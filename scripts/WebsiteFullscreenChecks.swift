import AppKit
import WebKit
import BrowserCore
import Darwin

/// Actual WebKit presentations in disposable windows; no desktop-wide input or user data.
@main struct WebsiteFullscreenChecks {
    enum Failure: Error { case timeout(String), fixture(String) }
    @MainActor static var checks = 0
    @MainActor static var failures = 0

    @MainActor static func check(_ value: Bool, _ label: String) {
        checks += 1
        if !value { failures += 1 }
        print("\(value ? "PASS" : "FAIL"): \(label)")
    }

    @MainActor static func wait(_ label: String, _ condition: @escaping @MainActor () async throws -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(12))
        while clock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure.timeout(label)
    }

    @MainActor static func residency(_ label: String, web: WKWebView, host: EdgeToEdgeWebHost, window: NSWindow) {
        print("FULLSCREEN_RESTORATION", label, "state", web.fullscreenState.rawValue,
              "originalHost", web.superview === host, "originalWindow", web.window === window,
              "parent", web.superview.map { String(describing: type(of: $0)) } ?? "none",
              "hostChildren", host.subviews.map { String(describing: type(of: $0)) },
              "borrowed", (web as? SplitDropWebView)?.websiteFullscreen?.isBorrowed ?? false)
    }

    @MainActor static func enter(_ web: WKWebView, target: String) async throws {
        _ = try await web.callAsyncJavaScript("""
            window.ownedFullscreenResult = 'requesting';
            document.getElementById(target).requestFullscreen()
                .then(() => window.ownedFullscreenResult = 'entered')
                .catch(error => window.ownedFullscreenResult = error.name + ': ' + error.message);
            return true;
            """, arguments: ["target": target], in: nil, contentWorld: .page)
        do {
            try await wait("genuine \(target) fullscreen") { web.fullscreenState == .inFullscreen }
        } catch {
            print("FULLSCREEN_ENTRY_FAILURE", target, "state", web.fullscreenState.rawValue,
                  "page", (try? await web.evaluateJavaScript("window.ownedFullscreenResult")) ?? "unavailable")
            throw error
        }
    }

    @MainActor static func leave(_ web: WKWebView) async throws {
        let presentationWindow = web.window
        // The independent stock control proves this normal document exit returns
        // the view. On the qualified hosted OS closeAllMediaPresentations instead
        // reports state 0 while leaving the view in a detached native container.
        _ = try await web.callAsyncJavaScript("""
            if (document.fullscreenElement) await Document.prototype.exitFullscreen.call(document);
            return true;
            """, contentWorld: .defaultClient)
        try await wait("coordinated fullscreen exit") {
            web.fullscreenState == .notInFullscreen && (web as? SplitDropWebView)?.websiteFullscreen?.isBorrowed != true
        }
        check(presentationWindow != nil && presentationWindow?.isVisible == false,
              "Completed fullscreen restoration waits for WebKit's presentation window to disappear")
    }

    @MainActor static func exercise(base: URL, target: String, replaceHost: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alcove-fullscreen-owned-" + UUID().uuidString)
        let store = BrowserStore(isPrivate: true, dataRoot: root)
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        let id = store.newTab()
        let config = WKWebViewConfiguration()
        config.preferences.isElementFullscreenEnabled = true // Explicit diagnostic control; production checked separately.
        config.mediaTypesRequiringUserActionForPlayback = []
        let web = store.view(for: id, configuration: config)
        let host = EdgeToEdgeWebHost(frame: NSRect(x: 0, y: 0, width: 960, height: 680))
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Alcove owned fullscreen regression"
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { web.closeAllMediaPresentations(completionHandler: nil); window.contentView = nil; window.close() }
        WebPane(webView: web, store: store).mount(in: host)
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        try await wait("owned window focus") { NSApp.isActive && window.isKeyWindow }
        web.load(URLRequest(url: base.appendingPathComponent("page")))
        try await wait("owned fixture document") {
            guard !web.isLoading else { return false }
            return (try? await web.evaluateJavaScript("document.getElementById('draft')!==null")) as? Bool == true
        }
        if target == "video" {
            try await wait("owned video decoded") {
                (try? await web.evaluateJavaScript("document.getElementById('video').readyState>=2")) as? Bool == true
            }
            _ = try await web.callAsyncJavaScript("await document.getElementById('video').play(); return true;", contentWorld: .page)
        }
        _ = try await web.evaluateJavaScript("""
            document.getElementById('draft').value='unsaved fullscreen draft';
            window.ownedDocumentToken = crypto.randomUUID();
            history.pushState({owned: true}, '', '#owned');
            window.scrollTo(0, 320); true;
            """)
        let snapshot = "JSON.stringify({token:window.ownedDocumentToken,draft:document.getElementById('draft').value,scroll:scrollY,history:history.length,href:location.href})"
        let before = try await web.evaluateJavaScript(snapshot) as? String
        let document = store.documentIdentity(for: web)
        var transitions: [Int] = []
        let observation = web.observe(\.fullscreenState, options: [.new]) { view, _ in
            print("FULLSCREEN_TRANSITION", target, view.fullscreenState.rawValue)
        }
        defer { observation.invalidate() }
        transitions.append(web.fullscreenState.rawValue)
        try await enter(web, target: target)
        transitions.append(web.fullscreenState.rawValue)
        let presentationWindow = web.window
        let placeholder = host.subviews.first
        print("FULLSCREEN_RESIDENCY", target, "replacement", replaceHost, "borrowed", web.superview !== host,
              "separateWindow", presentationWindow !== window, "placeholder", placeholder.map { String(describing: type(of: $0)) } ?? "none")
        check(web.superview !== host && presentationWindow != nil && presentationWindow !== window,
              "\(target): real WebKit fullscreen borrows the website into its native presentation window")
        check(placeholder != nil && placeholder !== web, "\(target): original host retains WebKit's restoration placeholder")
        let destination: EdgeToEdgeWebHost
        if replaceHost {
            destination = EdgeToEdgeWebHost(frame: NSRect(x: 0, y: 0, width: 810, height: 570))
            window.contentView = destination
        } else {
            destination = host
            host.setFrameSize(NSSize(width: 830, height: 590))
        }
        WebPane(webView: web, store: store).mount(in: destination)
        destination.layoutSubtreeIfNeeded()
        check(web.window === presentationWindow && web.superview !== destination && web.fullscreenState == .inFullscreen,
              "\(target): \(replaceHost ? "replacement host" : "SwiftUI remount and resize") does not reclaim WebKit's borrowed view")
        try await leave(web)
        do {
            try await wait("website restored to latest host") { web.superview === destination && web.window === window }
        } catch {
            residency("failed \(target)", web: web, host: destination, window: window)
            throw error
        }
        residency("restored \(target)", web: web, host: destination, window: window)
        destination.layoutSubtreeIfNeeded()
        check(web.frame == destination.bounds && web.bounds.width > 0 && web.bounds.height > 0,
              "\(target): exit restores a usable viewport in the latest intended host")
        check(store.views[id] === web && store.documentIdentity(for: web) === document,
              "\(target): fullscreen preserves the exact registered view and document identity")
        check((try await web.evaluateJavaScript(snapshot) as? String) == before,
              "\(target): fullscreen and remount preserve the actual document token, unsaved form, scroll and history")
        print("FULLSCREEN_CASE_COMPLETED", target, "replacement", replaceHost, "states", transitions)
    }

    @MainActor static func run() async -> Int32 {
        var displays: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displays)
        print("FULLSCREEN_ACTIVE_DISPLAYS", displays)
        guard displays > 0, let input = ProcessInfo.processInfo.environment["ALCOVE_FULLSCREEN_FIXTURE_URL"],
              let base = URL(string: input), base.host == "127.0.0.1" else {
            print("FULLSCREEN_ENVIRONMENT_UNAVAILABLE"); return 2
        }
        if let selection = ProcessInfo.processInfo.environment["ALCOVE_FULLSCREEN_COMMAND_CASES"], !selection.isEmpty {
            print("FULLSCREEN_SELECTION_COMMANDS_ONLY", selection)
            if #available(macOS 15.4, *) {
                do { try await exerciseCommands(base: base) }
                catch { failures += 1; print("FULLSCREEN_COMMAND_SETUP_ERROR", error) }
            } else { failures += 1; print("FULLSCREEN_COMMAND_OS_UNAVAILABLE") }
            print("WEBSITE_FULLSCREEN_CHECKS", checks, "FAILURES", failures)
            return failures == 0 ? 0 : 1
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alcove-fullscreen-preference-" + UUID().uuidString)
        let production = BrowserStore(isPrivate: true, dataRoot: root)
        let id = production.newTab()
        check(production.view(for: id).configuration.preferences.isElementFullscreenEnabled,
              "Production website configuration enables genuine element fullscreen")
        production.shutdown(); try? FileManager.default.removeItem(at: root)
        for (target, replace) in [("element", false), ("video", false), ("element", true)] {
            do { try await exercise(base: base, target: target, replaceHost: replace) }
            catch { failures += 1; print("FULLSCREEN_CASE_ERROR", target, "replacement", replace, error) }
        }
        if failures == 0 {
            if #available(macOS 15.4, *) {
                do { try await exerciseContexts(base: base) }
                catch { failures += 1; print("FULLSCREEN_CONTEXT_SETUP_ERROR", error) }
                do { try await exerciseCommands(base: base) }
                catch { failures += 1; print("FULLSCREEN_COMMAND_SETUP_ERROR", error) }
            }
        }
        print("WEBSITE_FULLSCREEN_CHECKS", checks, "FAILURES", failures)
        return failures == 0 ? 0 : 1
    }

    @MainActor static func main() {
        setbuf(stdout, nil)
        NSApplication.shared.setActivationPolicy(.regular)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(300))
            print("WEBSITE_FULLSCREEN_WATCHDOG_TIMEOUT"); exit(3)
        }
        Task { @MainActor in exit(await run()) }
        NSApp.run()
        print("WEBSITE_FULLSCREEN_RUN_LOOP_RETURNED"); exit(86)
    }
}
