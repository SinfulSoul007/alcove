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
                                controllers: OwnedExtensionControllers, isPrivate: Bool = false, isQuick: Bool = false) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alcove-fullscreen-command-" + UUID().uuidString)
        var keyReads = 0
        let writer = BrowserStore(isPrivate: isPrivate, dataRoot: root, keyProvider: { _ in
            keyReads += 1; return SymmetricKey(data: Data(repeating: 87, count: 32))
        })
        writer.finishOnboarding(); writer.preferences.automaticUpdateChecks = false
        let profile: UUID
        if isPrivate { profile = BrowserProfile.defaultID }
        else {
            profile = try writer.createProfile(name: "Owned fullscreen commands")
            try owned.register(profile)
            for item in writer.profiles where item.id == profile {
                if let controller = item.extensionControllerID { try controllers.register(controller) }
            }
        }
        let sourceSpace = writer.space.id
        var nextSpace: UUID?
        if kind == "next-space" {
            nextSpace = try writer.createSpace(name: "Owned next fullscreen Space", profileID: profile)
            _ = writer.newTab(url: base.appendingPathComponent("page"))
            writer.selectSpace(sourceSpace)
        }
        let sourceURL = base.appendingPathComponent(kind == "reader" ? "article" : "page")
        let primaryID = writer.newTab(url: sourceURL)
        if kind == "next-tab" || kind == "split" {
            _ = writer.newTab(url: sourceURL, activate: false)
            // This API appends to the session's selection even without
            // activating a pane. Explicitly stage the intended source first.
            writer.select(primaryID)
        }
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
        defer {
            owner.shutdown(); writer.shutdown()
            if isPrivate {
                check(keyReads == 0 && !FileManager.default.fileExists(atPath: writer.sessionURL.path),
                      "Private fullscreen \(kind) never reads a metadata key or writes a saved session")
            }
            try? FileManager.default.removeItem(at: root)
        }
        app.openPrimary(owner)
        guard let primaryWindow = app.primaryOwners.first(where: { $0.value === owner })?.key,
              let store = app.windows[primaryWindow], store.activeProfileID == profile else {
            throw Failure.fixture("real owned browser window")
        }
        var window = primaryWindow, id = primaryID
        var quick: QuickBrowseWindowController?
        if isQuick {
            id = try store.openQuickPage(url: sourceURL, profileID: profile, intendedSpaceID: store.space.id)
            app.syncQuickWindows(owner)
            guard let controller = app.quickWindows[QuickWindowKey(ownerID: owner.id, pageID: id)],
                  let compactWindow = controller.window else { throw Failure.fixture("registered Quick command window") }
            quick = controller; window = compactWindow; controller.surface()
        }
        window.title = "Alcove owned fullscreen \(isPrivate ? "private" : "regular") \(kind)"
        print("FULLSCREEN_COMMAND_CONTEXT", kind, "private", isPrivate, "quick", isQuick)
        let underlying = store.view(for: id)
        var web = underlying
        var targetID = id
        if kind == "peek-escape" {
            store.openPeek(base.appendingPathComponent("page"), from: underlying)
            guard let peek = isQuick ? store.quickPeekView(id) : store.primaryPeekView else { throw Failure.fixture("command Peek") }
            web = peek
        } else {
            if kind == "close" && !isQuick {
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
                    check((isQuick ? store.quickPeekView(id) : store.primaryPeekView) === web,
                          "Escape exits fullscreen before closing the underlying Peek")
                } else {
                    check(store.views[id] === web && window.isVisible, "Escape preserves its original tab and browser window")
                }
                let originalDraft = try await web.evaluateJavaScript("document.getElementById('draft').value==='captured command draft'&&window.ownedCommandToken===41") as? Bool
                check(exited && store.documentIdentity(for: web) === document && originalDraft == true,
                      "\(kind): Escape preserves the exact original draft and document")
            case "location":
                if routed {
                    app.location(); app.location()
                    let opened = await effect { (quick?.state.isEditingAddress ?? store.commandVisible) && web.window === window && window.firstResponder is NSTextView && (web as? SplitDropWebView)?.websiteFullscreen?.isBorrowed == false }
                    check(opened && app.windows.count == 1 && app.quickWindows.count == (isQuick ? 1 : 0), "Cmd-L leaves fullscreen and opens the captured address field without creating another window")
                } else {
                    check(false, "Cmd-L requires its captured routing context before address UI can be delivered")
                }
                store.dismissCommand()
                quick?.state.cancelLocation(currentURL: web.url?.absoluteString ?? "")
            case "find":
                app.find()
                let opened = await effect { (quick?.state.findVisible ?? store.findVisible) && web.window === window && window.firstResponder is NSTextView && (web as? SplitDropWebView)?.websiteFullscreen?.isBorrowed == false }
                check(opened && store.documentIdentity(for: web) === document, "Cmd-F leaves fullscreen and searches its captured live page")
                store.findVisible = false
                quick?.state.dismissFind()
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
            case "new-tab", "sidebar", "next-tab", "next-space", "split":
                let sidebarWasVisible = store.sidebarVisible
                switch kind {
                case "new-tab": app.newTab()
                case "sidebar": app.sidebar()
                case "next-tab": app.nextTab()
                case "next-space": app.nextSpace()
                default: app.split()
                }
                let delivered = await effect {
                    let changed: Bool
                    switch kind {
                    case "new-tab": changed = store.commandVisible
                    case "sidebar": changed = store.sidebarVisible != sidebarWasVisible
                    case "next-tab": changed = store.selectedID != id && store.currentView?.window === window
                    case "next-space": changed = store.space.id == nextSpace && store.currentView?.window === window
                    default: changed = store.splitLayout?.tabIDs.contains(id) == true && web.window === window
                    }
                    return changed && !presentation.isVisible && web.fullscreenState == .notInFullscreen &&
                        (web as? SplitDropWebView)?.websiteFullscreen?.isBorrowed == false
                }
                check(delivered, "\(kind): browser navigation and layout actions restore native fullscreen before changing the visible browser")
                let draft = try await web.evaluateJavaScript("document.getElementById('draft').value==='captured command draft'&&window.ownedCommandToken===41") as? Bool
                check(delivered && store.views[id] === web && store.documentIdentity(for: web) === document && draft == true,
                      "\(kind): browser navigation and layout retain the exact source page and unsaved form")
                store.dismissCommand()
            case "coalesced", "coalesced-close":
                guard let coordinator = (web as? SplitDropWebView)?.websiteFullscreen else { throw Failure.fixture("exit coordinator") }
                var results: [Bool] = []
                coordinator.exit { restored in
                    results.append(restored)
                    if restored && kind == "coalesced-close" { store.close(id) }
                }
                coordinator.exit { results.append($0) }
                let finished = await effect { results.count == 2 }
                check(finished && !presentation.isVisible && web.fullscreenState == .notInFullscreen,
                      "\(kind): simultaneous exit requests complete at the actual native restoration boundary")
                if kind == "coalesced-close" {
                    check(results == [true, false] && store.views[id] == nil,
                          "A captured tab closed by the first exit callback revokes the second callback")
                } else {
                    check(results == [true, true] && web.window === window,
                          "Coalesced callbacks each receive one valid original presentation")
                    if finished {
                        try await enter(web, target: "element")
                        check(results.count == 2 && coordinator.isBorrowed,
                              "A new genuine fullscreen presentation does not replay completed exit callbacks")
                        try await leave(web)
                        check(results.count == 2, "Completed callbacks remain settled after a later native exit")
                    }
                }
            case "focus-change":
                let other = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 420, height: 280),
                                     styleMask: [.titled, .closable], backing: .buffered, defer: false)
                other.isReleasedWhenClosed = false; other.title = "Owned alternate focus"
                other.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 280))
                defer { other.contentView = nil; other.close() }
                var focusEvents: [String] = []
                let focusObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { notification in
                    MainActor.assumeIsolated {
                        guard let changed = notification.object as? NSWindow else { return }
                        focusEvents.append(changed === other ? "other" : changed === window ? "origin" : changed === presentation ? "fullscreen" : "unrelated")
                    }
                }
                defer { NotificationCenter.default.removeObserver(focusObserver) }
                app.find()
                other.makeKeyAndOrderFront(nil)
                print("FULLSCREEN_FOCUS_REQUESTED", "otherKey", other.isKeyWindow, "originKey", window.isKeyWindow,
                      "fullscreenKey", presentation.isKeyWindow, "find", store.findVisible)
                let exited = await effect { (web as? SplitDropWebView)?.websiteFullscreen?.isBorrowed == false }
                print("FULLSCREEN_FOCUS_RESULT", "exited", exited, "otherKey", other.isKeyWindow,
                      "originKey", window.isKeyWindow, "fullscreenKey", presentation.isKeyWindow,
                      "find", store.findVisible, "events", focusEvents)
                check(exited && !presentation.isVisible && web.window === window,
                      "A focus change during command delivery still completes native fullscreen restoration")
                check(exited && !store.findVisible && other.isKeyWindow,
                      "A deferred browser command neither opens UI nor steals focus after another window becomes key")
            case "close":
                app.closeTab()
                if isQuick {
                    let closed = await effect { store.quickPage(id) == nil && !window.isVisible && !presentation.isVisible && web.fullscreenState == .notInFullscreen }
                    check(closed && app.quickWindows.isEmpty && primaryWindow.isVisible && store.tab(primaryID) != nil,
                          "Cmd-W leaves fullscreen and closes only its captured Quick window")
                    check(closed && NSApp.isRunning && !app.applicationShouldTerminateAfterLastWindowClosed(NSApp),
                          "Closing a fullscreen Quick window keeps the browser application running")
                    break
                }
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
        for controller in Array(app.quickWindows.values) { controller.window?.performClose(nil) }
        app.quickWindows.removeAll()
        for ownedWindow in Array(app.windows.keys) { ownedWindow.performClose(nil) }
        app.windows.removeAll(); app.primaryOwners.removeAll(); app.primaryLeases.removeAll()
        if let caught { throw caught }
        print("FULLSCREEN_COMMAND_CASE_COMPLETED", kind, "private", isPrivate, "quick", isQuick)
    }

    @available(macOS 15.4, *) @MainActor
    static func exerciseCommands(base: URL) async throws {
        let owned = try OwnedWebsiteStores(), controllers = try OwnedExtensionControllers()
        guard await controllers.cleanup(), await owned.cleanup() else { throw Failure.fixture("command ownership recovery") }
        let regular = ["escape", "peek-escape", "location", "find", "close", "reader", "print", "pdf", "archive", "customize", "settings", "library", "coalesced", "coalesced-close", "focus-change", "new-tab", "sidebar", "next-tab", "next-space", "split"]
        let compact = ["escape", "peek-escape", "location", "find", "reader", "close"].map { "quick-" + $0 }
        let all = regular + ["escape", "location", "find", "reader", "close"].map { "private-" + $0 } + compact + compact.map { "private-" + $0 }
        let selected = ProcessInfo.processInfo.environment["ALCOVE_FULLSCREEN_COMMAND_CASES"].map { $0.split(separator: ",").map(String.init) } ?? []
        guard selected.allSatisfy(all.contains) else { throw Failure.fixture("unknown selected command case") }
        for name in selected.isEmpty ? all : selected {
            let isPrivate = name.hasPrefix("private-"), presentation = isPrivate ? String(name.dropFirst(8)) : name
            let isQuick = presentation.hasPrefix("quick-"), kind = isQuick ? String(presentation.dropFirst(6)) : presentation
            do { try await exerciseCommand(base: base, kind: kind, owned: owned, controllers: controllers, isPrivate: isPrivate, isQuick: isQuick) }
            catch { failures += 1; print("FULLSCREEN_COMMAND_CASE_ERROR", name, error) }
        }
        let a = await controllers.cleanup(), b = await owned.cleanup()
        check(a && b, "Native command fixtures release and erase all owned website/extension stores")
        print("FULLSCREEN_COMMAND_CLEANUP", a, b)
    }
}
