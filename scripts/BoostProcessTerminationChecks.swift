import AppKit
import WebKit

/// Exercise the public WebKit callback without killing an OS process. The
/// public Objective-C API has a __ spelling because Swift refines its result.
@MainActor private final class UnavailableBoostDocument: WKWebView {
    var queryCount = 0
    override var url: URL? { URL(string: "http://127.0.0.1:9/original")! }
    override func __callAsyncJavaScript(_ functionBody: String, arguments: [String: Any]?,
                                      inFrame frame: WKFrameInfo?, in contentWorld: WKContentWorld,
                                      completionHandler: (@MainActor @Sendable (Any?, Error?) -> Void)?) {
        queryCount += 1
        completionHandler?(nil, NSError(domain: "OwnedUnavailableDocument", code: 1,
                                       userInfo: [NSLocalizedDescriptionKey: "The old document is unavailable"]))
    }
}

@MainActor func checkBoostProcessTermination(_ check: (Bool, String) -> Void) async throws {
    for privateMode in [false, true] {
        let fixture = try SiteSearchStoreFixture(isPrivate: privateMode)
        defer { fixture.close() }
        let store = fixture.store, id = store.selectedID!
        let configuration = fixture.web.configuration
        // Private Boosts must use this window’s actual ephemeral store.
        configuration.websiteDataStore = store.websiteDataStore(forProfile: fixture.profile)
        let web = UnavailableBoostDocument(frame: fixture.web.frame, configuration: configuration)
        store.registerView(web, for: id, profile: fixture.profile)
        let oldDocument = store.documentIdentity(for: web)

        store.webViewWebContentProcessDidTerminate(web)
        // Allow the callback's queued MainActor work to run. No JavaScript
        // engine, website, media or real crash is needed for this boundary.
        try await Task.sleep(for: .milliseconds(50))
        let scope = privateMode ? "Private" : "Normal"
        check(store.message == "This page stopped responding. Use Reload to try again.",
              "\(scope) page-process recovery keeps its useful reload message")
        check(web.queryCount == 0,
              "\(scope) terminated document receives no new Boost queries")
        check(store.views[id] === web && store.documentIdentity(for: web) !== oldDocument,
              "\(scope) termination expires document-bound work without discarding its tab")

        store.webView(web, didStartProvisionalNavigation: nil)
        try await Task.sleep(for: .milliseconds(50))
        check(web.queryCount > 0,
              "\(scope) explicit next navigation resumes normal Boost processing")
    }
}
