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
        writer.finishOnboarding(); writer.preferences.automaticUpdateChecks = false
        let profile = try writer.createProfile(name: "Owned fullscreen commands")
        try owned.register(profile)
        for item in writer.profiles where item.id == profile {
            if let controller = item.extensionControllerID { try controllers.register(controller) }
        }
        let id = writer.newTab(url: base.appendingPathComponent(kind == "reader" ? "article" : "page"))
        var outputSource: WKWebView?, outputWindow: NSWindow?, outputFormat: PageOutputFormat?
        var outputCalls = 0, outputErrors: [String] = []
        var environment = PageOutputEnvironment.live
        // Actual page capture remains native. Only the user-owned destination
        // and print-panel boundaries are witnessed/cancelled by this fixture.
        let nativeCapture = environment.capture
        environment.capture = { source, format, done in
            outputSource = source; nativeCapture(source, format, done)
        }
        environment.choose = { window, _, format, done in
            outputWindow = window; outputFormat = format; outputCalls += 1
            done(nil); return {}
        }
        environment.print = { source, window, done in
            outputSource = source; outputWindow = window; outputCalls += 1
            _ = PageOutputNative.printOperation(for: source)
            done(false); return {}
        }
        environment.reportError = { message, _ in outputErrors.append(message) }
        environment.reportOrphanedError = { outputErrors.append($0) }
        let app = AppDelegate(pageOutput: PageOutputCoordinator(environment: environment)), owner = app.makeOwner(writer)
        app.normalOwner = owner // Even a broken fallback can only open this owned profile.
        defer { owner.shutdown(); writer.shutdown(); try? FileManager.default.removeItem(at: root) }
        app.openPrimary(owner)
        guard let window = app.normalWindow, let store = app.windows[window], store.activeProfileID == profile else {
            throw Failure.fixture("real owned browser window")
        }
        window.title = "Alcove owned fullscreen \(kind)"
        let underlying = store.view(for: id)
        var web = underlying
        var targetID = id
        if kind == "peek-escape" {
            store.openPeek(base.appendingPathComponent("page"), from: underlying)
            guard let peek = store.primaryPeekView else { throw Failure.fixture("command Peek") }
            web = peek
        } else {
            if kind == "close" {
                targetID = store.newTab(url: base.appendingPathComponent("page"))
                web = store.view(for: targetID)
            }
        }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        var caught: Error?
        do {
            try await wait("real browser website host") { web.window === window && web.superview is EdgeToEdgeWebHost }
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
                    let opened = await effect { store.commandVisible && web.window === window && window.firstResponder is NSTextView && (web as? SplitDropWebView)?.websiteFullscreen?.isBorrowed == false }
                    check(opened && app.windows.count == 1, "Cmd-L leaves fullscreen and opens the captured address field without creating another window")
                } else {
                    check(false, "Cmd-L requires its captured routing context before address UI can be delivered")
                }
                store.dismissCommand()
            case "find":
                app.find()
                let opened = await effect { store.findVisible && web.window === window && window.firstResponder is NSTextView && (web as? SplitDropWebView)?.websiteFullscreen?.isBorrowed == false }
                check(opened && store.documentIdentity(for: web) === document, "Cmd-F leaves fullscreen and searches its captured live page")
                store.findVisible = false
            case "reader":
                let menu = NSMenuItem(title: "Show Reader", action: #selector(AppDelegate.toggleReader), keyEquivalent: "")
                check(app.validateMenuItem(menu), "Reader remains available for the captured fullscreen article")
                app.toggleReader()
                let opened = await effect {
                    store.readerSession(for: web)?.state == .ready && web.window === window &&
                    (web as? SplitDropWebView)?.websiteFullscreen?.isBorrowed == false
                }
                let reader = store.readerSession(for: web)
                check(opened && !presentation.isVisible && reader?.window === window && reader?.reader.window === window,
                      "Reader leaves native fullscreen and mounts in the original browser window")
                let draft = try await web.evaluateJavaScript("document.getElementById('draft').value==='captured command draft'&&window.ownedCommandToken===41") as? Bool
                check(opened && store.documentIdentity(for: web) === document && draft == true,
                      "Fullscreen Reader preserves the exact original article, document and unsaved form")
                reader?.dismiss(restoringFocus: true)
            case "print", "pdf", "archive":
                let action = kind == "print" ? #selector(AppDelegate.printPage) : kind == "pdf" ? #selector(AppDelegate.exportPDF) : #selector(AppDelegate.savePage)
                let menu = NSMenuItem(title: "Output", action: action, keyEquivalent: "")
                check(app.validateMenuItem(menu), "\(kind): page-output menu remains available during native fullscreen")
                let command: PageOutputCommand = kind == "print" ? .printPage : kind == "pdf" ? .pdf : .webArchive
                app.performPageOutput(command, in: presentation)
                let delivered = await effect { outputCalls == 1 }
                check(delivered && outputSource === web && outputWindow === window && !presentation.isVisible &&
                      web.window === window && (web as? SplitDropWebView)?.websiteFullscreen?.isBorrowed == false,
                      "\(kind): native page output reaches its boundary only after restoring the captured browser window")
                check(delivered && outputErrors.isEmpty && (kind == "print" || outputFormat == (kind == "pdf" ? .pdf : .webArchive)) &&
                      store.documentIdentity(for: web) === document && !app.pageOutput.isBusy(in: window),
                      "\(kind): cancelling the captured output boundary preserves the document and releases its job")
            case "customize", "settings", "library":
                if kind == "customize" { app.customize() }
                else if kind == "settings" { app.settings() }
                else { app.showLibrary() }
                let delivered = await effect {
                    let visible = kind == "customize" ? store.appearanceVisible : kind == "settings" ? store.settingsVisible : store.libraryVisible
                    return visible && web.window === window && !presentation.isVisible &&
                        (web as? SplitDropWebView)?.websiteFullscreen?.isBorrowed == false
                }
                check(delivered && app.windows.count == 1 && store.documentIdentity(for: web) === document,
                      "\(kind): browser chrome opens after restoring its existing window and live page")
                store.appearanceVisible = false; store.settingsVisible = false; store.libraryVisible = false
            case "close":
                app.closeTab()
                let closed = await effect { store.views[targetID] == nil && web.fullscreenState == .notInFullscreen && !presentation.isVisible }
                check(closed && window.isVisible && store.tab(id) != nil, "Cmd-W exits fullscreen and closes only the captured tab while another page remains")
                if closed {
                    store.select(id)
                    try await wait("real survivor browser host") { underlying.window === window && underlying.superview is EdgeToEdgeWebHost }
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
        for kind in ["escape", "peek-escape", "location", "find", "close", "reader", "print", "pdf", "archive", "customize", "settings", "library"] {
            do { try await exerciseCommand(base: base, kind: kind, owned: owned, controllers: controllers) }
            catch { failures += 1; print("FULLSCREEN_COMMAND_CASE_ERROR", kind, error) }
        }
        let a = await controllers.cleanup(), b = await owned.cleanup()
        check(a && b, "Native command fixtures release and erase all owned website/extension stores")
        print("FULLSCREEN_COMMAND_CLEANUP", a, b)
    }
}
