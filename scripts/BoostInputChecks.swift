import AppKit
import SwiftUI
import WebKit
import CryptoKit
import BrowserCore

enum BoostInputCheckError: Error { case failed }
@main struct BoostInputChecks {
    @MainActor static func render(_ host: NSView, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["ALCOVE_BOOST_RENDER_DIR"] else { return }
        let directory = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw BoostInputCheckError.failed }
        host.effectiveAppearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw BoostInputCheckError.failed }
        try png.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited); setbuf(stdout, nil)
        var failures = 0, fixtures: [SiteSearchStoreFixture] = [], windows: [NSWindow] = []
        defer { windows.forEach { $0.contentView = nil; $0.close() }; fixtures.forEach { $0.close() } }
        func check(_ value: Bool, _ name: String) { print("\(value ? "PASS" : "FAIL"): \(name)"); if !value { failures += 1 } }
        func fixture(_ privateMode: Bool = false) throws -> SiteSearchStoreFixture { let f = try SiteSearchStoreFixture(isPrivate: privateMode); fixtures.append(f); return f }
        func window(_ size: NSSize = NSSize(width: 800, height: 600)) -> NSWindow {
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false; windows.append(w); return w
        }
        func mounted() throws -> (SiteSearchStoreFixture, NSWindow, BoostEditSource) {
            let f = try fixture(), w = window(); w.contentView = f.web
            return (f, w, try BoostEditSource(store: f.store, web: f.web))
        }
        let (f, sourceWindow, source) = try mounted(), store = f.store, app = AppDelegate()
        check(BrowserCommand.boosts.matches("create boost") && BrowserCommand.boosts.matches("customize website") && store.availableCommands.contains(.boosts), "Arc-style commands discover the real website customization action")
        store.showCommand(); store.runCommand(.boosts)
        check(store.presentedPanel == .boosts && !store.commandVisible && store.boostEditor?.profileID == f.profile, "The command opens a source/profile-bound Boost editor")
        app.buildMenu()
        check(NSApp.mainMenu?.items.first?.submenu?.items.contains(where: { $0.action == #selector(AppDelegate.websiteBoosts) && $0.target === app }) == true, "The native menu exposes Website Boosts")
        store.presentedPanel = nil; store.boostEditor = nil
        var original = SiteBoost(content: BoostContent(name: "Owned look", host: "127.0.0.1", javascript: "window.owned=true;"))
        try store.saveBoost(original, profileID: f.profile)
        original = store.boostCatalog(profileID: f.profile).entries[0]
        let editor = BoostEditor(store: store, profileID: f.profile, source: source, initial: original)
        store.boostEditor = editor; store.presentedPanel = .boosts
        editor.draft.content.name = "Edited title"; editor.draft.content.javascript = "const unfinished = ;"
        let appearance = BoostAppearance(background: "#F6EED8", text: "#443322", link: "#884422", font: .serif, textScale: 1.2)
        check(editor.setAppearance(appearance, in: store), "A no-code change saves immediately even while code has an unfinished draft")
        let afterAppearance = store.boostCatalog(profileID: f.profile).entries[0]
        check(afterAppearance.content.name == "Owned look" && afterAppearance.content.javascript == "window.owned=true;" && afterAppearance.content.appearance == appearance && editor.draft.content.javascript == "const unfinished = ;", "Immediate appearance saves preserve unsaved name/code fields without executing them")
        check(!editor.finish(in: store) && store.presentedPanel == .boosts && editor.error != nil, "Invalid Done keeps the draft and existing definition visible")
        editor.cancel()
        check(!editor.isDirty && editor.draft.content.name == "Owned look" && editor.draft.content.appearance == appearance, "Cancel drops unsaved fields and retains already-saved appearance choices")
        editor.draft.content.name = "Saved on Done"
        check(editor.finish(in: store) && store.presentedPanel == nil && store.boostCatalog(profileID: f.profile).entries[0].content.name == "Saved on Done", "Done saves a valid dirty draft before dismissal")
        let current = store.boostCatalog(profileID: f.profile).entries[0]
        let stale = BoostEditor(store: store, profileID: f.profile, source: source, initial: current)
        stale.draft.content.css = "p{color:red}"
        var newer = current; newer.content.name = "Newer title"; try store.saveBoost(newer, profileID: f.profile, expected: current)
        check(!stale.save(in: store) && stale.isDirty && store.boostCatalog(profileID: f.profile).entries[0].content.name == "Newer title", "An old editor cannot overwrite a newer saved content revision")
        let live = store.boostCatalog(profileID: f.profile).entries[0]
        let preserved = BoostEditor(store: store, profileID: f.profile, source: source, initial: live)
        preserved.draft.content.css = "p{line-height:1.7}"
        try store.setBoostEnabled(live.id, profileID: f.profile, enabled: false)
        try store.addBoostZap(live.id, profileID: f.profile, selector: "#ad", expected: store.boostCatalog(profileID: f.profile).entries[0])
        check(preserved.save(in: store) && !store.boostCatalog(profileID: f.profile).entries[0].enabled && store.boostCatalog(profileID: f.profile).entries[0].hiddenSelectors == ["#ad"], "Native code Save preserves newer variant and hidden-element controls")
        try store.removeBoostZap(live.id, profileID: f.profile, selector: "#ad")
        check(store.boostCatalog(profileID: f.profile).entries[0].hiddenSelectors.isEmpty, "An individual hidden element can be restored atomically")
        try store.addBoostZap(live.id, profileID: f.profile, selector: "#one", expected: store.boostCatalog(profileID: f.profile).entries[0])
        try store.addBoostZap(live.id, profileID: f.profile, selector: "#two", expected: store.boostCatalog(profileID: f.profile).entries[0])
        try store.clearBoostZaps(live.id, profileID: f.profile)
        check(store.boostCatalog(profileID: f.profile).entries[0].hiddenSelectors.isEmpty, "Unhide All clears the saved list in one durable operation")
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        try BoostClipboard.copy(store.boostCatalog(profileID: f.profile).entries[0], to: board)
        let copied = board.string(forType: .string) ?? ""
        check(!copied.contains("window.owned") && !copied.contains("approvedJavaScriptHash"), "The actual owned pasteboard receives appearance data without executable code or approval")
        let imported = try BoostClipboard.read(from: board)
        check(imported.id != live.id && !imported.enabled && imported.content.javascript.isEmpty && imported.content.css == "p{line-height:1.7}", "Pasting an appearance yields a disabled fresh look")
        let importer = BoostEditor(store: store, profileID: f.profile)
        check(importer.pasteAppearance(from: board) && importer.isDirty && importer.draft.content.javascript.isEmpty, "The editor previews an appearance import before saving or enabling it")
        importer.draft.content.name = "Keep unsaved import"
        board.clearContents(); board.setString("not JSON", forType: .string)
        check(!importer.pasteAppearance(from: board) && importer.draft.content.name == "Keep unsaved import", "A bad or replacement paste cannot discard an unfinished draft")
        var sharedLook = store.boostCatalog(profileID: f.profile).entries[0]; sharedLook.hiddenSelectors = ["#imported-ad"]
        try BoostClipboard.copy(sharedLook, to: board)
        let styledImport = BoostEditor(store: store, profileID: f.profile)
        check(styledImport.pasteAppearance(from: board) && styledImport.setAppearance(BoostAppearance(font: .rounded), in: store) && styledImport.save(in: store), "A pasted appearance can be styled before its remaining code fields are saved")
        let styledSaved = store.boostCatalog(profileID: f.profile).entries.first { $0.id == styledImport.draft.id }
        check(styledSaved?.hiddenSelectors == ["#imported-ad"] && styledSaved?.content.css == "p{line-height:1.7}" && styledSaved?.enabled == false && styledSaved?.content.javascript.isEmpty == true, "Styling an imported draft retains its selectors/CSS and keeps it disabled without scripts")
        store.boostEditor = importer; store.presentedPanel = .settings
        try store.requestBoostEditor()
        check(store.presentedPanel == .boosts && store.boostEditor === importer && importer.draft.content.name == "Keep unsaved import", "Opening another panel and returning preserves a cached unfinished Boost draft")
        check(!preserved.changeProfile(BrowserProfile.defaultID, in: store) && preserved.profileID == f.profile, "A page-bound editor cannot silently target another profile")
        let oldDraft = preserved.draft
        store.savingEnabled = false
        check(!preserved.setAppearance(BoostAppearance(background: "#000000"), in: store) && preserved.draft == oldDraft, "A failed immediate appearance save leaves the previous visible draft intact")
        store.savingEnabled = true

        let (approvalFixture, approvalWindow, approvalSource) = try mounted(), approvalStore = approvalFixture.store
        let script = SiteBoost(content: BoostContent(name: "Consent fixture", host: "127.0.0.1", javascript: "window.consentFixture = 17;"))
        try approvalStore.saveBoost(script, profileID: approvalFixture.profile)
        var replies: [(Bool) -> Void] = [], shown = 0, errors = 0, expectedPromptCode = "window.consentFixture = 17;"
        let prompt = BoostJavaScriptPrompt(confirm: { w, title, detail, code, reply in
            shown += 1; check(w === approvalWindow && title.contains("127.0.0.1") && detail.contains("Owned search fixture") && code == expectedPromptCode, "Consent presents the captured source window, profile, site and exact script")
            replies.append(reply)
        })
        approvalStore.requestBoostJavaScriptApproval(script.id, source: approvalSource, prompt: prompt, onError: { _ in errors += 1 })
        approvalStore.requestBoostJavaScriptApproval(script.id, source: approvalSource, prompt: prompt, onError: { _ in errors += 1 })
        check(shown == 1 && errors == 1, "A second request cannot stack a duplicate window-bound prompt")
        replies[0](false)
        check(!approvalStore.boostCatalog(profileID: approvalFixture.profile).entries[0].isJavaScriptApproved && approvalStore.boostApprovalJobs.isEmpty, "Cancel releases the pending request without approval")
        approvalStore.requestBoostJavaScriptApproval(script.id, source: approvalSource, prompt: prompt)
        replies.last!(true)
        let approvedBytes = try Data(contentsOf: approvalStore.sessionURL)
        replies.last!(true)
        check(try approvalStore.boostCatalog(profileID: approvalFixture.profile).entries[0].isJavaScriptApproved && Data(contentsOf: approvalStore.sessionURL) == approvedBytes && approvalFixture.web.requests.isEmpty, "Allow saves exact consent once without running code or reloading the page")
        let snapshot = approvalStore.boostCatalog(profileID: approvalFixture.profile).entries[0]
        var edited = snapshot; edited.content.javascript += "\nwindow.newCode=true;"; try approvalStore.saveBoost(edited, profileID: approvalFixture.profile, expected: snapshot)
        expectedPromptCode = edited.content.javascript
        approvalStore.requestBoostJavaScriptApproval(script.id, source: approvalSource, prompt: prompt, onError: { _ in errors += 1 })
        let beforeEdit = approvalStore.boostCatalog(profileID: approvalFixture.profile).entries[0]
        edited = beforeEdit; edited.content.javascript += "\nwindow.later=true;"; try approvalStore.saveBoost(edited, profileID: approvalFixture.profile, expected: beforeEdit)
        replies.last!(true)
        check(!approvalStore.boostCatalog(profileID: approvalFixture.profile).entries[0].isJavaScriptApproved, "Late Allow cannot authorize code edited while the prompt was open")
        let latePrompt = BoostJavaScriptPrompt(confirm: { _, _, _, _, reply in replies.append(reply) })
        approvalStore.requestBoostJavaScriptApproval(script.id, source: approvalSource, prompt: latePrompt)
        approvalStore.invalidateDocumentIdentity(for: approvalFixture.web); replies.last!(true)
        check(!approvalStore.boostCatalog(profileID: approvalFixture.profile).entries[0].isJavaScriptApproved, "Replacing the same-URL document invalidates pending native consent")
        let freshSource = try BoostEditSource(store: approvalStore, web: approvalFixture.web)
        approvalStore.requestBoostJavaScriptApproval(script.id, source: freshSource, prompt: latePrompt)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: approvalWindow); replies.last!(true)
        check(approvalStore.boostApprovalJobs.isEmpty && !approvalStore.boostCatalog(profileID: approvalFixture.profile).entries[0].isJavaScriptApproved, "Closing the native source window clears the prompt and ignores late Allow")
        let (switched, _, switchedSource) = try mounted()
        try switched.store.saveBoost(script, profileID: switched.profile)
        var switchedReply: ((Bool) -> Void)?
        switched.store.requestBoostJavaScriptApproval(script.id, source: switchedSource, prompt: BoostJavaScriptPrompt(confirm: { _, _, _, _, reply in switchedReply = reply }))
        check(switchedReply != nil, "The profile-switch fixture actually has an outstanding consent request")
        let otherProfile = try switched.store.createProfile(name: "Different primary account")
        switchedReply?(true)
        check(!switched.store.boostCatalog(profileID: switched.profile).entries[0].isJavaScriptApproved && switched.store.boostCatalog(profileID: otherProfile).entries.isEmpty, "Changing the primary Space/profile rejects consent for the old source without writing to the new profile")
        let alert = BoostJavaScriptPrompt.makeAlert(title: "Allow script?", detail: "Owned site and profile", code: "const owned = 17;")
        check(alert.alertStyle == .critical && alert.buttons.count == 2 && (alert.accessoryView as? NSScrollView)?.documentView is NSTextView && ((alert.accessoryView as? NSScrollView)?.documentView as? NSTextView)?.string == "const owned = 17;", "The native consent alert exposes exact code and can appear above the editing sheet using AppKit critical presentation")

        let (escapeFixture, escapeWindow, escapeSource) = try mounted(), es = escapeFixture.store
        let escapeLook = SiteBoost(content: BoostContent(name: "Escape fixture", host: "127.0.0.1"))
        try es.saveBoost(escapeLook, profileID: escapeFixture.profile)
        es.boostPicker = BoostPickerSession(source: escapeSource, boost: escapeLook)
        let oldPage = es.selectedID!
        _ = es.newTab()
        check(es.boostPicker == nil, "Changing the selected native tab cancels the old page's picker")
        es.select(oldPage)
        es.boostPicker = BoostPickerSession(source: try BoostEditSource(store: es, web: escapeFixture.web), boost: escapeLook)
        app.windows[escapeWindow] = es
        let container = NSView(frame: escapeWindow.contentView!.frame), text = NSTextView(frame: NSRect(x: 0, y: 0, width: 180, height: 50))
        escapeFixture.web.removeFromSuperview(); container.addSubview(escapeFixture.web); container.addSubview(text); escapeWindow.contentView = container
        escapeWindow.makeFirstResponder(text); text.setMarkedText("composing", selectedRange: NSRange(location: 0, length: 1), replacementRange: NSRange(location: NSNotFound, length: 0))
        check(text.hasMarkedText() && !app.handleEscape(in: escapeWindow) && es.boostPicker != nil, "Native IME composition receives Escape before picker cancellation")
        text.unmarkText()
        check(app.handleEscape(in: escapeWindow) && es.boostPicker == nil, "Escape cancels the actual window's picker after composition ends")
        let qf = try fixture(), qs = qf.store
        let quickID = try qs.openQuickPage(url: URL(string: "http://127.0.0.1:9/quick")!, profileID: qf.profile)
        let quickConfig = WKWebViewConfiguration(); quickConfig.websiteDataStore = qs.websiteDataStore(forProfile: qf.profile)
        let quickWeb = SiteSearchProbeWeb(frame: qf.web.frame, configuration: quickConfig)
        qs.registerView(quickWeb, for: quickID, profile: qf.profile)
        let owner = BrowserWindowOwner(store: qs) { }
        var primaryRequests = 0, capturedProfile: UUID?
        let quick = try QuickBrowseWindowController(owner: owner, pageID: quickID, requestPrimary: {
            primaryRequests += 1; capturedProfile = qs.boostEditor?.profileID
            if let id = try? qs.createProfile(name: "Primary window account") { qs.namedDataStores[id] = .nonPersistent() }
        }, requestProfiles: { }, didClose: { })
        defer { quick.window?.contentView = nil; quick.window?.close() }
        quick.window?.contentView?.layoutSubtreeIfNeeded(); await Task.yield()
        quick.requestBoosts()
        check(primaryRequests == 1 && capturedProfile == qf.profile && qs.boostEditor?.profileID == qf.profile && qs.activeProfileID != qf.profile && qs.boostEditor?.source?.window === quick.window, "The real compact action captures its source before opening a primary window that selects another profile")
        let quickText = NSTextView(frame: NSRect(x: 0, y: 0, width: 180, height: 50))
        quick.window?.contentView?.addSubview(quickText); quick.window?.makeFirstResponder(quickText)
        let quickSource = try BoostEditSource(store: qs, web: quickWeb)
        qs.boostPicker = BoostPickerSession(source: quickSource, boost: escapeLook)
        quickText.setMarkedText("composing", selectedRange: NSRange(location: 0, length: 1), replacementRange: NSRange(location: NSNotFound, length: 0))
        quick.escape()
        check(quickText.hasMarkedText() && qs.boostPicker != nil, "The compact controller's direct Escape path also preserves active IME composition")
        quickText.unmarkText(); quick.escape()
        check(qs.boostPicker == nil, "The compact controller cancels its picker once IME composition ends")
        let quickPeek = SiteSearchProbeWeb(frame: qf.web.frame, configuration: quickConfig)
        quickPeek.navigationDelegate = qs; quickPeek.uiDelegate = qs
        quick.window?.contentView?.addSubview(quickPeek)
        qs.peekPages[.quick(quickID)] = PeekState(web: quickPeek, profileID: qf.profile, spaceID: nil)
        qs.boostPicker = BoostPickerSession(source: try BoostEditSource(store: qs, web: quickPeek), boost: escapeLook)
        quick.escape()
        check(qs.boostPicker == nil && qs.quickPeekView(quickID) === quickPeek, "Escape exits picking before closing a compact Peek")
        store.boostEditor = stale; store.presentedPanel = .boosts; app.windows[sourceWindow] = store
        check(app.handleEscape(in: sourceWindow) && store.presentedPanel == .boosts && stale.isDirty, "Escape cannot dismiss a stale unsaved editor through the generic panel shortcut")
        store.boostEditor = nil; store.presentedPanel = nil
        for height in [300.0, 620.0] {
            var appAppearance = store.appearance; appAppearance.textScale = 1.35; store.appearance = appAppearance
            let model = BoostEditor(store: store, profileID: f.profile, source: source, initial: store.boostCatalog(profileID: f.profile).entries[0])
            let host = NSHostingView(rootView: BoostPanel(store: store, availableHeight: height, editor: model))
            host.safeAreaRegions = []; host.sizingOptions = []; let w = window(NSSize(width: 600, height: height))
            w.appearance = NSAppearance(named: store.activeTheme.isDark ? .darkAqua : .aqua)
            host.appearance = w.appearance; w.contentView = host; host.layoutSubtreeIfNeeded()
            check(host.fittingSize.width <= 601 && host.fittingSize.height <= height + 1, "Boost controls stay bounded at600×\(Int(height)) with large text")
            check(f.web.window === sourceWindow && store.views[store.selectedID!] === f.web, "Rendering/resizing the editor keeps the original mounted page")
            try render(host, name: "boosts-600x\(Int(height))-large")
        }
        let p = try fixture(true), privateEditor = BoostEditor(store: p.store, profileID: BrowserProfile.defaultID)
        privateEditor.draft.content.host = "private.test"; privateEditor.draft.content.name = "Private draft"
        check(privateEditor.save(in: p.store) && p.reads.count == 0 && !FileManager.default.fileExists(atPath: p.store.sessionURL.path), "The native private editor saves only temporary definitions without requesting a key or file")
        if failures != 0 { throw BoostInputCheckError.failed }
    }
}
