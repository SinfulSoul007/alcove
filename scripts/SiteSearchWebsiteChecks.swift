import AppKit
import WebKit
import CryptoKit
import BrowserCore

enum SiteSearchWebsiteError: Error { case missingFixture, timedOut, invalidPage, failed }
@main struct SiteSearchWebsiteChecks {
    @MainActor static func ready(_ web: WKWebView, _ expected: String) async throws {
        let quoted = String(decoding: try JSONEncoder().encode(expected), as: UTF8.self)
        let deadline = ContinuousClock.now.advanced(by: .seconds(40))
        while ContinuousClock.now < deadline {
            if (try? await web.evaluateJavaScript("window.alcoveSiteSearchReady === true && location.href === \(quoted)")) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(15))
        }
        throw SiteSearchWebsiteError.timedOut
    }
    @MainActor static func record(_ web: WKWebView) async throws -> (query: [String: [String]], cookie: String) {
        guard let result = try await web.evaluateJavaScript("JSON.parse(document.getElementById('result').textContent)") as? [String: Any],
              let query = result["query"] as? [String: [String]], let cookie = result["cookie"] as? String else { throw SiteSearchWebsiteError.invalidPage }
        return (query, cookie)
    }
    @MainActor static func exercise(_ origin: String, root: URL, owned: OwnedWebsiteStores) async throws -> Int {
        var failures = 0, privateKeyReads = 0
        func check(_ value: Bool, _ name: String) { print("\(value ? "PASS" : "FAIL"): \(name)"); if !value { failures += 1 } }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        func count(_ path: String = "*") async throws -> Int {
            var parts = URLComponents(string: origin + "__count")!; parts.queryItems = [URLQueryItem(name: "path", value: path)]
            let (data, _) = try await session.data(from: parts.url!)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Int], let value = object["count"] else { throw SiteSearchWebsiteError.invalidPage }
            return value
        }
        let key = SymmetricKey(size: .bits256)
        let store = BrowserStore(dataRoot: root.appendingPathComponent("normal"), keyProvider: { _ in key })
        let privateStore = BrowserStore(isPrivate: true, dataRoot: root.appendingPathComponent("private"), keyProvider: { _ in privateKeyReads += 1; return key })
        store.onboardingVisible = false; privateStore.onboardingVisible = false
        defer { store.shutdown(); privateStore.shutdown() }
        let a = try store.createProfile(name: "Owned search A"), spaceA = store.space.id, tabA = store.selectedID!
        try owned.register(a)
        store.update(tabA) { $0.url = origin + "start?account=A" }
        let webA = store.view(for: tabA); webA.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        try await ready(webA, origin + "start?account=A")
        _ = try await webA.evaluateJavaScript("document.cookie='account=ALPHA; Path=/'")
        let b = try store.createProfile(name: "Owned search B"), spaceB = store.space.id, tabB = store.selectedID!
        try owned.register(b)
        store.update(tabB) { $0.url = origin + "start?account=B" }
        let webB = store.view(for: tabB); webB.frame = webA.frame
        try await ready(webB, origin + "start?account=B")
        _ = try await webB.evaluateJavaScript("document.cookie='account=BETA; Path=/'")
        let site = SiteSearch(name: "Owned local search", keyword: "own", template: origin + "search?q=%s&kind=site")
        try store.saveSiteSearch(site); store.selectSpace(spaceA)
        let beforeActivation = try await count()
        store.showCommand(); store.command = "own"; _ = store.activateCommandSiteSearch(site)
        store.command = "cats & dogs/#?%=+ café 🐈"
        check(try await count() == beforeActivation && webA.url?.absoluteString == origin + "start?account=A", "Typing and activating a site send no real WebKit request")
        store.navigate(store.command)
        try await ready(webA, origin + "search?q=cats%20%26%20dogs%2F%23%3F%25%3D%2B%20caf%C3%A9%20%F0%9F%90%88&kind=site")
        let first = try await record(webA)
        check(first.query == ["q": ["cats & dogs/#?%=+ café 🐈"], "kind": ["site"]], "The real site receives one intact Unicode query without injected parameters")
        check(first.cookie.contains("account=ALPHA") && !first.cookie.contains("BETA"), "Primary site search uses its own actual named-profile login")
        let rightID = store.newTab(url: URL(string: origin + "start?pane=right"))
        let right = store.view(for: rightID); right.frame = webA.frame
        try await ready(right, origin + "start?pane=right")
        store.session.spaces[store.spaceIndex].selected = tabA; store.splitID = rightID; store.activePaneID = rightID
        store.showCommand(); _ = store.activateCommandSiteSearch(site); store.command = "right"; store.navigate(store.command)
        try await ready(right, origin + "search?q=right&kind=site")
        let split = try await record(right)
        let leftAfterSplit = try await record(webA)
        check(split.query["q"] == ["right"] && split.cookie.contains("account=ALPHA") && leftAfterSplit.query["q"] == first.query["q"], "A real focused split search preserves the covered pane's document and account")
        store.openPeek(URL(string: origin + "start?peek=primary")!, from: right)
        let peek = store.primaryPeekView!; peek.frame = webA.frame
        try await ready(peek, origin + "start?peek=primary")
        store.showCommand(); _ = store.activateCommandSiteSearch(site); store.command = "preview"; store.navigate(store.command)
        try await ready(peek, origin + "search?q=preview&kind=site")
        let preview = try await record(peek)
        let parentAfterPreview = try await record(right)
        check(preview.query["q"] == ["preview"] && preview.cookie.contains("account=ALPHA") && parentAfterPreview.query["q"] == ["right"], "Real primary Peek search navigates only its preview in the source profile")
        store.closePrimaryPeek()
        let quickID = try store.openQuickPage(url: URL(string: origin + "start?quick=B"), profileID: b, intendedSpaceID: spaceB)
        let quick = store.view(for: quickID); quick.frame = webA.frame
        try await ready(quick, origin + "start?quick=B")
        let compactContext = store.searchInputContext(quickID: quickID)!
        try store.navigateForegroundQuickPage(quickID, input: "compact", selection: site, context: compactContext)
        try await ready(quick, origin + "search?q=compact&kind=site")
        let compact = try await record(quick)
        check(store.activeProfileID == a && compact.query["q"] == ["compact"] && compact.cookie.contains("account=BETA") && !compact.cookie.contains("ALPHA"), "Real compact search retains its B account while the primary window uses A")
        store.openPeek(URL(string: origin + "start?peek=compact")!, from: quick)
        let quickPeek = store.quickPeekView(quickID)!; quickPeek.frame = webA.frame
        try await ready(quickPeek, origin + "start?peek=compact")
        let compactPeekContext = store.searchInputContext(quickID: quickID)!
        try store.navigateForegroundQuickPage(quickID, input: "compact preview", selection: site, context: compactPeekContext)
        try await ready(quickPeek, origin + "search?q=compact%20preview&kind=site")
        let compactPreview = try await record(quickPeek)
        let compactParentAfterPreview = try await record(quick)
        check(compactPreview.cookie.contains("account=BETA") && compactPreview.query["q"] == ["compact preview"] && compactParentAfterPreview.query["q"] == ["compact"], "Real compact Peek search preserves its parent and primary account")
        check(privateStore.siteSearchCatalog.preferredMatch("own") == nil, "A new private owner does not inherit normal custom search configuration")
        let privateID = privateStore.selectedID!
        privateStore.update(privateID) { $0.url = origin + "start?private=1" }
        let privateWeb = privateStore.view(for: privateID); privateWeb.frame = webA.frame
        try await ready(privateWeb, origin + "start?private=1")
        try privateStore.saveSiteSearch(site)
        privateStore.showCommand(); _ = privateStore.activateCommandSiteSearch(site); privateStore.command = "private query"; privateStore.navigate(privateStore.command)
        try await ready(privateWeb, origin + "search?q=private%20query&kind=site")
        let privateResult = try await record(privateWeb)
        check(privateResult.query["q"] == ["private query"] && privateResult.cookie.isEmpty, "Real private search sends neither normal profile's login cookies")
        check(privateKeyReads == 0 && !FileManager.default.fileExists(atPath: privateStore.sessionURL.path), "Real private query navigation and configuration do not read keys or save metadata")
        let beforeRejected = try await count()
        var changed = site; changed.template = origin + "other?q=%s"; try store.saveSiteSearch(changed)
        var rejected = false
        do { try store.navigateForegroundQuickPage(quickID, input: "old provider query", selection: site, context: compactPeekContext) } catch { rejected = true }
        check(try await count() == beforeRejected && rejected && quickPeek.url?.absoluteString == origin + "search?q=compact%20preview&kind=site", "Changed provider snapshots send no real fallback or redirected request")
        try store.saveSiteSearch(site)
        store.showCommand(); _ = store.activateCommandSiteSearch(site); store.command = "old A draft"
        let oldContext = store.commandContext!
        store.selectSpace(spaceB)
        check(!store.matchesSearchInputContext(oldContext) && store.command.isEmpty && !store.commandVisible, "A real profile switch removes the previous account's pending query")
        check(try await count() == beforeRejected, "Profile switching and draft cancellation send no pending search")
        store.selectSpace(spaceA)
        let beforeNewTab = try await count("/search")
        store.showCommand(new: true); _ = store.activateCommandSiteSearch(site); store.command = "created tab"; store.navigate(store.command)
        let created = store.currentView!; created.frame = webA.frame
        try await ready(created, origin + "search?q=created%20tab&kind=site")
        let createdResult = try await record(created)
        check(createdResult.query["q"] == ["created tab"] && createdResult.cookie.contains("account=ALPHA"), "A newly created search tab uses the captured normal profile")
        check(try await count("/search") == beforeNewTab + 1, "One explicit new-tab submission causes one site search request")
        return failures
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited); setbuf(stdout, nil)
        let owned = try OwnedWebsiteStores()
        if CommandLine.arguments.contains("--cleanup-owned-stores") { exit(await owned.cleanup() ? 0 : 1) }
        guard await owned.cleanup() else { exit(1) }
        guard let origin = ProcessInfo.processInfo.environment["ALCOVE_SITE_SEARCH_FIXTURE_URL"], let url = URL(string: origin), url.host == "127.0.0.1", url.port != nil else { throw SiteSearchWebsiteError.missingFixture }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Alcove.SiteSearchWebsite.\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var failures = 0, caught: Error?
        do { failures = try await exercise(origin, root: root, owned: owned) } catch { caught = error }
        guard await owned.cleanup() else { exit(1) }
        if let caught { throw caught }
        if failures > 0 { throw SiteSearchWebsiteError.failed }
    }
}
