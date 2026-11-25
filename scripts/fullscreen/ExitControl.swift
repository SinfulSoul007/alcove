import AppKit
import WebKit
import Darwin

/// Independent public-API control: no Alcove store, subclass or host behavior.
@main struct FullscreenExitControl {
    enum Failure: Error { case timeout(String) }
    @MainActor static func wait(_ label: String, _ condition: @escaping @MainActor () async -> Bool) async throws {
        let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: .seconds(12))
        while clock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure.timeout(label)
    }
    @MainActor static func exercise(_ method: String) async throws -> Bool {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent(); config.preferences.isElementFullscreenEnabled = true
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        let web = WKWebView(frame: host.bounds, configuration: config)
        web.autoresizingMask = [.width, .height]; host.addSubview(web)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "Alcove owned stock WebKit exit control"
        window.contentView = host; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        defer { web.closeAllMediaPresentations(completionHandler: nil); window.contentView = nil; window.close() }
        web.loadHTMLString("<div id='element' style='width:500px;height:300px;background:navy;color:white'>Owned fullscreen exit control</div>", baseURL: nil)
        try await wait("owned stock WebKit document") {
            (try? await web.evaluateJavaScript("document.getElementById('element')!==null")) as? Bool == true
        }
        try await wait("owned stock window active") { window.isKeyWindow && NSApp.isActive }
        _ = try await web.callAsyncJavaScript("document.getElementById('element').requestFullscreen();return true;", contentWorld: .page)
        try await wait("stock WebKit genuine entry") { web.fullscreenState == .inFullscreen }
        print("STOCK_EXIT_ENTRY", method, "borrowed", web.superview !== host, "differentWindow", web.window !== window)
        if method == "document.exitFullscreen" {
            _ = try await web.callAsyncJavaScript("await document.exitFullscreen();return true;", contentWorld: .page)
        } else {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                web.closeAllMediaPresentations { continuation.resume() }
            }
        }
        do {
            try await wait("stock WebKit physical restoration") { web.fullscreenState == .notInFullscreen && web.superview === host && web.window === window }
        } catch {
            print("STOCK_EXIT_RESULT", method, "restored", false, "state", web.fullscreenState.rawValue,
                  "parent", web.superview.map { String(describing: type(of: $0)) } ?? "none",
                  "hostChildren", host.subviews.map { String(describing: type(of: $0)) },
                  "documentFullscreen", (try? await web.evaluateJavaScript("Boolean(document.fullscreenElement)")) ?? "unavailable")
            return false
        }
        print("STOCK_EXIT_RESULT", method, "restored", true, "state", web.fullscreenState.rawValue)
        return true
    }
    @MainActor static func main() {
        setbuf(stdout, nil); NSApplication.shared.setActivationPolicy(.regular)
        Task { @MainActor in try? await Task.sleep(for: .seconds(65)); print("STOCK_EXIT_WATCHDOG"); exit(3) }
        Task { @MainActor in
            var failures = 0
            for method in ["document.exitFullscreen", "closeAllMediaPresentations"] {
                do { if try await !exercise(method) { failures += 1 } }
                catch { failures += 1; print("STOCK_EXIT_ERROR", method, error) }
            }
            print("STOCK_EXIT_CONTROL_FAILURES", failures); exit(failures == 0 ? 0 : 1)
        }
        NSApp.run(); exit(86)
    }
}
