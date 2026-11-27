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
        try await actualMenuKeyboardChecks()
    }
}
@main struct QuickBrowseFocusChecks {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let runner = QuickFocusRunner(); app.delegate = runner; app.run()
    }
}

import AppKit
import ScreenCaptureKit
import CryptoKit

private struct OwnedWindowCaptureError: Error, CustomStringConvertible {
    let description: String
}

@MainActor private enum NativeOwnedWindowCapture {
    static func capture(_ window: NSWindow, kind: String, directory: String) async throws {
        guard CGPreflightScreenCaptureAccess() else {
            print("OWNED_WINDOW_CAPTURE_ENVIRONMENT_UNAVAILABLE screenRecordingNotAlreadyGranted")
            throw OwnedWindowCaptureError(description: "Owned-window capture needs an existing Screen Recording grant; no permission was requested or changed")
        }
        guard window.isVisible, window.windowNumber > 0 else {
            throw OwnedWindowCaptureError(description: "The owned native window is not visible")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let pid = ProcessInfo.processInfo.processIdentifier
        guard let owned = content.windows.first(where: {
            $0.windowID == CGWindowID(window.windowNumber) && $0.owningApplication?.processID == pid
        }) else {
            throw OwnedWindowCaptureError(description: "The exact owned window is unavailable to the OS compositor")
        }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(owned.frame.width.rounded(.up))
        configuration.height = Int(owned.frame.height.rounded(.up))
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: owned), configuration: configuration)
        guard image.width >= 400, image.height >= 300,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw OwnedWindowCaptureError(description: "The OS compositor did not return a usable owned-window image")
        }
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let name = kind + "-window.png"
        try png.write(to: root.appendingPathComponent(name), options: .atomic)
        let record: [String: Any] = ["method": "SCScreenshotManager.desktopIndependentWindow",
            "case": kind, "ownedProcessID": pid, "ownedWindowID": owned.windowID,
            "width": image.width, "height": image.height,
            "sha256": SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined(),
            "screenRecordingAlreadyGranted": true]
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent(kind + "-window.json"), options: .atomic)
        print("OWNED_WINDOW_CAPTURE_COMPLETE", kind, image.width, image.height)
    }
}

extension QuickFocusRunner {
    func postKey(_ window: NSWindow, _ key: String, code: UInt16, flags: NSEvent.ModifierFlags = []) throws {
        guard window.isKeyWindow, window.isVisible else { throw SetupFailure.notReady }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: key, charactersIgnoringModifiers: key,
                isARepeat: false, keyCode: code) else { throw SetupFailure.notReady }
            NSApp.postEvent(event, atStart: false)
        }
    }
    func captureQuick(_ window: NSWindow, _ name: String) async throws {
        guard let directory = ProcessInfo.processInfo.environment["ALCOVE_OWNED_WINDOW_CAPTURE_DIR"] else {
            throw SetupFailure.notReady
        }
        try await NativeOwnedWindowCapture.capture(window, kind: name, directory: directory)
    }
    func actualMenuKeyboardChecks() async throws {
        let delegate = AppDelegate()
        let store = BrowserStore(isPrivate: true)
        var appearance = store.appearance; appearance.animationsEnabled = false; appearance.showFavicons = false; store.appearance = appearance
        let owner = delegate.makeOwner(store)
        let id = try store.openQuickPage(url: URL(string: "about:blank")!)
        delegate.syncQuickWindows(owner)
        guard let controller = delegate.quickWindows[QuickWindowKey(ownerID: owner.id, pageID: id)],
              let window = controller.window else { throw SetupFailure.notReady }
        let web = store.view(for: id)
        web.loadHTMLString("<html><meta name='color-scheme' content='light dark'><style>body{font:18px system-ui;padding:24px;background:#e7eff5;color:#142638}input{font:16px system-ui}</style><h1>Owned Quick Browse page</h1><input id='draft' value='unsaved Quick Browse draft'><p>needle belongs to this page.</p></html>", baseURL: nil)
        for _ in 0..<200 {
            if (try? await web.evaluateJavaScript("document.getElementById('draft')?.value") as? String) == "unsaved Quick Browse draft" { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        guard (try? await web.evaluateJavaScript("document.getElementById('draft')?.value") as? String) == "unsaved Quick Browse draft" else { throw SetupFailure.notReady }
        _ = try await web.evaluateJavaScript("window.quickKeyboardToken=9472")
        delegate.buildMenu(); controller.surface(); await settle()
        _ = window.makeFirstResponder(web); await settle()
        for attempt in 1...3 {
            try postKey(window, "l", code: 37, flags: .command); await settle()
            check(controller.state.isEditingAddress && focused(window, field(window, "Search or enter a URL"), selected: "about:blank"),
                  "Actual menu Cmd-L request \(attempt) selects the visible Quick Browse location")
        }
        try await captureQuick(window, "quick-location-selected")
        try postKey(window, "x", code: 7); await settle()
        check(controller.state.addressText == "x" && field(window, "Search or enter a URL")?.currentEditor()?.string == "x",
              "Typing after actual Cmd-L replaces the selected URL in the retained editor")
        try postKey(window, "\u{1b}", code: 53); await settle()
        check(!controller.state.isEditingAddress && controller.activeWebView === web,
              "Actual Escape cancels the typed location without replacing the live page")
        try await captureQuick(window, "quick-location-cancelled")

        try postKey(window, "f", code: 3, flags: .command); await settle()
        check(controller.state.findVisible && focused(window, field(window, "Find in page")),
              "Actual menu Cmd-F focuses Quick Browse Find")
        for (key, code) in [("n", UInt16(45)), ("e", 14), ("e", 14), ("d", 2), ("l", 37), ("e", 14)] {
            try postKey(window, key, code: code)
        }
        await settle()
        check(controller.state.findText == "needle", "Actual Find typing reaches the native query editor")
        try await captureQuick(window, "quick-find-query")
        try postKey(window, "l", code: 37, flags: .command); await settle()
        check(!controller.state.findVisible && controller.state.isEditingAddress && focused(window, field(window, "Search or enter a URL"), selected: "about:blank"),
              "Actual Cmd-L moves from Find to the selected location")
        let draft = try await web.evaluateJavaScript("document.getElementById('draft').value") as? String
        let token = try await web.evaluateJavaScript("window.quickKeyboardToken") as? Int
        check(draft == "unsaved Quick Browse draft" && token == 9472 && controller.activeWebView === web,
              "Real menu shortcuts and typing preserve the exact website and unsaved form")

        let otherID = try store.openQuickPage()
        delegate.syncQuickWindows(owner)
        guard let other = delegate.quickWindows[QuickWindowKey(ownerID: owner.id, pageID: otherID)],
              let otherWindow = other.window else { throw SetupFailure.notReady }
        other.surface(); await settle()
        check(other.state.isEditingAddress && focused(otherWindow, field(otherWindow, "Search or enter a URL")),
              "A real second blank Quick Browse window begins with a focused location")
        try await captureQuick(otherWindow, "quick-blank-location")
        try postKey(otherWindow, "w", code: 13, flags: .command); await settle()
        check(store.quickPage(otherID) == nil && !otherWindow.isVisible && window.isVisible && !owner.isClosed,
              "Actual Cmd-W closes only its Quick Browse window and preserves the other window")
        controller.surface(); await settle()
        try postKey(window, "w", code: 13, flags: .command); await settle()
        check(!window.isVisible && owner.isClosed && store.isShuttingDown && NSApp.isRunning,
              "Actual Cmd-W on the final compact window closes its owner while the application keeps running")
        NSApp.mainMenu = nil; NSApp.windowsMenu = nil
    }
}
