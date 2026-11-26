import AppKit
import WebKit

@MainActor private final class RecoveryProbeWeb: WKWebView {
    var pageURL: URL? = URL(string: "http://127.0.0.1:9/recovery")!
    var reloadCount = 0
    var pageTitle: String? = "Owned recovery page"
    override var url: URL? { pageURL }
    override var title: String? { pageTitle }
    func clearTitle() {
        willChangeValue(forKey: "title"); pageTitle = ""; didChangeValue(forKey: "title")
    }
    override func reload() -> WKNavigation? { reloadCount += 1; return nil }
}

@MainActor func checkWebsiteProcessRecovery(_ check: (Bool, String) -> Void) async throws {
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    for privateMode in [false, true] {
        let fixture = try SiteSearchStoreFixture(isPrivate: privateMode)
        defer { fixture.close() }
        let store = fixture.store, id = store.selectedID!
        let configuration = fixture.web.configuration
        configuration.websiteDataStore = store.websiteDataStore(forProfile: fixture.profile)
        let web = RecoveryProbeWeb(frame: fixture.web.frame, configuration: configuration)
        store.registerView(web, for: id, profile: fixture.profile)
        store.update(id) { $0.url = web.pageURL!.absoluteString }
        store.flush()
        let savedBytes = privateMode ? nil : try Data(contentsOf: store.sessionURL)
        let host = EdgeToEdgeWebHost(frame: NSRect(x: 0, y: 0, width: 800, height: 560))
        let pane = WebPane(webView: web, store: store)
        pane.mount(in: host)
        store.message = "Owned unrelated notice"
        store.webViewWebContentProcessDidTerminate(web)
        web.pageURL = nil
        pane.mount(in: host); host.layoutSubtreeIfNeeded()
        let scope = privateMode ? "Private" : "Normal"
        let card = descendants(host).first { $0.identifier?.rawValue == "AlcoveWebsiteProcessRecovery" && !$0.isHidden }
        let reload = card.flatMap { descendants($0).first { $0.identifier?.rawValue == "AlcoveWebsiteProcessReload" } as? NSButton }
        check(store.message == "Owned unrelated notice", "\(scope) failed page preserves unrelated global notices")
        check(card != nil && reload?.title == "Reload", "\(scope) failed page presents its own native Reload control")
        check(web.superview === host && web.frame == host.bounds, "\(scope) recovery keeps the same full-size page mounted")
        check(store.sidebarAddressURL?.host == "127.0.0.1", "\(scope) address survives WebKit losing its URL")
        if let reload {
            reload.performClick(nil); pane.mount(in: host)
            check(web.reloadCount == 1 && !descendants(host).contains { $0.identifier?.rawValue == "AlcoveWebsiteProcessRecovery" && !$0.isHidden }, "\(scope) retry clears its recovery before requesting one reload")
            reload.performClick(nil)
            check(web.reloadCount == 1, "\(scope) an old Reload control cannot replay its action")
        } else {
            check(false, "\(scope) retry clears its recovery before requesting one reload")
            check(false, "\(scope) an old Reload control cannot replay its action")
        }
        if privateMode {
            check(fixture.reads.count == 0 && !FileManager.default.fileExists(atPath: store.sessionURL.path), "Private recovery requests no keys and writes no session")
        } else {
            check(try Data(contentsOf: store.sessionURL) == savedBytes, "Normal recovery does not persist transient error state")
        }

        web.clearTitle()
        try await Task.sleep(for: .milliseconds(50))
        check(store.tab(id)?.title == "127.0.0.1", "\(scope) empty WebKit titles retain the saved hostname")
        let boostError = NSError(domain: "OwnedBoostFailure", code: 1, userInfo: [NSLocalizedDescriptionKey: "Owned Boost failure"])
        BoostRuntime.report(boostError, page: BoostRuntime.page(for: web))
        check(store.message == "Boost: Owned Boost failure", "\(scope) a current Boost error is still reported")
        store.webViewWebContentProcessDidTerminate(web)
        check(store.message == nil && store.websiteProcessRecovery(for: web) != nil,
              "\(scope) process recovery removes only its own obsolete Boost notice")

        store.webViewWebContentProcessDidTerminate(web); pane.mount(in: host)
        let staleNavigationButton = descendants(host).first { $0.identifier?.rawValue == "AlcoveWebsiteProcessReload" } as? NSButton
        store.webView(web, didStartProvisionalNavigation: nil); pane.mount(in: host)
        staleNavigationButton?.performClick(nil)
        check(staleNavigationButton != nil && web.reloadCount == 1 && store.websiteProcessRecovery(for: web) == nil,
              "\(scope) navigation expires its old card and Reload action")

        store.webViewWebContentProcessDidTerminate(web)
        var appearance = store.appearance; appearance.textScale = 1.5; store.appearance = appearance
        host.frame.size = NSSize(width: 224, height: 170)
        pane.mount(in: host); host.needsLayout = true; host.layoutSubtreeIfNeeded()
        let narrowCard = descendants(host).first { $0.identifier?.rawValue == "AlcoveWebsiteProcessRecovery" }
        let scroll = narrowCard.flatMap { descendants($0).first { $0 is NSScrollView } as? NSScrollView }
        let narrowButton = narrowCard.flatMap { descendants($0).first { $0.identifier?.rawValue == "AlcoveWebsiteProcessReload" } as? NSButton }
        check(scroll?.hasVerticalScroller == true && (scroll?.documentView?.bounds.height ?? 0) > (scroll?.contentSize.height ?? 0)
                && narrowButton != nil && narrowButton!.frame.maxY <= scroll!.documentView!.bounds.maxY,
              "\(scope) narrow large-text recovery keeps its native control in scrollable content")
        store.discardView(id); pane.mount(in: host)
        narrowButton?.performClick(nil); store.webViewWebContentProcessDidTerminate(web)
        check(web.reloadCount == 1 && store.websiteProcessRecovery(for: web) == nil && store.websiteProcessRecoveries.isEmpty,
              "\(scope) disposal rejects old buttons and late process callbacks")
        host.removeContent(web)
    }

    let fixture = try SiteSearchStoreFixture()
    defer { fixture.close() }
    let store = fixture.store, owner = BrowserWindowOwner(store: store)
    let first = try owner.acquirePrimaryStore()
    defer { owner.release(first.lease) }
    let id = store.selectedID!, web = RecoveryProbeWeb(frame: fixture.web.frame, configuration: fixture.web.configuration)
    store.registerView(web, for: id, profile: fixture.profile)
    store.webViewWebContentProcessDidTerminate(web)
    let original = store.websiteProcessRecovery(for: web)
    let firstHost = EdgeToEdgeWebHost(frame: NSRect(x: 0, y: 0, width: 800, height: 560))
    WebPane(webView: web, store: store).mount(in: firstHost)
    let oldButton = descendants(firstHost).first { $0.identifier?.rawValue == "AlcoveWebsiteProcessReload" } as? NSButton
    let second = try owner.acquirePrimaryStore(copying: store, claimSelection: false)
    defer { owner.release(second.lease) }
    second.store.select(id)
    let transferred = second.store.websiteProcessRecovery(for: web)
    oldButton?.performClick(nil)
    check(original != nil && transferred != nil && transferred !== original && store.websiteProcessRecoveries.isEmpty
            && second.store.views[id] === web && web.reloadCount == 0,
          "A moved failed page recreates recovery only in its new owner and rejects the old button")
    store.webViewWebContentProcessDidTerminate(web)
    check(second.store.websiteProcessRecovery(for: web) === transferred && store.websiteProcessRecoveries.isEmpty,
          "A late callback from the previous owner cannot replace transferred recovery")
    let secondHost = EdgeToEdgeWebHost(frame: firstHost.frame)
    WebPane(webView: web, store: second.store).mount(in: secondHost)
    let newButton = descendants(secondHost).first { $0.identifier?.rawValue == "AlcoveWebsiteProcessReload" } as? NSButton
    newButton?.performClick(nil)
    check(newButton != nil && web.reloadCount == 1 && second.store.websiteProcessRecovery(for: web) == nil,
          "The moved page's native Reload targets its new owner exactly once")
}
