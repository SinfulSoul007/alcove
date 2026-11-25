import AppKit
import WebKit
import CryptoKit
import BrowserCore

extension WebsiteFullscreenChecks {
    @MainActor static func effect(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        do { try await wait("captured native command effect") { condition() }; return true }
        catch { return false }
    }

    @available(macOS 15.4, *) @MainActor
    static func exerciseCommand(base: URL, kind: String, owned: OwnedWebsiteStores,
                                controllers: OwnedExtensionControllers) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alcove-fullscreen-command-" + UUID().uuidString)
        let writer = BrowserStore(dataRoot: root, keyProvider: { _ in SymmetricKey(data: Data(repeating: 87, count: 32)) })
        let app = AppDelegate(), owner = app.makeOwner(writer)
        app.normalOwner = owner // Even a broken fallback can only open this owned profile.
        let primary = try owner.acquirePrimaryStore(), store = primary.store
        defer { owner.shutdown(); writer.shutdown(); try? FileManager.default.removeItem(at: root) }
        let profile = try store.createProfile(name: "Owned fullscreen commands")
        try owned.register(profile)
        for item in store.profiles where item.id == profile {
            if let controller = item.extensionControllerID { try controllers.register(controller) }
        }
        store.finishOnboarding()
        let id = store.newTab(url: base.appendingPathComponent("page")), underlying = store.view(for: id)
        let host = EdgeToEdgeWebHost(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "Alcove owned fullscreen \(kind)"
        window.contentView = host; window.delegate = app
        app.windows[window] = store; app.primaryOwners[window] = owner; app.primaryLeases[window] = primary.lease
        var web = underlying
        var targetID = id
        if kind == "peek-escape" {
            WebPane(webView: underlying, store: store).mount(in: host)
            store.openPeek(base.appendingPathComponent("page"), from: underlying)
            guard let peek = store.primaryPeekView else { throw Failure.fixture("command Peek") }
            web = peek
            let peekHost = EdgeToEdgeWebHost(frame: host.bounds.insetBy(dx: 60, dy: 40))
            host.addSubview(peekHost); WebPane(webView: web, store: store).mount(in: peekHost)
        } else {
            if kind == "close" {
                targetID = store.newTab(url: base.appendingPathComponent("page"))
                web = store.view(for: targetID)
            }
            WebPane(webView: web, store: store).mount(in: host)
        }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        var caught: Error?
        do {
            try await wait("command source decoded") {
                guard !web.isLoading else { return false }
                return (try? await web.evaluateJavaScript("document.getElementById('video')?.readyState>=2")) as? Bool == true
            }
            _ = try await web.evaluateJavaScript("document.getElementById('draft').value='captured command draft';window.ownedCommandToken=41;true")
            let document = store.documentIdentity(for: web)
            try await enter(web, target: "element")
            guard let presentation = web.window, presentation !== window else { throw Failure.fixture("command presentation") }
            try await wait("command native window key") { presentation.isKeyWindow }
            let routed = app.browserStore(in: presentation) === store && app.activeStore === store && app.activeWebView === web
            check(routed, "\(kind): native fullscreen command routing retains the actual page and store")
            check(app.activeBrowserWindow === window, "\(kind): native fullscreen resolves to its captured logical browser window")
            check(app.outputTarget(in: presentation)?.web === web,
                  "\(kind): page-output selection retains the fullscreen source")
            switch kind {
            case "escape", "peek-escape":
                let first = app.handleEscape(in: presentation), second = app.handleEscape(in: presentation)
                check(first && second, "\(kind): repeated Escape is handled while the same fullscreen exit is pending")
                let exited = await effect { web.fullscreenState == .notInFullscreen && (web as? SplitDropWebView)?.websiteFullscreen?.isBorrowed == false }
                check(exited && !presentation.isVisible && web.window === window,
                      "\(kind): Escape exits the actual native presentation and restores its original window")
                if kind == "peek-escape" {
                    check(store.primaryPeekView === web, "Escape exits fullscreen before closing the underlying Peek")
                } else {
                    check(store.views[id] === web && window.isVisible, "Escape preserves its original tab and browser window")
                }
                let originalDraft = try await web.evaluateJavaScript("document.getElementById('draft').value==='captured command draft'&&window.ownedCommandToken===41") as? Bool
                check(exited && store.documentIdentity(for: web) === document && originalDraft == true,
                      "\(kind): Escape preserves the exact original draft and document")
            case "location":
                if routed {
                    app.location(); app.location()
                    let opened = await effect { store.commandVisible && web.window === window && (web as? SplitDropWebView)?.websiteFullscreen?.isBorrowed == false }
                    check(opened && app.windows.count == 1, "Cmd-L leaves fullscreen and opens the captured address field without creating another window")
                } else {
                    check(false, "Cmd-L requires its captured routing context before address UI can be delivered")
                }
                store.dismissCommand()
            case "find":
                app.find()
                let opened = await effect { store.findVisible && web.window === window && (web as? SplitDropWebView)?.websiteFullscreen?.isBorrowed == false }
                check(opened && store.documentIdentity(for: web) === document, "Cmd-F leaves fullscreen and searches its captured live page")
                store.findVisible = false
            case "close":
                app.closeTab()
                let closed = await effect { store.views[targetID] == nil && web.fullscreenState == .notInFullscreen && !presentation.isVisible }
                check(closed && window.isVisible && store.tab(id) != nil, "Cmd-W exits fullscreen and closes only the captured tab while another page remains")
                if closed {
                    store.select(id); WebPane(webView: underlying, store: store).mount(in: host)
                    try await wait("remaining page decoded") { (try? await underlying.evaluateJavaScript("document.getElementById('video')?.readyState>=2")) as? Bool == true }
                    try await enter(underlying, target: "element")
                    app.closeTab()
                    let windowClosed = await effect { !window.isVisible && underlying.fullscreenState == .notInFullscreen }
                    check(windowClosed && app.windows[window] == nil, "Cmd-W on the last real tab exits fullscreen and closes its browser window")
                    check(windowClosed && NSApp.isRunning && !app.applicationShouldTerminateAfterLastWindowClosed(NSApp),
                          "Closing the last fullscreen tab leaves the browser application running")
                } else {
                    check(false, "Last-tab close remains unqualified while captured tab close fails")
                }
            default: throw Failure.fixture("unknown native command")
            }
        } catch { caught = error }

        // Recover using the independently qualified document exit, only after
        // observing each command's own result. Recovery never turns a failure green.
        let remaining = [underlying, web] + Array(store.views.values) + store.peekPages.values.map(\.web)
        for page in remaining where page.fullscreenState != .notInFullscreen || (page as? SplitDropWebView)?.websiteFullscreen?.isBorrowed == true {
            do { try await leave(page) }
            catch { failures += 1; print("FULLSCREEN_COMMAND_RECOVERY_ERROR", kind, error) }
        }
        for ownedWindow in Array(app.windows.keys) { ownedWindow.performClose(nil) }
        app.windows.removeAll(); app.primaryOwners.removeAll(); app.primaryLeases.removeAll()
        if let caught { throw caught }
        print("FULLSCREEN_COMMAND_CASE_COMPLETED", kind)
    }

    @available(macOS 15.4, *) @MainActor
    static func exerciseCommands(base: URL) async throws {
        let owned = try OwnedWebsiteStores(), controllers = try OwnedExtensionControllers()
        guard await controllers.cleanup(), await owned.cleanup() else { throw Failure.fixture("command ownership recovery") }
        for kind in ["escape", "peek-escape", "location", "find", "close"] {
            do { try await exerciseCommand(base: base, kind: kind, owned: owned, controllers: controllers) }
            catch { failures += 1; print("FULLSCREEN_COMMAND_CASE_ERROR", kind, error) }
        }
        let a = await controllers.cleanup(), b = await owned.cleanup()
        check(a && b, "Native command fixtures release and erase all owned website/extension stores")
        print("FULLSCREEN_COMMAND_CLEANUP", a, b)
    }
}
