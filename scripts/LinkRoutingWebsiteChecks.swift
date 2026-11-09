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
