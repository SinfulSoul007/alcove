import AppKit
import SwiftUI
import WebKit
import BrowserCore

enum SiteSearchInputCheckError: Error { case failed, timeout }
@MainActor final class SiteInputWindow: NSWindow {}
// Some toolchains import this protocol as nonisolated. Stateful witnesses assert AppKit's main-thread contract.
@MainActor final class SiteCompositionClient: NSView, NSTextInputClient {
    var marked = true
    override var acceptsFirstResponder: Bool { true }
    nonisolated func insertText(_ string: Any, replacementRange: NSRange) {}
    nonisolated func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) { MainActor.assumeIsolated { marked = true } }
    nonisolated func unmarkText() { MainActor.assumeIsolated { marked = false } }
    nonisolated func selectedRange() -> NSRange { NSRange(location: 0, length: 0) }
    nonisolated func markedRange() -> NSRange { MainActor.assumeIsolated { marked ? NSRange(location: 0, length: 1) : NSRange(location: NSNotFound, length: 0) } }
    nonisolated func hasMarkedText() -> Bool { MainActor.assumeIsolated { marked } }
    nonisolated func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    nonisolated func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    nonisolated func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect { .zero }
    nonisolated func characterIndex(for point: NSPoint) -> Int { 0 }
}
@main struct SiteSearchInputChecks {
    @MainActor static func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        if !condition() { throw SiteSearchInputCheckError.timeout }
    }
    @MainActor static func descendants<T: NSView>(_ view: NSView, as type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, as: type) }
    }
    @MainActor static func render(_ view: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["ALCOVE_SITE_SEARCH_RENDER_DIR"] else { return }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw SiteSearchInputCheckError.failed }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw SiteSearchInputCheckError.failed }
        let file = folder.appendingPathComponent(name + ".png")
        try data.write(to: file, options: .atomic)
        print("RENDER: \(file.path)")
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited); setbuf(stdout, nil)
        var failures = 0, fixtures: [SiteSearchStoreFixture] = [], windows: [NSWindow] = []
        defer { windows.forEach { $0.contentView = nil; $0.close() }; fixtures.forEach { $0.close() } }
        func fixture() throws -> SiteSearchStoreFixture { let f = try SiteSearchStoreFixture(); fixtures.append(f); return f }
        func check(_ value: Bool, _ name: String) { print("\(value ? "PASS" : "FAIL"): \(name)"); if !value { failures += 1 } }
        func window(_ size: NSSize) -> SiteInputWindow {
            let w = SiteInputWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false; windows.append(w); return w
        }
        let f = try fixture(), store = f.store
        let binding = Binding(get: { store.command }, set: { store.command = $0 })
        var submits = 0, cancels = 0, moves = 0
        let input = FocusedInput(text: binding, placeholder: "Search", onSubmit: { submits += 1 }, onCancel: { cancels += 1 }, onMove: { moves += $0 }, onTab: { store.activatePreferredCommandSiteSearch() }, onEmptyDelete: { store.deleteEmptyCommandSiteSearch() })
        let coordinator = FocusedInput.Coordinator(input), field = FocusedInput.Field(string: ""), editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        store.showCommand(); store.command = "yt"
        check(coordinator.control(field, textView: editor, doCommandBy: NSSelectorFromString("insertTab:")) && store.commandSiteSearch?.keyword == "yt" && store.command.isEmpty, "Native primary Tab enters an exact shortcut without submitting")
        check(submits == 0 && f.web.requests.isEmpty, "Native Tab activation sends no page request")
        check(coordinator.control(field, textView: editor, doCommandBy: NSSelectorFromString("deleteBackward:")) && store.commandSiteSearch == nil && store.command == "yt", "Native empty Backspace restores normal shortcut input")
        check(field.stringValue == "yt" && editor.string == "yt" && editor.selectedRange() == NSRange(location: 2, length: 0), "Handled Backspace synchronizes the native field and caret")
        store.command = "wik"
        check(coordinator.control(field, textView: editor, doCommandBy: NSSelectorFromString("insertTab:")) && store.commandSiteSearch?.keyword == "wiki", "Native primary Tab resolves a unique prefix")
        check(field.stringValue.isEmpty && editor.string.isEmpty && editor.selectedRange() == NSRange(location: 0, length: 0), "Handled Tab clears the native editor and positions its caret")
        store.command = "typed query"
        check(!coordinator.control(field, textView: editor, doCommandBy: NSSelectorFromString("deleteBackward:")) && store.command == "typed query", "Backspace within a query stays native text editing")
        store.dismissCommand(); store.showCommand(); store.command = "unknown"
        check(!coordinator.control(field, textView: editor, doCommandBy: NSSelectorFromString("insertTab:")), "An unrelated primary Tab retains native focus navigation")
        check(!coordinator.control(field, textView: editor, doCommandBy: NSSelectorFromString("insertBacktab:")), "Shift-Tab is not hijacked by search shortcuts")
        var another = store.siteSearchCatalog.entries.first!; another.id = UUID(); another.keyword = "yy"; try store.saveSiteSearch(another)
        store.command = "y"
        check(!coordinator.control(field, textView: editor, doCommandBy: NSSelectorFromString("insertTab:")) && store.commandSiteSearch == nil, "An ambiguous shortcut prefix preserves native Tab behavior")
        editor.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        check(editor.hasMarkedText(), "The owned input fixture has real marked composition text")
        let beforeComposition = (submits, cancels, moves)
        for selector in ["insertNewline:", "cancelOperation:", "moveUp:", "moveDown:", "insertTab:", "deleteBackward:"] {
            check(!coordinator.control(field, textView: editor, doCommandBy: Selector(selector)), "Primary marked composition forwards \(selector) to AppKit")
        }
        check(submits == beforeComposition.0 && cancels == beforeComposition.1 && moves == beforeComposition.2, "Composition cannot trigger primary browser actions")
        editor.unmarkText()
        check(coordinator.control(field, textView: editor, doCommandBy: NSSelectorFromString("insertNewline:")) && submits == 1, "A committed primary Return invokes submission")

        let quickID = try store.openQuickPage(profileID: f.profile)
        let context = store.searchInputContext(quickID: quickID)!, state = QuickBrowseWindowState()
        state.requestLocation(currentURL: "about:blank", context: context); state.addressText = "yt"
        let quickBinding = Binding(get: { state.addressText }, set: { state.addressText = $0 })
        var quickSubmits = 0, quickCancels = 0, quickMoves = 0
        let quickInput = QuickBrowseInput(text: quickBinding, placeholder: "Quick Search", size: 12, ink: .labelColor, focusRequest: 0, onSubmit: { quickSubmits += 1 }, onCancel: { quickCancels += 1 }, onMove: { quickMoves += $0 }, onTab: { state.activatePreferredSiteSearch(catalog: store.siteSearchCatalog, context: store.searchInputContext(quickID: quickID)) }, onEmptyDelete: { state.deleteEmptySiteSearch() })
        let quickCoordinator = QuickBrowseInput.Coordinator(quickInput), quickField = QuickBrowseInput.Field(string: "")
        check(quickCoordinator.control(quickField, textView: editor, doCommandBy: NSSelectorFromString("insertTab:")) && state.siteSearch?.keyword == "yt" && state.addressText.isEmpty, "Native compact Tab enters its own site-search mode")
        check(quickCoordinator.control(quickField, textView: editor, doCommandBy: NSSelectorFromString("deleteBackward:")) && state.siteSearch == nil && state.addressText == "yt", "Native compact Backspace restores its shortcut")
        editor.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        for selector in ["insertNewline:", "cancelOperation:", "moveUp:", "moveDown:", "insertTab:", "deleteBackward:"] {
            check(!quickCoordinator.control(quickField, textView: editor, doCommandBy: Selector(selector)), "Compact marked composition forwards \(selector) to AppKit")
        }
        check(quickSubmits == 0 && quickCancels == 0 && quickMoves == 0, "Composition cannot trigger compact browser actions")
        editor.unmarkText()
        check(!quickCoordinator.control(quickField, textView: editor, doCommandBy: NSSelectorFromString("insertBacktab:")), "Compact Shift-Tab retains native focus navigation")
        let delegate = AppDelegate()
        let editingWindow = window(NSSize(width: 500, height: 160)); editingWindow.contentView = editor; _ = editingWindow.makeFirstResponder(editor)
        delegate.windows[editingWindow] = store
        store.showCommand(); editor.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        check(!delegate.handleEscape(in: editingWindow) && store.commandVisible, "The app-level Escape handler also preserves active IME composition")
        editor.unmarkText()
        check(delegate.handleEscape(in: editingWindow) && !store.commandVisible, "Escape closes an owned command after composition is committed")
        let protocolWindow = window(NSSize(width: 500, height: 160)), protocolClient = SiteCompositionClient(frame: .zero)
        protocolWindow.contentView = protocolClient; _ = protocolWindow.makeFirstResponder(protocolClient)
        let protocolFixture = try fixture()
        delegate.windows[protocolWindow] = protocolFixture.store
        protocolFixture.store.peekPages[.primary] = PeekState(web: protocolFixture.web, profileID: protocolFixture.profile, spaceID: protocolFixture.store.space.id)
        check(protocolWindow.firstResponder === protocolClient && protocolClient.hasMarkedText(), "The owned first responder composes through NSTextInputClient without NSTextView")
        check(!delegate.handleEscape(in: protocolWindow) && protocolFixture.store.primaryPeekView === protocolFixture.web, "App Escape preserves composition in non-NSTextView text clients")
        protocolFixture.store.peekPages[.primary] = PeekState(web: protocolFixture.web, profileID: protocolFixture.profile, spaceID: protocolFixture.store.space.id)
        protocolClient.unmarkText()
        check(delegate.handleEscape(in: protocolWindow) && protocolFixture.store.primaryPeekView == nil, "Committed non-NSTextView clients can close their own Peek with Escape")
        let editorFixture = try fixture(), editorStore = editorFixture.store
        let originalEntry = editorStore.siteSearchCatalog.entries[0]
        var draft = originalEntry, toggled = originalEntry
        draft.name = "Changed while disabling"; toggled.enabled = false; try editorStore.saveSiteSearch(toggled)
        try SiteSearchPanel.saveDraft(draft, in: editorStore)
        check(editorStore.siteSearchCatalog.entries.first?.enabled == false && editorStore.siteSearchCatalog.entries.first?.name == draft.name, "Saving edited fields preserves a newer disabled toggle")
        toggled = editorStore.siteSearchCatalog.entries[0]; toggled.enabled = false; try editorStore.saveSiteSearch(toggled)
        draft = editorStore.siteSearchCatalog.entries[0]; draft.name = "Changed while enabling"
        toggled = draft; toggled.enabled = true; try editorStore.saveSiteSearch(toggled)
        try SiteSearchPanel.saveDraft(draft, in: editorStore)
        check(editorStore.siteSearchCatalog.entries.first?.enabled == true && editorStore.siteSearchCatalog.entries.first?.name == draft.name, "Saving edited fields preserves a newer enabled toggle")
        store.showCommand(); store.command = "yt"
        let normalOptions = CommandPanel.options(for: store)
        normalOptions[0].run()
        check(store.commandSiteSearch == nil && f.web.requests.last?.url?.absoluteString == "https://duckduckgo.com/?q=yt", "Ordinary Enter keeps normal web search until Tab or an explicit site action")
        store.showCommand(); store.command = "yt"; _ = store.activatePreferredCommandSiteSearch(); store.command = "Pin Tab"
        let selectedOptions = CommandPanel.options(for: store)
        check(selectedOptions.count == 1 && selectedOptions[0].id == "search", "A selected site's query is never interpreted as an app command or tab match")
        store.dismissCommand(); let requests = f.web.requests.count
        store.submitCommandInput()
        check(f.web.requests.count == requests && !store.commandVisible, "A stale closed-command submission cannot fall back to programmatic navigation")
        check(BrowserCommand.siteSearch.matches("site search") && store.availableCommands.contains(.siteSearch), "Site-search settings are discoverable through the command list")
        store.showCommand(); store.runCommand(.siteSearch)
        check(store.presentedPanel == .siteSearch && !store.commandVisible, "The site-search command opens its settings panel after closing input")
        store.presentedPanel = nil; delegate.buildMenu()
        let appMenu = NSApp.mainMenu?.items.first?.submenu
        check(appMenu?.items.contains(where: { $0.action == #selector(AppDelegate.siteSearchSettings) && $0.target === delegate }) == true, "The native app menu exposes the actual site-search settings action")

        for width in [480.0, 760.0] {
            let q = try fixture(), s = q.store
            var appearance = s.appearance; appearance.textScale = 1.35; appearance.animationsEnabled = false; s.appearance = appearance
            let id = try s.openQuickPage(profileID: q.profile); s.update(id) { $0.url = "about:blank" }
            let web = q.anotherWeb(id), uiState = QuickBrowseWindowState()
            let w = window(NSSize(width: width, height: 500))
            let host = NSHostingView(rootView: QuickBrowseUI(store: s, id: id, state: uiState, onPromoteSpace: { _ in }, onPromotePeek: {}, onRequestProfile: { _, _ in }, onManageProfiles: {}, onOpenSettings: {}, onClose: {}, onNewQuick: {}))
            host.safeAreaRegions = []; host.sizingOptions = []
            w.contentView = host
            host.layoutSubtreeIfNeeded()
            try await until { host.layoutSubtreeIfNeeded(); return web.window === w && !descendants(host, as: QuickBrowseInput.Field.self).isEmpty }
            let normalField = descendants(host, as: QuickBrowseInput.Field.self)[0]
            let normalQueryX = normalField.convert(normalField.bounds, to: nil).minX
            let scope = s.searchInputContext(quickID: id)!
            uiState.requestLocation(currentURL: "about:blank", context: scope); uiState.addressText = "yt"
            _ = uiState.activatePreferredSiteSearch(catalog: s.siteSearchCatalog, context: scope)
            try await until { descendants(host, as: QuickBrowseInput.Field.self).first?.placeholderString == "Search YouTube" }
            let native = descendants(host, as: QuickBrowseInput.Field.self)[0]
            host.layoutSubtreeIfNeeded(); let rect = native.convert(native.bounds, to: nil), content = host.convert(host.bounds, to: nil)
            check(rect.width >= 80 && content.insetBy(dx: -1, dy: -1).contains(rect), "Compact site query remains visible at \(Int(width))pt and large text")
            check(native.accessibilityLabel() == "Search YouTube", "The native compact query label updates to its selected site")
            print("PILL RESERVED WIDTH: \(width) \(rect.minX - normalQueryX)")
            check(rect.minX - normalQueryX >= 50, "Compact selected-site pill reserves visible space for its name beside the query")
            check(uiState.siteSearch?.keyword == "yt" && uiState.isEditingAddress, "Selected compact mode survives native layout without a focus transition")
            check(web.window === w && s.views[id] === web, "Selecting compact site mode preserves the mounted native page")
            try render(host, name: "quick-\(Int(width))-large-text")
            if width == 480 {
                let preview = q.anotherWeb(UUID())
                s.peekPages[.quick(id)] = PeekState(web: preview, profileID: q.profile, spaceID: s.space.id)
                for _ in 0..<12 { try await Task.sleep(for: .milliseconds(10)); host.layoutSubtreeIfNeeded() }
                uiState.requestLocation(currentURL: preview.fixtureURL.absoluteString, context: s.searchInputContext(quickID: id))
                uiState.addressText = "yt"; _ = uiState.activatePreferredSiteSearch(catalog: s.siteSearchCatalog, context: s.searchInputContext(quickID: id))
                uiState.addressText = "old preview draft"
                s.peekPages[.quick(id)] = PeekState(web: preview, profileID: q.profile, spaceID: s.space.id)
                for _ in 0..<12 { try await Task.sleep(for: .milliseconds(10)); host.layoutSubtreeIfNeeded() }
                check(uiState.siteSearch == nil && uiState.locationContext == nil && !uiState.isEditingAddress, "Replacing a compact Peek lifetime cancels input even with the same native view")
                s.closeQuickPeek(id)
                for _ in 0..<12 { try await Task.sleep(for: .milliseconds(10)); host.layoutSubtreeIfNeeded() }
                uiState.requestLocation(currentURL: "about:blank", context: s.searchInputContext(quickID: id)); uiState.addressText = "yt"
                _ = uiState.activatePreferredSiteSearch(catalog: s.siteSearchCatalog, context: s.searchInputContext(quickID: id))
            }
            uiState.addressText = "must not follow another account"
            let newOwner = try s.createProfile(name: "Another owned fixture")
            s.namedDataStores[newOwner] = .nonPersistent()
            try s.changeQuickProfile(id, to: newOwner, allowReload: true)
            _ = q.anotherWeb(id, profile: newOwner)
            // Allow the actual SwiftUI owner observer to run; this is not a direct state-helper call.
            for _ in 0..<12 { try await Task.sleep(for: .milliseconds(10)); host.layoutSubtreeIfNeeded() }
            check(uiState.siteSearch == nil && uiState.locationContext == nil && !uiState.isEditingAddress && uiState.addressText == "about:blank", "Changing a compact page's owner clears its selected site and draft")
            uiState.cancelLocation(currentURL: "about:blank")
            try await until { descendants(host, as: QuickBrowseInput.Field.self).first?.placeholderString == "Search or enter a URL" }
        }
        store.showCommand(); store.command = "yt"; _ = store.activatePreferredCommandSiteSearch(); store.command = "a longer site query"
        var large = store.appearance; large.textScale = 1.35; large.animationsEnabled = false; store.appearance = large
        let commandWindow = window(NSSize(width: 600, height: 330))
        let commandHost = NSHostingView(rootView: CommandPanel(store: store, availableHeight: 330).frame(width: 600))
        commandHost.sizingOptions = []; commandHost.safeAreaRegions = []; commandWindow.contentView = commandHost
        commandHost.layoutSubtreeIfNeeded()
        try await until { commandHost.layoutSubtreeIfNeeded(); return !descendants(commandHost, as: FocusedInput.Field.self).isEmpty }
        let commandField = descendants(commandHost, as: FocusedInput.Field.self)[0]
        check(commandField.placeholderString == "Search YouTube" && commandField.accessibilityLabel() == "Search YouTube", "Primary selected mode uses the site's native query label")
        check(commandField.bounds.width >= 80 && commandHost.fittingSize.height <= 331, "Primary selected mode remains bounded in a short host at large text")
        try render(commandHost, name: "command-selected-large-text")
        let settingsWindow = window(NSSize(width: 760, height: 460))
        let settingsHost = NSHostingView(rootView: SiteSearchPanel(store: store, availableHeight: 400))
        settingsWindow.contentView = settingsHost; settingsHost.layoutSubtreeIfNeeded()
        check(settingsHost.fittingSize.height <= 461, "Site-search settings respect a short native host and scrolling")
        try render(settingsHost, name: "settings-short-large-text")
        if failures > 0 { throw SiteSearchInputCheckError.failed }
    }
}
