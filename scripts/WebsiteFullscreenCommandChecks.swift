import AppKit
import WebKit
import CryptoKit
import BrowserCore

/// Observe this fixture's public delegate boundary while retaining the real
/// production alert implementation. No synthetic frame or replacement dialog.
@MainActor private final class OwnedFullscreenScriptProbe: NSObject, WKUIDelegate {
    let store: BrowserStore
    let sample: (String) -> Void
    let nativeExitControl: Bool
    var confirmationResults: [Bool] = []
    init(store: BrowserStore, nativeExitControl: Bool = false, sample: @escaping (String) -> Void) {
        self.store = store; self.sample = sample; self.nativeExitControl = nativeExitControl
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        sample("delegate-entry")
        if nativeExitControl {
            webView.closeAllMediaPresentations {
                self.sample("native-control-completion")
                self.forwardAlert(webView, message: message, frame: frame, completionHandler: completionHandler)
            }
            sample("native-control-return")
            return
        }
        forwardAlert(webView, message: message, frame: frame, completionHandler: completionHandler)
    }
    private func forwardAlert(_ webView: WKWebView, message: String, frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        store.webView(webView, runJavaScriptAlertPanelWithMessage: message, initiatedByFrame: frame) {
            self.sample("delegate-completion"); completionHandler()
        }
        sample("delegate-return")
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        sample("delegate-entry")
        store.webView(webView, runJavaScriptConfirmPanelWithMessage: message, initiatedByFrame: frame) { result in
            self.confirmationResults.append(result)
            self.sample("delegate-completion"); completionHandler(result)
        }
        sample("delegate-return")
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        sample("delegate-entry")
        store.webView(webView, runJavaScriptTextInputPanelWithPrompt: prompt, defaultText: defaultText, initiatedByFrame: frame) { result in
            self.sample("delegate-completion"); completionHandler(result)
        }
        sample("delegate-return")
    }
}

extension WebsiteFullscreenChecks {
    @MainActor static func effect(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        do { try await wait("captured native command effect") { condition() }; return true }
        catch { return false }
    }

    @available(macOS 15.4, *) @MainActor
    static func exerciseCommand(base: URL, kind: String, owned: OwnedWebsiteStores,
                                controllers: OwnedExtensionControllers, isPrivate: Bool = false, isQuick: Bool = false) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alcove-fullscreen-command-" + UUID().uuidString)
        var protection: WebsiteProtectionService?
        if kind == "warning" {
            // A one-domain owned catalog; no target navigation or network request.
            let rows = Data("listed.alcove.example\n".utf8)
            let instant = ISO8601DateFormatter().string(from: Date())
            let metadata = try JSONSerialization.data(withJSONObject: ["formatVersion": 1, "provider": "PhishDestroy",
                "sourceRevision": String(repeating: "1", count: 40), "sourceUpdatedAt": instant, "retrievedAt": instant,
                "sha256": SHA256.hash(data: rows).map { String(format: "%02x", $0) }.joined(),
                "licenseSHA256": String(repeating: "0", count: 64), "domainCount": 1])
            let catalog = try WebsiteThreatCatalog(domains: rows, metadata: metadata)
            let service = WebsiteProtectionService(loader: { catalog }); _ = await service.load(); protection = service
        }
        var keyReads = 0
        let writer = BrowserStore(isPrivate: isPrivate, dataRoot: root, keyProvider: { _ in
            keyReads += 1; return SymmetricKey(data: Data(repeating: 87, count: 32))
        }, websiteProtection: protection)
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
        let sourceURL = base.appendingPathComponent(kind == "reader" ? "article" : (kind == "no-media" ? "page-no-media" : "page"))
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
            if (kind == "close" || kind.hasPrefix("close-direct") || kind == "close-script-sheet") && !isQuick {
                targetID = store.newTab(url: base.appendingPathComponent("page"))
                web = store.view(for: targetID)
            }
        }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        var caught: Error?
        do {
            try await wait("real browser website host") { web.window === window && web.superview is EdgeToEdgeWebHost }
            guard let commandHost = web.superview as? EdgeToEdgeWebHost else { throw Failure.fixture("original command host") }
            try await wait("command source decoded") {
                guard !web.isLoading else { return false }
                if kind == "no-media" {
                    return (try? await web.evaluateJavaScript("document.getElementById('enter')!==null&&document.querySelectorAll('video,audio').length===0")) as? Bool == true
                }
                return (try? await web.evaluateJavaScript("document.getElementById('video')?.readyState>=2")) as? Bool == true
            }
            _ = try await web.evaluateJavaScript("document.getElementById('draft').value='captured command draft';window.ownedCommandToken=41;true")
            let document = store.documentIdentity(for: web)
            if kind == "no-media" { try await enterWithOwnedClick(web, window: window) }
            else { try await enter(web, target: "element") }
            guard let presentation = web.window, presentation !== window else { throw Failure.fixture("command presentation") }
            try await wait("command native window key") { presentation.isKeyWindow }
            let routed = app.browserStore(in: presentation) === store && app.activeStore === store && app.activeWebView === web
            check(routed, "\(kind): native fullscreen command routing retains the actual page and store")
            check(app.activeBrowserWindow === window, "\(kind): native fullscreen resolves to its captured logical browser window")
            check(app.outputTarget(in: presentation)?.web === web,
                  "\(kind): page-output selection retains the fullscreen source")
            switch kind {
            case "no-media":
                check(app.handleEscape(in: presentation), "Escape handles an ordinary page's native fullscreen presentation")
                let restored = await effect {
                    web.window === window && !presentation.isVisible && web.fullscreenState == .notInFullscreen &&
                        (web as? SplitDropWebView)?.websiteFullscreen?.isBorrowed == false
                }
                check(restored, "A page without media returns from genuine fullscreen to its original browser window")
                let draft = try await web.evaluateJavaScript("document.getElementById('draft').value==='captured command draft'&&window.ownedCommandToken===41&&document.querySelectorAll('video,audio').length===0") as? Bool
                check(restored && store.profileID(for: web) == profile && store.documentIdentity(for: web) === document && draft == true,
                      "Ordinary fullscreen preserves its exact profile, live document and unsaved form without adding media")
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
            case "file-prompt", "media-prompt":
                var prompt: NSWindow?, presentedIn: NSWindow?
                var denials: [Bool] = []
                var duplicateReply: (() -> Void)?, recoveryReply: (() -> Void)?
                if kind == "file-prompt" {
                    store.requestWebsiteFiles(from: web, present: { parent, reply in
                        let panel = NSOpenPanel(); panel.directoryURL = root
                        panel.canChooseFiles = true; panel.canChooseDirectories = false
                        presentedIn = parent; prompt = panel
                        duplicateReply = { reply([root.appendingPathComponent("never-selected.txt")]) }
                        recoveryReply = { reply(nil) }
                        panel.beginSheetModal(for: parent) { _ in reply(nil) }
                        return { panel.cancel(nil) }
                    }, completion: { denials.append($0 == nil) })
                } else {
                    store.requestWebsiteMedia(from: web, present: { parent, reply in
                        let alert = NSAlert(); alert.messageText = "Owned fullscreen media consent"
                        alert.addButton(withTitle: "Don’t Allow"); alert.addButton(withTitle: "Allow Once")
                        presentedIn = parent; prompt = alert.window
                        duplicateReply = { reply(true) }; recoveryReply = { reply(false) }
                        alert.beginSheetModal(for: parent) { reply($0 == .alertSecondButtonReturn) }
                        return {
                            if let parent = alert.window.sheetParent { parent.endSheet(alert.window, returnCode: .cancel) }
                            alert.window.orderOut(nil)
                        }
                    }, completion: { denials.append($0 == .deny) })
                }
                let shown = await effect { prompt != nil && prompt?.isVisible == true && prompt?.sheetParent === presentedIn }
                print("FULLSCREEN_PROMPT_PRESENTED", kind, "shown", shown, "parentIsOrigin", presentedIn === window,
                      "sourceInOrigin", web.window === window, "nativeVisible", presentation.isVisible,
                      "state", web.fullscreenState.rawValue, "borrowed", (web as? SplitDropWebView)?.websiteFullscreen?.isBorrowed ?? false)
                check(shown && presentedIn === window && web.window === window && !presentation.isVisible &&
                      (web as? SplitDropWebView)?.websiteFullscreen?.isBorrowed == false,
                      "\(kind): the actual native sheet presents only after restoring its original browser window")
                app.location()
                print("FULLSCREEN_PROMPT_COMMAND", kind, "commandVisible", store.commandVisible,
                      "keyIsSheet", NSApp.keyWindow === prompt, "originHasSheet", window.attachedSheet != nil)
                check(shown && !store.commandVisible,
                      "\(kind): a native website sheet blocks conflicting address UI")
                let endedNativeSheet: Bool
                if let prompt, let parent = prompt.sheetParent {
                    endedNativeSheet = true
                    parent.endSheet(prompt, returnCode: kind == "file-prompt" ? .cancel : .alertFirstButtonReturn)
                    prompt.orderOut(nil)
                } else {
                    endedNativeSheet = false
                    // Recovery can settle an unavailable native boundary, but
                    // cannot make either visibility or callback assertion pass.
                    recoveryReply?(); prompt?.orderOut(nil)
                }
                let settled = await effect { !denials.isEmpty }
                duplicateReply?()
                check(endedNativeSheet && settled && denials == [true],
                      "\(kind): cancelling the real native sheet denies once and rejects a duplicate reply")
                store.dismissCommand()
                let draft = try await web.evaluateJavaScript("document.getElementById('draft').value==='captured command draft'&&window.ownedCommandToken===41") as? Bool
                check(store.profileID(for: web) == profile && store.documentIdentity(for: web) === document && draft == true,
                      "\(kind): the native prompt preserves its captured profile, live document and unsaved form")
            case "warning":
                var decisions: [Bool] = []
                let held = URL(string: "https://listed.alcove.example/owned-fullscreen-warning")!
                guard let ticket = store.decideWebsiteProtection(web, url: held, kind: .navigation(isMainFrame: true),
                                                                 decision: { decisions.append($0) }) else { throw Failure.fixture("owned warning ticket") }
                func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
                var warning: NSView?
                let visible = await effect {
                    guard web.window === window, !presentation.isVisible,
                          (web as? SplitDropWebView)?.websiteFullscreen?.isBorrowed == false,
                          let parent = web.superview,
                          let overlay = descendants(parent).first(where: { $0.identifier?.rawValue == "AlcoveWebsiteProtection" && !$0.isHiddenOrHasHiddenAncestor }),
                          overlay.window === window, overlay.frame.intersects(parent.bounds) else { return false }
                    warning = overlay; return true
                }
                check(visible && ticket.isPending && decisions.isEmpty,
                      "A held website warning exits fullscreen and visibly covers the captured original page")
                let controls = warning.map(descendants) ?? []
                let safe = controls.first(where: { $0.identifier?.rawValue == "AlcoveWebsiteProtectionSafe" }) as? NSButton
                let proceed = controls.first(where: { $0.identifier?.rawValue == "AlcoveWebsiteProtectionContinue" }) as? NSButton
                print("FULLSCREEN_WARNING_CONTROLS", "assessment", ticket.assessment != nil,
                      "safeFound", safe != nil, "safeEnabled", safe?.isEnabled ?? false,
                      "safeTarget", safe?.target != nil, "continueFound", proceed != nil,
                      "continueHidden", proceed?.isHidden ?? true)
                if let safe { safe.performClick(nil) } else { ticket.cancel() }
                print("FULLSCREEN_WARNING_AFTER_SAFE", "decisions", decisions, "pending", ticket.isPending,
                      "safeEnabled", safe?.isEnabled ?? false, "safeTarget", safe?.target != nil)
                proceed?.performClick(nil)
                print("FULLSCREEN_WARNING_AFTER_CONTINUE", "decisions", decisions, "pending", ticket.isPending)
                check(visible && safe != nil && decisions == [false] && !ticket.isPending,
                      "The visible warning cancels once and a retained Continue control cannot revive it")
                let draft = try await web.evaluateJavaScript("document.getElementById('draft').value==='captured command draft'&&window.ownedCommandToken===41") as? Bool
                check(store.profileID(for: web) == profile && store.documentIdentity(for: web) === document && draft == true,
                      "Cancelling the fullscreen warning preserves its original profile, document and unsaved form")
            case "script-alert", "script-confirm", "script-prompt", "script-alert-native-control":
                let marker = "Owned fullscreen " + kind
                var observed = false, restoredBeforePrompt = false, attachedToOrigin = false
                var nativeHiddenBeforePrompt = false, sourceSheet = false, commandBlocked = false
                var defaultWasPreserved = kind != "script-prompt"
                let probe = OwnedFullscreenScriptProbe(store: store, nativeExitControl: kind == "script-alert-native-control") { label in
                    residency(kind + " " + label, web: web, host: commandHost, window: window)
                    print("FULLSCREEN_SCRIPT_BOUNDARY", kind, label, "nativeVisible", presentation.isVisible,
                          "originKey", window.isKeyWindow, "nativeKey", presentation.isKeyWindow,
                          "modal", NSApp.modalWindow != nil, "sourceWindowNil", web.window == nil,
                          "sourceInNative", web.window === presentation)
                }
                guard web.uiDelegate === store else { throw Failure.fixture("original production UI delegate") }
                web.uiDelegate = probe
                defer { web.uiDelegate = store }
                func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
                // The legacy app-modal implementation can nest AppKit's run
                // loop. A common-mode native timer witnesses/dismisses only
                // this owned marker, without relying on a blocked actor task.
                let timer = Timer(timeInterval: 0.02, repeats: true) { timer in
                    MainActor.assumeIsolated {
                        guard let prompt = window.attachedSheet ?? presentation.attachedSheet ?? NSApp.modalWindow,
                              let content = prompt.contentView,
                              descendants(content).contains(where: { ($0 as? NSTextField)?.stringValue == marker }) else { return }
                        observed = true
                        restoredBeforePrompt = web.window === window && !presentation.isVisible &&
                            web.fullscreenState == .notInFullscreen && (web as? SplitDropWebView)?.websiteFullscreen?.isBorrowed == false
                        attachedToOrigin = prompt.sheetParent === window
                        nativeHiddenBeforePrompt = !presentation.isVisible
                        sourceSheet = attachedToOrigin && NSApp.modalWindow !== prompt
                        print("FULLSCREEN_SCRIPT_DIALOG", kind, "restored", restoredBeforePrompt, "originSheet", attachedToOrigin,
                              "appModal", NSApp.modalWindow === prompt)
                        if sourceSheet { app.location(); commandBlocked = !store.commandVisible }
                        if kind == "script-prompt", let field = descendants(content).compactMap({ $0 as? NSTextField }).first(where: \.isEditable) {
                            defaultWasPreserved = field.stringValue == "Owned starting text"
                            field.stringValue = "Owned submitted text"
                        }
                        timer.invalidate()
                        let response: NSApplication.ModalResponse = kind == "script-confirm" ? .alertSecondButtonReturn : .alertFirstButtonReturn
                        if let parent = prompt.sheetParent { parent.endSheet(prompt, returnCode: response) }
                        else {
                            NSApp.stopModal(withCode: response)
                            if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                                NSApp.postEvent(wake, atStart: true)
                            }
                        }
                        prompt.orderOut(nil)
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                defer { timer.invalidate() }
                _ = try await web.callAsyncJavaScript("""
                    window.ownedScriptDialogDone=false;
                    setTimeout(()=>{
                        if(kind.startsWith('script-alert')){alert(marker);window.ownedScriptDialogResult='alert-returned';}
                        else if(kind==='script-confirm') window.ownedScriptDialogResult=confirm(marker);
                        else window.ownedScriptDialogResult=prompt(marker,'Owned starting text');
                        window.ownedScriptDialogDone=true;
                    },0);return true;
                    """, arguments: ["marker": marker, "kind": kind], in: nil, contentWorld: .page)
                let shown = await effect { observed }
                // WebKit cannot finalize its immediate exit until the dialog
                // reply resumes JavaScript. Physical hiding and correct sheet
                // ownership must precede the prompt; live restoration follows.
                check(shown && nativeHiddenBeforePrompt && sourceSheet,
                      "\(kind): native fullscreen is hidden before a real dialog sheet appears on its captured browser window")
                check(shown && commandBlocked, "\(kind): a source-bound script sheet blocks conflicting address UI")
                var completed = false
                do {
                    try await wait("owned script dialog completion") { (try? await web.evaluateJavaScript("window.ownedScriptDialogDone===true")) as? Bool == true }
                    completed = true
                } catch { print("FULLSCREEN_SCRIPT_DIALOG_COMPLETION_ERROR", kind, error) }
                let result = try await web.evaluateJavaScript("window.ownedScriptDialogResult")
                let expectedResult = kind == "script-confirm" ? (result as? Bool == false) :
                    (result as? String == (kind.hasPrefix("script-alert") ? "alert-returned" : "Owned submitted text"))
                check(completed && expectedResult, "\(kind): the actual document receives the native dialog result")
                if kind == "script-prompt" { check(shown && defaultWasPreserved, "The real prompt preserves its starting text before submitting edited text") }
                let restored = await effect {
                    web.window === window && web.superview is EdgeToEdgeWebHost && !presentation.isVisible &&
                        web.fullscreenState == .notInFullscreen && (web as? SplitDropWebView)?.websiteFullscreen?.isBorrowed == false
                }
                check(restored && store.profileID(for: web) == profile,
                      "\(kind): answering the actual dialog completes native exit and restores its exact page to the original profile/window")
                let draft = try await web.evaluateJavaScript("document.getElementById('draft').value==='captured command draft'&&window.ownedCommandToken===41") as? Bool
                check(completed && store.documentIdentity(for: web) === document && draft == true,
                      "\(kind): dismissing the actual dialog resumes its original document and preserves the unsaved form")
                residency(kind + " after-script", web: web, host: commandHost, window: window)
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
            case "close-script-sheet":
                try await wait("owned surviving sheet-close document") {
                    (try? await underlying.evaluateJavaScript("document.getElementById('draft')!==null")) as? Bool == true
                }
                _ = try await underlying.evaluateJavaScript("document.getElementById('draft').value='surviving sheet-close draft';true")
                let survivorDocument = store.documentIdentity(for: underlying)
                let marker = "Owned pending confirmation on tab closure"
                let probe = OwnedFullscreenScriptProbe(store: store) { label in
                    residency("close-script-sheet " + label, web: web, host: commandHost, window: window)
                }
                guard web.uiDelegate === store else { throw Failure.fixture("pending-script production delegate") }
                web.uiDelegate = probe
                defer { if store.views[targetID] === web { web.uiDelegate = store } }
                func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
                var prompt: NSWindow?, deadline: ContinuousClock.Instant?
                var observed = false, unanswered = false, hiddenBeforePrompt = false
                var closedBeforeRecovery = false, recoveryUsed = false
                let clock = ContinuousClock()
                // A real JS dialog can hold even the initiating evaluation's
                // reply. Observe/close in AppKit's common run-loop modes.
                let timer = Timer(timeInterval: 0.02, repeats: true) { timer in
                    MainActor.assumeIsolated {
                        if !observed {
                            guard let sheet = window.attachedSheet, sheet.isVisible, let content = sheet.contentView,
                                  descendants(content).contains(where: { ($0 as? NSTextField)?.stringValue == marker }) else { return }
                            prompt = sheet; observed = true
                            unanswered = probe.confirmationResults.isEmpty
                            hiddenBeforePrompt = !presentation.isVisible
                            deadline = clock.now.advanced(by: .seconds(12))
                            store.close(targetID)
                        }
                        if store.views[targetID] == nil && store.tab(targetID) == nil && !presentation.isVisible &&
                            web.fullscreenState == .notInFullscreen && (web as? SplitDropWebView)?.websiteFullscreen?.isBorrowed == false &&
                            prompt?.isVisible == false && window.attachedSheet == nil && probe.confirmationResults == [false] {
                            closedBeforeRecovery = true; timer.invalidate()
                        } else if let deadline, clock.now >= deadline {
                            // Snapshot failure before ending our owned sheet.
                            // Recovery must never make the assertion pass.
                            recoveryUsed = true; timer.invalidate()
                            if let prompt, let parent = prompt.sheetParent {
                                parent.endSheet(prompt, returnCode: .alertSecondButtonReturn); prompt.orderOut(nil)
                            }
                        }
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                defer { timer.invalidate() }
                do {
                    _ = try await web.callAsyncJavaScript("setTimeout(()=>confirm(marker),0);return true;",
                        arguments: ["marker": marker], in: nil, contentWorld: .page)
                } catch {
                    guard observed else { throw error }
                    print("FULLSCREEN_PENDING_SHEET_EVALUATION_ENDED", error)
                }
                let settled = await effect { closedBeforeRecovery || recoveryUsed }
                timer.invalidate()
                let closed = settled && closedBeforeRecovery
                check(observed && unanswered && hiddenBeforePrompt,
                      "An actual unanswered page confirmation belongs to its captured browser window after fullscreen hides")
                check(closed,
                      "Closing a fullscreen tab cancels its actual pending script sheet once before retiring the page")
                print("FULLSCREEN_PENDING_SHEET_CLOSE", "closed", closed, "recoveryUsed", recoveryUsed,
                      "replies", probe.confirmationResults, "sheetVisible", prompt?.isVisible ?? false,
                      "attached", window.attachedSheet != nil, "registered", store.views[targetID] === web,
                      "state", web.fullscreenState.rawValue)
                if let prompt, let parent = prompt.sheetParent {
                    parent.endSheet(prompt, returnCode: .alertSecondButtonReturn); prompt.orderOut(nil)
                }
                if !closed {
                    _ = await effect { !probe.confirmationResults.isEmpty }
                    store.close(targetID)
                    _ = await effect { store.views[targetID] == nil }
                }
                let survivorDraft = try await underlying.evaluateJavaScript("document.getElementById('draft').value==='surviving sheet-close draft'") as? Bool
                check(closed && window.isVisible && NSApp.isRunning && store.views[id] === underlying &&
                      store.profileID(for: underlying) == profile && store.documentIdentity(for: underlying) === survivorDocument && survivorDraft == true,
                      "Cancelling a closing tab's script sheet preserves the other exact live profile/document/form")
            case "close-direct", "close-direct-background":
                try await wait("owned surviving document") {
                    (try? await underlying.evaluateJavaScript("document.getElementById('draft')!==null")) as? Bool == true
                }
                _ = try await underlying.evaluateJavaScript("document.getElementById('draft').value='surviving close draft';true")
                let survivorDocument = store.documentIdentity(for: underlying)
                var alternate: NSWindow?
                if kind == "close-direct-background" {
                    let other = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 420, height: 280),
                                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
                    other.isReleasedWhenClosed = false; other.title = "Owned background tab-close requester"
                    other.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 280))
                    other.makeKeyAndOrderFront(nil); alternate = other
                    try await wait("owned close requester key") { other.isKeyWindow }
                }
                defer { alternate?.contentView = nil; alternate?.close() }
                // This is the shared model API used by tab close controls;
                // AppDelegate's already-qualified Cmd-W wrapper is bypassed.
                store.close(targetID)
                let closed = await effect {
                    store.views[targetID] == nil && store.tab(targetID) == nil && !presentation.isVisible &&
                        web.fullscreenState == .notInFullscreen && (web as? SplitDropWebView)?.websiteFullscreen?.isBorrowed == false
                }
                check(closed, "Closing a fullscreen tab through its shared model API finishes native exit before retiring the page")
                let survivorDraft = try await underlying.evaluateJavaScript("document.getElementById('draft').value==='surviving close draft'") as? Bool
                check(closed && window.isVisible && NSApp.isRunning && store.views[id] === underlying &&
                      store.profileID(for: underlying) == profile && store.documentIdentity(for: underlying) === survivorDocument && survivorDraft == true,
                      "Direct fullscreen tab closure keeps the browser and its other exact live document/profile/form intact")
                if let alternate { check(closed && alternate.isKeyWindow, "Closing a fullscreen tab from another window preserves the requesting window's focus") }
            default: throw Failure.fixture("unknown native command")
            }
        } catch { caught = error }

        // Recover using the independently qualified document exit, only after
        // observing each command's own result. Recovery never turns a failure green.
        let remaining = [underlying, web] + Array(store.views.values) + store.peekPages.values.map(\.web)
        var recovered = Set<ObjectIdentifier>()
        for page in remaining where recovered.insert(ObjectIdentifier(page)).inserted &&
            (page.fullscreenState != .notInFullscreen || (page as? SplitDropWebView)?.websiteFullscreen?.isBorrowed == true) {
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
        let regular = ["escape", "peek-escape", "location", "find", "close", "reader", "print", "pdf", "archive", "customize", "settings", "library", "coalesced", "coalesced-close", "focus-change", "new-tab", "sidebar", "next-tab", "next-space", "split", "file-prompt", "media-prompt", "warning", "script-alert", "script-confirm", "script-prompt"]
        let scriptDialogs = ["script-alert", "script-confirm", "script-prompt"]
        let compact = (["escape", "peek-escape", "location", "find", "reader", "close"] + scriptDialogs).map { "quick-" + $0 }
        let all = regular + ["close-direct", "close-direct-background", "close-script-sheet"] + (["escape", "location", "find", "reader", "close"] + scriptDialogs).map { "private-" + $0 } + compact + compact.map { "private-" + $0 }
        let selected = ProcessInfo.processInfo.environment["ALCOVE_FULLSCREEN_COMMAND_CASES"].map { $0.split(separator: ",").map(String.init) } ?? []
        // Characterization controls are opt-in and never counted as normal
        // production-path command coverage in the full default matrix.
        // App-local events do not grant WebKit transient activation on this
        // hosted OS. Keep no-media's strict input control explicit; ordinary
        // no-media fullscreen remains a required, unqualified live-input gate.
        guard selected.allSatisfy((all + ["script-alert-native-control", "no-media"]).contains) else { throw Failure.fixture("unknown selected command case") }
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
