import AppKit
import SwiftUI
import WebKit
import BrowserCore

/// Opt-in GUI checks: actual compact windows, private stores and local HTML only.
@MainActor private final class QuickFocusRunner: NSObject, NSApplicationDelegate {
    var failures = 0
    func check(_ value: Bool, _ name: String) {
        print("\(value ? "PASS" : "FAIL"): \(name)")
        if !value { failures += 1 }
    }
    func settle() async { for _ in 0..<12 { try? await Task.sleep(for: .milliseconds(15)) } }
    func fields(_ view: NSView) -> [QuickBrowseInput.Field] {
        (view as? QuickBrowseInput.Field).map { [$0] } ?? view.subviews.flatMap(fields)
    }
    func field(_ window: NSWindow, _ placeholder: String) -> QuickBrowseInput.Field? {
        window.contentView.flatMap { fields($0).first { $0.placeholderString == placeholder } }
    }
    func focused(_ window: NSWindow, _ field: QuickBrowseInput.Field?, selected: String? = nil) -> Bool {
        guard window.isKeyWindow, let field, let editor = field.currentEditor(), window.firstResponder === editor else { return false }
        guard let selected else { return true }
        return editor.string == selected && editor.selectedRange == NSRange(location: 0, length: (selected as NSString).length)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        setbuf(stdout, nil)
        Task { @MainActor in
            do { try await run(); print("QUICK_FOCUS_REGRESSION_FINISHED"); exit(failures == 0 ? 0 : 1) }
            catch { print("FIXTURE_ERROR", error); exit(2) }
        }
    }
    enum SetupFailure: Error { case notReady }
    func run() async throws {
        let store = BrowserStore(isPrivate: true)
        var appearance = store.appearance; appearance.animationsEnabled = false; appearance.showFavicons = false; store.appearance = appearance
        let owner = BrowserWindowOwner(store: store)
        let id = try store.openQuickPage(url: URL(string: "https://owned-focus.example.invalid/")!)
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = store.websiteDataStore(forProfile: BrowserProfile.defaultID)
        let web = WKWebView(frame: .zero, configuration: configuration)
        store.registerView(web, for: id, profile: BrowserProfile.defaultID)
        web.loadHTMLString("<html><body><input id='draft' value='initial'><p>needle on an owned page</p></body></html>", baseURL: nil)
        for _ in 0..<200 {
            if (try? await web.evaluateJavaScript("document.getElementById('draft')?.value") as? String) == "initial" { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        guard web.url?.absoluteString == "about:blank",
              (try? await web.evaluateJavaScript("document.getElementById('draft')?.value") as? String) == "initial" else { throw SetupFailure.notReady }
        _ = try await web.evaluateJavaScript("document.getElementById('draft').value='unsaved focus canary'; window.focusDocumentToken='owned-document-9472'")
        let controller = try QuickBrowseWindowController(owner: owner, pageID: id, requestPrimary: {}, requestProfiles: {}, didClose: {})
        let window = controller.window!; controller.surface(); await settle()
        guard window.isKeyWindow, web.window === window, field(window, "Search or enter a URL") != nil else { throw SetupFailure.notReady }
        print("QUICK_FOCUS_FIXTURE_READY")
        for request in 1...3 {
            controller.requestLocation(); await settle()
            check(controller.state.isEditingAddress && focused(window, field(window, "Search or enter a URL"), selected: "about:blank"),
                  "Address focus request \(request) keeps its editor and selects the displayed URL")
            check(controller.activeWebView === web && web.window === window,
                  "Address focus request \(request) preserves the same mounted website")
        }
        _ = window.makeFirstResponder(web); await settle()
        controller.requestLocation(); await settle()
        check(controller.state.isEditingAddress && focused(window, field(window, "Search or enter a URL"), selected: "about:blank"),
              "Address focus after website interaction selects the URL without cancelling editing")
        controller.state.findText = "needle"; controller.state.showFind(); await settle()
        check(focused(window, field(window, "Find in page"), selected: "needle"), "Find focuses and selects its nonempty query")
        controller.state.showFind(); await settle()
        check(focused(window, field(window, "Find in page"), selected: "needle"), "Repeated Find focus keeps the existing query editor")
        controller.state.dismissFind(); controller.requestLocation(); await settle()
        check(controller.state.isEditingAddress && focused(window, field(window, "Search or enter a URL"), selected: "about:blank"),
              "Returning from Find focuses the address without replacing the page")

        let blankID = try store.openQuickPage()
        let blank = try QuickBrowseWindowController(owner: owner, pageID: blankID, requestPrimary: {}, requestProfiles: {}, didClose: {})
        let blankWindow = blank.window!; blank.surface(); await settle()
        check(blank.state.isEditingAddress && focused(blankWindow, field(blankWindow, "Search or enter a URL")),
              "A new blank Quick Browse window automatically focuses its address")
        controller.requestLocation(); await settle()
        check(NSApp.keyWindow === blankWindow && field(window, "Search or enter a URL")?.pendingFocus == true,
              "A background address request waits without stealing the foreground window")
        controller.surface(); await settle()
        check(controller.state.isEditingAddress && focused(window, field(window, "Search or enter a URL"), selected: "about:blank"),
              "A pending address request focuses only after its own window becomes key")
        blank.requestLocation(); blankWindow.close(); await settle()
        check(NSApp.keyWindow === window && focused(window, field(window, "Search or enter a URL")),
              "Closing a window cancels its pending native focus without disturbing another editor")
        let draft = try await web.evaluateJavaScript("document.getElementById('draft').value") as? String
        let token = try await web.evaluateJavaScript("window.focusDocumentToken") as? String
        check(draft == "unsaved focus canary" && token == "owned-document-9472" && controller.activeWebView === web,
              "All focus changes preserve unsaved input and the exact loaded document")
        window.close(); await settle()
        check(owner.isClosed && store.isShuttingDown, "Owned focus fixtures release their private browser owner")
    }
}
@main struct QuickBrowseFocusChecks {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let runner = QuickFocusRunner(); app.delegate = runner; app.run()
    }
}
