import AppKit
import WebKit
import CryptoKit
import BrowserCore

enum LinkRoutingWebsiteError: Error { case missingFixture, timedOut, invalidPage, failed }
@main struct LinkRoutingWebsiteChecks {
    @MainActor static func ready(_ web: WKWebView, _ expected: String) async throws {
        let quoted = String(decoding:try JSONEncoder().encode(expected),as:UTF8.self)
        let deadline = ContinuousClock.now.advanced(by:.seconds(40))
        while ContinuousClock.now < deadline {
            if (try? await web.evaluateJavaScript("window.alcoveRoutingReady === true && location.href === \(quoted)")) as? Bool == true { return }
            try await Task.sleep(for:.milliseconds(15))
        }
        print("FAIL: Timed out waiting for owned routing page \(expected)"); throw LinkRoutingWebsiteError.timedOut
    }
    @MainActor static func cookie(_ web: WKWebView) async throws -> String {
        guard let data = try await web.evaluateJavaScript("JSON.parse(document.getElementById('result').textContent)") as? [String:Any], let cookie = data["cookie"] as? String else { throw LinkRoutingWebsiteError.invalidPage }; return cookie
    }
    @MainActor static func exercise(_ origin: String, root: URL, owned: OwnedWebsiteStores) async throws -> Int {
        var failures = 0, privateReads = 0
        func check(_ value: Bool, _ name: String) { print("\(value ? "PASS" : "FAIL"): \(name)"); if !value { failures += 1 } }
        func rejects(_ action: () throws -> Void) -> Bool { do { try action(); return false } catch { return true } }
        let config = URLSessionConfiguration.ephemeral; config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        let requests = URLSession(configuration:config); defer { requests.invalidateAndCancel() }
        func count() async throws -> Int {
            let (data,_) = try await requests.data(from:URL(string:origin+"__count")!)
            guard let result = try JSONSerialization.jsonObject(with:data) as? [String:Int], let count = result["count"] else { throw LinkRoutingWebsiteError.invalidPage }; return count
        }
        let key = SymmetricKey(size:.bits256)
        let store = BrowserStore(dataRoot:root.appendingPathComponent("normal"),keyProvider:{_ in key})
        let privateStore = BrowserStore(isPrivate:true,dataRoot:root.appendingPathComponent("private"),keyProvider:{_ in privateReads += 1; return key})
        store.onboardingVisible = false; privateStore.onboardingVisible = false
        defer { store.shutdown(); privateStore.shutdown() }
        let a = try store.createProfile(name:"Owned route A"), spaceA = store.space.id, idA = store.selectedID!; try owned.register(a)
        store.update(idA) { $0.url = origin + "start-a" }; let webA = store.view(for:idA); webA.frame = NSRect(x:0,y:0,width:800,height:600)
        try await ready(webA,origin+"start-a"); _ = try await webA.evaluateJavaScript("document.cookie='account=ALPHA; Path=/'")
        let b = try store.createProfile(name:"Owned route B"), spaceB = store.space.id, idB = store.selectedID!; try owned.register(b)
        store.update(idB) { $0.url = origin + "start-b" }; let webB = store.view(for:idB); webB.frame = webA.frame
        try await ready(webB,origin+"start-b"); _ = try await webB.evaluateJavaScript("document.cookie='account=BETA; Path=/'")
        store.selectSpace(spaceA); store.preferences.quickDomainChoices = [QuickDomainChoice(host:"127.0.0.1",profileID:b)]
        try store.setDefaultLinkDestination(.mostRecentSpace)
        let beforeLocal = try await count()
        _ = try store.linkDecision(for:URL(string:origin+"recent")!)
        try store.saveLinkRule(LinkRule(pattern:"/named",destination:.space(spaceA)))
        check(try await count() == beforeLocal, "Rule edits and destination preview send no WebKit requests")
        check(try store.openExternalPage(URL(string:origin+"recent")!) == .space(spaceB), "Remembered-profile recent route selects its own durable Space")
        let recent = store.view(for:store.selectedID!); recent.frame = webA.frame; try await ready(recent,origin+"recent")
        let recentCookie = try await cookie(recent)
        check(recentCookie.contains("account=BETA") && !recentCookie.contains("ALPHA"), "External recent Space loads only the remembered account's cookies")
        _ = try store.openExternalPage(URL(string:origin+"named")!); let named = store.view(for:store.selectedID!); named.frame = webA.frame
        try await ready(named,origin+"named"); let namedCookie = try await cookie(named)
        check(store.space.id == spaceA && namedCookie.contains("account=ALPHA") && !namedCookie.contains("BETA"), "Named-Space route overrides remembered account with actual A cookies")
        try store.setDefaultLinkDestination(.quickBrowse)
        guard case .quick(let compactID) = try store.openExternalPage(URL(string:origin+"compact")!) else { throw LinkRoutingWebsiteError.invalidPage }
        let compact = store.view(for:compactID); compact.frame = webA.frame; try await ready(compact,origin+"compact")
        let compactCookie = try await cookie(compact)
        check(store.quickProfileID(compactID) == b && compactCookie.contains("account=BETA") && !compactCookie.contains("ALPHA"), "External compact route loads in its remembered named store")
        var archiveDoc = store.makeDocument(), records = archiveDoc.library(for:a)
        var archived = BrowserCore.Tab(title:"Owned archived page",url:origin+"archive"); archived.archivedSpaceID = spaceA
        records.archive.insert(archived,at:0); archiveDoc.setLibrary(records,for:a); try store.commitQuickDocument(archiveDoc)
        try store.saveLinkRule(LinkRule(pattern:"/archive",destination:.space(spaceB)))
        let restored = try store.restoreArchivedRouted(archived.id,profileID:a), archiveView = store.view(for:restored); archiveView.frame = webA.frame
        try await ready(archiveView,origin+"archive"); let archiveCookie = try await cookie(archiveView)
        check(store.profileID(for:restored) == b && archiveCookie.contains("account=BETA") && !archiveCookie.contains("ALPHA") && store.library(for:a).archive.isEmpty, "Closed archive routes with fresh target cookies and consumes its source record atomically")
        store.selectSpace(spaceA)
        store.openPeek(URL(string:origin+"peek-start")!,from:webA)
        let peek = store.primaryPeekView!; peek.frame = webA.frame; try await ready(peek,origin+"peek-start")
        peek.load(URLRequest(url:URL(string:origin+"peek-final")!)); try await ready(peek,origin+"peek-final")
        _ = try await peek.evaluateJavaScript("document.getElementById('draft').value='unsaved A form'; window.scrollTo(0,420)")
        let scroll = (try await peek.evaluateJavaScript("scrollY")) as! Double, history = peek.backForwardList.backList.count
        let beforeHandoff = try await count(), promoted = try store.promotePeek(in:.primary,to:spaceA)
        let form = try await peek.evaluateJavaScript("document.getElementById('draft').value") as? String
        let afterScroll = (try await peek.evaluateJavaScript("scrollY")) as! Double
        check(store.views[promoted] === peek && form == "unsaved A form" && afterScroll == scroll && history > 0 && peek.backForwardList.backList.count == history, "Same-profile real Peek retains its view, unsaved form, scroll and navigation history")
        check(try await count() == beforeHandoff, "Same-profile handoff makes no reload request")
        store.openPeek(URL(string:origin+"preserve-primary")!,from:webA)
        let primary = store.primaryPeekView!; primary.frame = webA.frame; try await ready(primary,origin+"preserve-primary")
        _ = try await primary.evaluateJavaScript("document.getElementById('draft').value='primary form'")
        store.openPeek(URL(string:origin+"compact-peek")!,from:compact)
        let compactPeek = store.quickPeekView(compactID)!; compactPeek.frame = webA.frame; try await ready(compactPeek,origin+"compact-peek")
        _ = try await compactPeek.evaluateJavaScript("document.getElementById('draft').value='compact B form'")
        let compactPromoted = try store.promotePeek(in:.quick(compactID),to:spaceB)
        let primaryForm = try await primary.evaluateJavaScript("document.getElementById('draft').value") as? String
        let compactForm = try await compactPeek.evaluateJavaScript("document.getElementById('draft').value") as? String
        check(store.views[compactPromoted] === compactPeek && store.views.values.contains(where:{$0 === primary}) && primaryForm == "primary form" && compactForm == "compact B form", "Opening a compact Peek preserves two distinct live forms in their original named stores")
        store.selectSpace(spaceA); store.openPeek(URL(string:origin+"cross-profile")!,from:webA)
        let crossing = store.primaryPeekView!; crossing.frame = webA.frame; try await ready(crossing,origin+"cross-profile")
        _ = try await crossing.evaluateJavaScript("document.getElementById('draft').value='private A draft'")
        let snapshot = try store.preparePeekPromotion(in:.primary,to:spaceB), beforeConsent = try await count(), tabsBefore = store.session.spaces.flatMap(\.tabs).count
        check(rejects { _ = try store.performPeekPromotion(snapshot) } && store.session.spaces.flatMap(\.tabs).count == tabsBefore && store.primaryPeekView === crossing, "Missing reload consent preserves the live source and creates no target tab")
        check(try await count() == beforeConsent, "Unconfirmed cross-profile opening sends no request")
        let crossedID = try store.performPeekPromotion(snapshot,allowProfileChange:true), crossed = store.view(for:crossedID); crossed.frame = webA.frame
        try await ready(crossed,origin+"cross-profile"); let crossedCookie = try await cookie(crossed), crossedForm = try await crossed.evaluateJavaScript("document.getElementById('draft').value") as? String
        check(crossed !== crossing && crossedCookie.contains("account=BETA") && !crossedCookie.contains("ALPHA") && crossedForm == "", "Confirmed cross-profile handoff uses a fresh B view without copying A's cookies or unsaved form")
        store.selectSpace(spaceA); store.openPeek(URL(string:origin+"stale")!,from:webA)
        let staleWeb = store.primaryPeekView!; staleWeb.frame = webA.frame; try await ready(staleWeb,origin+"stale")
        let stale = try store.preparePeekPromotion(in:.primary,to:spaceB)
        staleWeb.load(URLRequest(url:URL(string:origin+"new-document")!)); try await ready(staleWeb,origin+"new-document")
        let afterNewDocument = try await count()
        check(rejects { _ = try store.performPeekPromotion(stale,allowProfileChange:true) } && store.primaryPeekView === staleWeb, "Actual WebKit document navigation invalidates the earlier consent")
        check(try await count() == afterNewDocument, "Stale consent creates no real target request")
        store.savingEnabled = false
        check(rejects { _ = try store.openExternalPage(URL(string:origin+"failed-save")!) }, "Locked encrypted metadata rejects external navigation before view creation")
        check(try await count() == afterNewDocument, "Failed routing sends no real request")
        store.savingEnabled = true
        let privateID = privateStore.selectedID!; privateStore.update(privateID) { $0.url = origin + "private" }
        let privateWeb = privateStore.view(for:privateID); privateWeb.frame = webA.frame; try await ready(privateWeb,origin+"private")
        privateStore.preferences.linkRules = [LinkRule(pattern:"/private-peek",destination:.space(spaceB))]
        privateStore.openPeek(URL(string:origin+"private-peek")!,from:privateWeb)
        let privatePeek = privateStore.primaryPeekView!; privatePeek.frame = webA.frame; try await ready(privatePeek,origin+"private-peek")
        let privatePromoted = try privateStore.promotePeek(in:.primary), privateCookie = try await cookie(privatePeek)
        check(privateStore.views[privatePromoted] === privatePeek && privateCookie.isEmpty && privateReads == 0 && !FileManager.default.fileExists(atPath:privateStore.sessionURL.path), "Private Peek ignores normal rules, stays ephemeral and sends no named-store cookies")
        store.selectSpace(spaceA)
        let first = origin + "duplicate-first", current = origin + "duplicate-current", next = origin + "duplicate-next"
        let original = store.newTab(url:URL(string:first)!)
        let originalWeb = store.view(for:original); originalWeb.frame = webA.frame
        try await ready(originalWeb,first)
        originalWeb.load(URLRequest(url:URL(string:current)!)); try await ready(originalWeb,current)
        originalWeb.load(URLRequest(url:URL(string:next)!)); try await ready(originalWeb,next)
        originalWeb.goBack(); try await ready(originalWeb,current)
        _ = try await originalWeb.evaluateJavaScript("document.getElementById('draft').value='original draft'")
        let following = store.newTab(url:URL(string:origin+"duplicate-following")!)
        store.accessOrder.removeAll { $0 == original }
        store.accessOrder.insert(original, at: 0)
        store.preferences.suspendTabs = true
        guard let duplicate = store.duplicateSidebarTab(original) else { throw LinkRoutingWebsiteError.failed }
        store.preferences.suspendTabs = false
        let duplicateWeb = store.view(for:duplicate); duplicateWeb.frame = originalWeb.frame
        try await ready(duplicateWeb,current)
        let duplicateCookie = try await cookie(duplicateWeb)
        check(duplicate != original && duplicateWeb !== originalWeb && store.views[original] === originalWeb, "Duplicate opens a separate WebKit view without replacing its source")
        check(store.activeProfileID == a && duplicateCookie.contains("account=ALPHA") && !duplicateCookie.contains("BETA"), "Duplicate keeps the source profile website data")
        check(store.focusedID == duplicate && Array(store.space.tabs.map(\.id).suffix(3)) == [original, duplicate, following], "Duplicate appears next to its Today source and becomes active")
        check(duplicateWeb.backForwardList.backList.map { $0.url.absoluteString } == [first] && duplicateWeb.backForwardList.forwardList.map { $0.url.absoluteString } == [next], "Duplicate keeps the current, back and forward navigation entries")
        duplicateWeb.goBack(); try await ready(duplicateWeb,first)
        duplicateWeb.goForward(); try await ready(duplicateWeb,current)
        let retainedDraft = try await originalWeb.evaluateJavaScript("document.getElementById('draft').value") as? String
        check(originalWeb.url?.absoluteString == current && retainedDraft == "original draft", "Copy navigation leaves the original page and unsaved form intact")
        store.toggleFavorite(original)
        guard let favoriteCopy = store.duplicateSidebarTab(original), let copiedFavorite = store.tab(favoriteCopy) else { throw LinkRoutingWebsiteError.failed }
        check(!copiedFavorite.pinned && copiedFavorite.favorite != true && copiedFavorite.homeURL == nil && store.favorites.contains(where: { $0.id == original }), "Duplicating a Favorite opens a Today tab and keeps the saved Favorite")
        let saved = store.newTab(url:URL(string:origin+"duplicate-saved")!)
        guard let restoredCopy = store.duplicateSidebarTab(saved) else { throw LinkRoutingWebsiteError.failed }
        try await ready(store.view(for:restoredCopy),origin+"duplicate-saved")
        check(store.views[saved] == nil, "A saved-only tab opens its current address without mounting the source")
        guard let privateCopy = privateStore.duplicateSidebarTab(privateID) else { throw LinkRoutingWebsiteError.failed }
        let privateCopyWeb = privateStore.view(for:privateCopy)
        try await ready(privateCopyWeb,origin+"private")
        let copyCookie = try await cookie(privateCopyWeb)
        check(copyCookie.isEmpty && !privateCopyWeb.configuration.websiteDataStore.isPersistent && privateReads == 0, "Private duplication stays inside its ephemeral website store")
        let home = origin + "pinned-home", drift = origin + "pinned-current"
        let pin = store.newTab(url: URL(string: home)!)
        let pinWeb = store.view(for: pin); pinWeb.frame = webA.frame
        try await ready(pinWeb, home)
        store.togglePin(pin)
        let folder = try store.createTabFolder(name: "Pinned test folder", in: spaceA, adding: pin)
        try store.renameSidebarTab(store.beginSidebarRename(pin), to: "Saved starting point")
        check(!store.canReturnToPinnedAddress(pin), "The pin does not show a reset action at its saved address")
        pinWeb.load(URLRequest(url: URL(string: drift)!)); try await ready(pinWeb, drift)
        check(store.canReturnToPinnedAddress(pin), "The reset action becomes available after navigating away from a pin")
        check(store.availableCommands.contains(.returnToPinnedURL) && store.availableCommands.contains(.returnToPinnedURLKeepingPage),
              "Both pinned reset actions are available in keyboard command search")
        let originalCount = store.space.tabs.count
        let reset = try store.returnToPinnedAddress(pin)
        try await ready(pinWeb, home)
        check(reset == nil && store.views[pin] === pinWeb && pinWeb.canGoBack && store.space.tabs.count == originalCount,
              "Reset navigates the existing pinned page home without making a copy")
        pinWeb.goBack(); try await ready(pinWeb, drift)
        _ = try await pinWeb.evaluateJavaScript("document.getElementById('draft').value='keep this draft'")
        store.savingEnabled = false
        check(rejects { _ = try store.returnToPinnedAddress(pin, keepingCurrentPage: true) }
              && store.views[pin] === pinWeb && store.space.tabs.count == originalCount,
              "A failed pinned reset cannot detach the live page or create a phantom tab")
        store.savingEnabled = true
        guard let continued = try store.returnToPinnedAddress(pin, keepingCurrentPage: true) else { throw LinkRoutingWebsiteError.failed }
        let returnedHome = store.view(for: pin); returnedHome.frame = pinWeb.frame; try await ready(returnedHome, home)
        let movedDraft = try await pinWeb.evaluateJavaScript("document.getElementById('draft').value") as? String
        check(store.views[continued] === pinWeb && returnedHome !== pinWeb && pinWeb.url?.absoluteString == drift
              && pinWeb.canGoBack && movedDraft == "keep this draft",
              "Keeping the current page moves its original WebKit view, history and unsaved form")
        check(store.tab(pin)?.homeURL == home && store.tab(pin)?.folder == folder && store.tab(pin)?.sidebarTitle == "Saved starting point"
              && store.tab(continued)?.pinned == false && store.profileID(for: continued) == a && store.focusedID == pin,
              "The saved pin stays selected in its folder while its old page becomes a same-profile Today tab")
        store.toggleFavorite(pin)
        returnedHome.load(URLRequest(url: URL(string: drift)!)); try await ready(returnedHome, drift)
        _ = try store.returnToPinnedAddress(pin)
        try await ready(returnedHome, home)
        check(store.favorites.contains(where: { $0.id == pin && $0.url == home && $0.homeURL == home && $0.sidebarTitle == "Saved starting point" }),
              "Reset synchronizes the Favorite and saved-tab address")
        returnedHome.load(URLRequest(url: URL(string: drift)!)); try await ready(returnedHome, drift)
        _ = try await returnedHome.evaluateJavaScript("document.getElementById('draft').value='editing the pin'")
        let pendingEdit = try store.beginPinnedAddressEdit(pin)
        let editedHome = origin + "pinned-edited-address"
        check(rejects { try store.setPinnedAddress(pendingEdit, to: "javascript:void(0)") }
              && store.tab(pin)?.homeURL == home,
              "Pinned URL editing rejects non-website addresses without changing the pin")
        try store.setPinnedAddress(pendingEdit, to: editedHome)
        let stillDraft = try await returnedHome.evaluateJavaScript("document.getElementById('draft').value") as? String
        check(store.views[pin] === returnedHome && returnedHome.url?.absoluteString == drift
              && stillDraft == "editing the pin" && store.tab(pin)?.sidebarTitle == "Saved starting point",
              "Editing a pinned address keeps the live page, draft and custom title")
        check(store.favorites.contains(where: { $0.id == pin && $0.homeURL == editedHome }),
              "Editing a favorite updates both saved definitions")
        check(rejects { try store.setPinnedAddress(pendingEdit, to: home) } && store.tab(pin)?.homeURL == editedHome,
              "A stale pinned address editor cannot overwrite a newer edit")
        try store.useCurrentAddressAsPinned(pin)
        check(store.tab(pin)?.homeURL == drift && store.views[pin] === returnedHome && !store.canReturnToPinnedAddress(pin),
              "Use Current saves the committed page address without a reload")
        let persistedPin = try MetadataStore(url: store.sessionURL, key: key).load(BrowserDocument.self)
        check(persistedPin?.library(for: a).favoriteTabs?.first(where: { $0.id == pin })?.homeURL == drift,
              "The new pinned address round-trips through the encrypted profile library")
        let suspended = store.newTab(url: URL(string: home)!)
        store.togglePin(suspended)
        try store.setPinnedAddress(store.beginPinnedAddressEdit(suspended), to: editedHome)
        check(store.views[suspended] == nil && store.tab(suspended)?.url == editedHome,
              "Editing an unloaded pin changes its next opening address without loading it")
        let legacyPin = store.newTab(url: URL(string: drift)!)
        store.update(legacyPin) { $0.pinned = true }
        check(!store.canReturnToPinnedAddress(legacyPin), "Older pins without a saved address have no reset action")
        store.update(legacyPin) { $0.homeURL = home }
        guard let savedCurrent = try store.returnToPinnedAddress(legacyPin, keepingCurrentPage: true) else { throw LinkRoutingWebsiteError.failed }
        try await ready(store.view(for: legacyPin), home)
        check(store.tab(savedCurrent)?.url == drift && store.views[savedCurrent] == nil, "A suspended pin keeps its saved current address without loading the old page")
        store.selectSpace(spaceB)
        check(!store.canReturnToPinnedAddress(legacyPin), "A pin from another profile cannot be reset through the current sidebar")
        privateStore.select(privatePromoted)
        privateStore.togglePin(privatePromoted)
        privatePeek.load(URLRequest(url: URL(string: origin + "private-pinned-drift")!))
        try await ready(privatePeek, origin + "private-pinned-drift")
        guard let keptPrivate = try privateStore.returnToPinnedAddress(privatePromoted, keepingCurrentPage: true) else { throw LinkRoutingWebsiteError.failed }
        check(privateStore.views[keptPrivate] === privatePeek && !privatePeek.configuration.websiteDataStore.isPersistent
              && privateReads == 0 && !FileManager.default.fileExists(atPath: privateStore.sessionURL.path),
              "Returning home with a private pin preserves the live page without persisting a session")
        let aliases:[(String,String?)] = [("127.1","127.0.0.1"),("0x7f.1","127.0.0.1"),("0177.0.0.1","127.0.0.1"),("2130706433","127.0.0.1"),("bücher.example","xn--bcher-kva.example"),("[0:0:0:0:0:0:0:1]","[::1]"),("[::ffff:127.0.0.1]","[::ffff:7f00:1]"),("[:::]",nil),("09",nil)]
        let beforeAliases = try await count()
        for (input,expected) in aliases {
            let literal = String(decoding:try JSONEncoder().encode(input),as:UTF8.self)
            let engine = try await privatePeek.evaluateJavaScript("try { new URL('http://' + \(literal) + '/').hostname } catch (_) { null }")
            let actual = engine as? String
            check(actual == expected && RoutingHost.normalized(input) == expected, "Host identity agrees with actual WebKit for \(input)")
        }
        check(try await count() == beforeAliases, "Host alias comparisons use local URL parsing without navigation")
        return failures
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited); setbuf(stdout,nil)
        let owned = try OwnedWebsiteStores()
        if CommandLine.arguments.contains("--cleanup-owned-stores") { exit(await owned.cleanup() ? 0 : 1) }
        guard await owned.cleanup() else { exit(1) }
        guard let origin = ProcessInfo.processInfo.environment["ALCOVE_LINK_ROUTING_FIXTURE_URL"], let url = URL(string:origin), url.host == "127.0.0.1", url.port != nil else { throw LinkRoutingWebsiteError.missingFixture }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Alcove.LinkRoutingWebsite.\(UUID())")
        defer { try? FileManager.default.removeItem(at:root) }
        var failures = 0, caught: Error?
        do { failures = try await exercise(origin,root:root,owned:owned) } catch { caught = error }
        guard await owned.cleanup() else { exit(1) }
        if let caught { throw caught }; if failures > 0 { throw LinkRoutingWebsiteError.failed }
    }
}
