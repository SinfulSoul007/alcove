import AppKit
import SwiftUI
import WebKit

@MainActor private final class FullscreenTransition: NSObject, NSWindowDelegate {
    var entered = 0
    var exited = 0
    var failed = false
    func windowDidEnterFullScreen(_ notification: Notification) { entered += 1 }
    func windowDidExitFullScreen(_ notification: Notification) { exited += 1 }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { failed = true }
    func windowDidFailToExitFullScreen(_ window: NSWindow) { failed = true }
}

/// Opt-in real GUI integration check. Uses an owned native window and ephemeral
/// local HTML only; never reads a browser profile or touches Keychain.
@MainActor private final class FullscreenChecks: NSObject, NSApplicationDelegate {
    var failures = 0
    func check(_ ok: Bool, _ name: String) {
        print("\(ok ? "PASS" : "FAIL"): \(name)")
        if !ok { failures += 1 }
    }
    func settle() async { for _ in 0..<8 { try? await Task.sleep(for: .milliseconds(15)) } }
    func window() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 30, y: 80, width: 1000, height: 650), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false; w.collectionBehavior = .fullScreenPrimary
        return w
    }
    func fullscreen(_ value: Bool, _ w: NSWindow, _ transition: FullscreenTransition) async -> Bool {
        let count = value ? transition.entered : transition.exited
        transition.failed = false
        w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        w.toggleFullScreen(nil)
        for _ in 0..<400 {
            if transition.failed { return false }
            if (value ? transition.entered : transition.exited) > count {
                await settle(); return w.styleMask.contains(.fullScreen) == value
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        setbuf(stdout, nil)
        Task { @MainActor in await run(); exit(failures == 0 ? 0 : 1) }
    }
    func run() async {
        let chrome = NativeWindowChrome()
        var original: NSWindow? = window()
        let transition = FullscreenTransition(); original!.delegate = transition
        let reader = NativeChromeReader.Host(chrome: chrome)
        original!.contentView = reader
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: reader.bounds, configuration: configuration)
        web.autoresizingMask = [.width, .height]; reader.addSubview(web)
        web.loadHTMLString("<html><body><input id='value' value='keep my form'></body></html>", baseURL: nil)
        original!.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        for _ in 0..<200 {
            if (try? await web.evaluateJavaScript("document.getElementById('value')?.value") as? String) == "keep my form" { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        check((try? await web.evaluateJavaScript("document.getElementById('value')?.value") as? String) == "keep my form", "Owned local form is ready before fullscreen checks")
        let ownedToolbar = original!.toolbar!
        check(ownedToolbar.isVisible && chrome.height >= 32, "Normal native chrome reserves a usable traffic-light row")
        for cycle in 1...2 {
            guard await fullscreen(true, original!, transition) else { check(false, "Actual fullscreen entry completes"); return }
            let top = reader.convert(reader.bounds, to: nil).maxY
            check(!ownedToolbar.isVisible && abs(original!.contentLayoutRect.maxY - top) <= 0.5,
                  "Actual fullscreen cycle \(cycle) leaves top content unobscured by the empty toolbar")
            let formValue = try? await web.evaluateJavaScript("document.getElementById('value')?.value") as? String
            check(web.window === original && formValue == "keep my form",
                  "Actual fullscreen cycle \(cycle) preserves the mounted web form")
            guard await fullscreen(false, original!, transition) else { check(false, "Actual fullscreen exit completes"); return }
            let close = original!.standardWindowButton(.closeButton)!
            let closeRect = close.convert(close.bounds, to: reader)
            let center = reader.isFlipped ? closeRect.midY : reader.bounds.maxY - closeRect.midY
            check(ownedToolbar.isVisible && abs(chrome.height / 2 - center) <= 0.5,
                  "Actual fullscreen cycle \(cycle) restores measured native-button alignment")
        }
        for initiallyVisible in [true, false] {
            let borrowedWindow = window(); let borrowedTransition = FullscreenTransition(); borrowedWindow.delegate = borrowedTransition
            let toolbar = NSToolbar(identifier: "OwnedFixture.\(initiallyVisible)")
            borrowedWindow.toolbar = toolbar; toolbar.isVisible = initiallyVisible
            original!.contentView = nil; borrowedWindow.contentView = reader; await settle()
            guard await fullscreen(true, borrowedWindow, borrowedTransition) else { check(false, "Borrowed window fullscreen entry completes"); return }
            check(toolbar.isVisible == initiallyVisible, "A caller's \(initiallyVisible ? "visible" : "hidden") toolbar retains visibility in fullscreen")
            guard await fullscreen(false, borrowedWindow, borrowedTransition) else { check(false, "Borrowed window fullscreen exit completes"); return }
            check(toolbar.isVisible == initiallyVisible, "A caller's toolbar retains its original visibility after exit")
            borrowedWindow.contentView = nil; borrowedWindow.close()
        }
        original!.contentView = reader; await settle()
        guard await fullscreen(true, original!, transition) else { check(false, "Returning reader fullscreen entry completes"); return }
        check(ownedToolbar.isVisible == false, "Returning a reader to its original window still uncovers fullscreen navigation")
        guard await fullscreen(false, original!, transition) else { check(false, "Returning reader fullscreen exit completes"); return }
        original!.contentView = nil
        let next = window(); let nextTransition = FullscreenTransition(); next.delegate = nextTransition
        next.contentView = reader; await settle()
        guard await fullscreen(true, next, nextTransition) else { check(false, "Reattached window fullscreen entry completes"); return }
        check(next.toolbar?.isVisible == false && ownedToolbar.isVisible,
              "Moving a chrome reader reconciles only the new window's owned toolbar")
        original!.close(); original = nil; await settle()
        guard await fullscreen(false, next, nextTransition) else { check(false, "Reattached window fullscreen exit completes"); return }
        check(next.toolbar?.isVisible == true, "The reattached window restores normal toolbar visibility")
        next.contentView = nil; next.close()
    }
}
@main struct NativeChromeFullscreenChecks {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let checks = FullscreenChecks(); app.delegate = checks; app.run()
    }
}
