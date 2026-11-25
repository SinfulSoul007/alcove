import AppKit
import SwiftUI
import WebKit
import BrowserCore

struct QuickWindowKey: Hashable { let ownerID: UUID; let pageID: UUID }
enum PageOutputCommand { case printPage, pdf, webArchive }

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation, NSMenuDelegate {
    var windows: [NSWindow: BrowserStore] = [:]
    var primaryOwners: [NSWindow: BrowserWindowOwner] = [:]
    var primaryLeases: [NSWindow: UUID] = [:]
    var owners: [UUID: BrowserWindowOwner] = [:]
    var normalOwner: BrowserWindowOwner?
    var temporaryStartupOwners: Set<UUID> = []
    var preparingMetadataOwners: Set<UUID> = []
    var pendingStartupQuickRequests:[UUID:Int] = [:]
    var quickWindows: [QuickWindowKey: QuickBrowseWindowController] = [:]
    let pageOutput: PageOutputCoordinator
    lazy var bookmarkExports = BookmarkExportController(output: pageOutput)
    let outputTermination: PageOutputTermination
    let updates = UpdateController(installedTag: Bundle.main.object(forInfoDictionaryKey: "AlcoveReleaseTag") as? String ?? "unknown")
    var normalWindow: NSWindow?
    var spacesMenu: NSMenu?
    var escapeMonitor: Any?
    var paneFocusMonitor: Any?
    var updateTimer: Timer?
    private var terminating = false
    override convenience init() { self.init(pageOutput: PageOutputCoordinator()) }
    init(pageOutput: PageOutputCoordinator, quitPresenter: PageOutputQuitPresenter? = nil) {
        self.pageOutput = pageOutput
        outputTermination = PageOutputTermination(output: pageOutput, presenter: quitPresenter ?? PageOutputNative().quitPresenter)
        super.init()
    }
    var activeBrowserWindow: NSWindow? { NSApp.keyWindow?.sheetParent ?? NSApp.keyWindow ?? NSApp.mainWindow }
    var activeQuick: QuickBrowseWindowController? { quickWindows.values.first { $0.window === activeBrowserWindow } }
    func browserStore(in window: NSWindow?) -> BrowserStore? {
        guard let window else { return nil }
        return quickWindows.values.first { $0.window === window }?.store ?? windows[window]
    }
    var activeStore: BrowserStore? { browserStore(in: activeBrowserWindow) }
    var activeWebView: WKWebView? {
        if let quick = activeQuick { return quick.activeWebView }
        guard let store = activeStore else { return nil }
        return store.primaryPeekView ?? store.currentView
    }
    func outputTarget(in window: NSWindow?) -> (store: BrowserStore, web: WKWebView, window: NSWindow)? {
        guard let window else { return nil }
        let store: BrowserStore, web: WKWebView?
        if let quick = quickWindows.values.first(where: { $0.window === window }) {
            store = quick.store; web = quick.activeWebView
        } else if let primary = windows[window] {
            store = primary; web = primary.primaryPeekView ?? primary.currentView
        } else { return nil }
        guard let web, web.window === window, store.isVisibleWebsite(web) else { return nil }
        return (store, web, window)
    }
    func performPageOutput(_ command: PageOutputCommand, in window: NSWindow?) {
        guard let target = outputTarget(in: window) else { return }
        switch command {
        case .printPage: pageOutput.printPage(web: target.web, store: target.store, window: target.window)
        case .pdf: pageOutput.save(web: target.web, store: target.store, window: target.window, format: .pdf)
        case .webArchive: pageOutput.save(web: target.web, store: target.store, window: target.window, format: .webArchive)
        }
    }
    @objc func toggleReader() { if let target = outputTarget(in: activeBrowserWindow) { target.store.toggleReader(target.web) } }
    @objc func printPage() { performPageOutput(.printPage, in: activeBrowserWindow) }
    @objc func exportPDF() { performPageOutput(.pdf, in: activeBrowserWindow) }
    @objc func savePage() { performPageOutput(.webArchive, in: activeBrowserWindow) }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular); buildMenu()
        let owner = ensureNormalOwner()
        if owner.store.awaitingInitialMetadata { openPrimary(owner, startupPlaceholder: true) }
        else if owner.store.onboardingVisible || owner.store.savedWindowRestore != nil || owner.store.allQuickPages.isEmpty { openPrimary(owner) }
        else { syncQuickWindows(owner); quickWindows.values.first(where: { $0.windowOwner === owner })?.surface() }
        NSApp.activate(ignoringOtherApps: true)
        updateTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkNormalWindowAutomatically() }
        }
        updateTimer?.tolerance = 60
        paneFocusMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let window = event.window, let store = self.windows[window],
                  store.primaryPeekView == nil, !store.commandVisible, store.visibleRecentTabSwitcher == nil else { return event }
            for (id, web) in store.views where web.window === window {
                if web.convert(web.bounds, to: nil).contains(event.locationInWindow) { store.focusPane(id); break }
            }
            return event
        }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            if self.handleRecentTabInput(event) { return nil }
            if event.type == .keyDown, event.keyCode == 53, self.handleEscape(in: event.window) { return nil }
            return event
        }
    }
    func hasMarkedText(in window: NSWindow?) -> Bool {
        (window?.firstResponder as? NSTextInputClient)?.hasMarkedText() == true
    }
    @discardableResult func handleEscape(in window: NSWindow?) -> Bool {
        guard let window, !hasMarkedText(in: window) else { return false }
        if let manager=ExtensionManagerWindowController.active {manager.escape();return true}
        if SidebarResizeHandle.cancelActiveResize(in: window) { return true }
        if let pickerStore = browserStore(in: window), pickerStore.boostPicker?.source.window === window { pickerStore.cancelBoostPicker(); return true }
        if let target = outputTarget(in: window), let reader = target.store.readerSession(for: target.web) { if reader.searchVisible { reader.dismissFind() } else { reader.dismiss(restoringFocus: true) }; return true }
        if let quick = quickWindows.values.first(where: { $0.window === window }),
           quick.state.findVisible || quick.state.isEditingAddress || quick.store.quickPeekView(quick.pageID) != nil { quick.escape(); return true }
        guard let store = windows[window] else { return false }
        if store.presentedPanel == .boosts { Task { @MainActor [weak store] in _ = await store?.finishBoostEditor() } }
        else if store.presentedPanel != nil { store.presentedPanel = nil }
        else if store.commandVisible { store.dismissCommand() }
        else if store.findVisible { store.findVisible = false }
        else if store.primaryPeekView != nil { store.closePrimaryPeek() }
        else { return false }
        return true
    }
    func makeOwner(_ store: BrowserStore) -> BrowserWindowOwner {
        let owner = BrowserWindowOwner(store: store) { [weak self, weak store] in
            guard let self, let store else { return }
            if let id = self.owners.first(where: { $0.value.store === store })?.key {
                self.temporaryStartupOwners.remove(id);self.pendingStartupQuickRequests.removeValue(forKey:id)
            }
            self.owners = self.owners.filter { $0.value.store !== store }
            if self.normalOwner?.store === store { self.normalOwner = nil }
        }
        owners[owner.id] = owner
        configurePrimaryActions(store, owner: owner)
        store.metadataDidLoad = { [weak self, weak owner] in if let owner { self?.metadataDidLoad(owner) } }
        store.quickPagesDidChange = { [weak self, weak owner] in if let owner { self?.syncQuickWindows(owner) } }
        return owner
    }
    private func configurePrimaryActions(_ store: BrowserStore, owner: BrowserWindowOwner) {
        store.privateWindowRequested = { [weak self] in self?.openWindow(isPrivate: true) }
        store.extensionPrimaryWindowRequested = { [weak self,weak owner] in if let owner {self?.openPrimary(owner)} }
        store.onboardingDidFinish = { [weak self, weak store] in if let store { self?.checkAutomaticallyIfNeeded(store) } }
        store.automaticUpdatesDidChange = { [weak self, weak store] in if let store { self?.checkAutomaticallyIfNeeded(store) } }
        store.quickPageRequested = { [weak self, weak owner] id in
            guard let self, let owner else { return }
            self.syncQuickWindows(owner)
            if !self.preparingMetadataOwners.contains(owner.id) { self.quickWindows[QuickWindowKey(ownerID: owner.id, pageID: id)]?.surface() }
        }
    }
    func ensureNormalOwner() -> BrowserWindowOwner {
        if let normalOwner, !normalOwner.isClosed { return normalOwner }
        let owner = makeOwner(BrowserStore()); normalOwner = owner
        // Restored records have no native media yet; expire them before mounting windows.
        if !owner.store.awaitingInitialMetadata { owner.store.archiveInactiveQuickPages(); syncQuickWindows(owner) }
        return owner
    }
    func metadataDidLoad(_ owner: BrowserWindowOwner) {
        guard !owner.isClosed, !owner.store.awaitingInitialMetadata else { return }
        let mayActivate = NSApp.isActive && (activeStore == nil || activeStore === owner.store)
        let temporary = temporaryStartupOwners.remove(owner.id) != nil
        let restoresPrimary = owner.store.savedWindowRestore != nil && owner.store.windowGroup == nil
        preparingMetadataOwners.insert(owner.id)
        owner.store.archiveInactiveQuickPages()
        // Resolve explicit New Quick Browse requests only after the actual saved
        // account is known. Native compact leases precede placeholder disposal.
        let requests=pendingStartupQuickRequests.removeValue(forKey:owner.id) ?? 0
        for _ in 0..<requests {
            do {_ = try owner.store.openQuickPage()}
            catch {owner.store.message=error.localizedDescription;break}
        }
        if restoresPrimary { openPrimary(owner, activate: false) }
        let destinations = owner.drainExternalLinks()
        preparingMetadataOwners.remove(owner.id)
        syncQuickWindows(owner, orderFront: mayActivate)
        let needsPrimary = destinations.contains { if case .space = $0 { return true }; return false }
        if temporary && !needsPrimary && !restoresPrimary && owner.store.savedWindowRestore == nil && !owner.store.onboardingVisible && !owner.store.allQuickPages.isEmpty,
           let primary = primaryOwners.first(where: { $0.value === owner })?.key,
           quickWindows.values.contains(where: { $0.windowOwner === owner }) {
            // Compact controllers hold leases before the placeholder releases its lease.
            primary.close()
            if mayActivate { quickWindows.values.first(where: { $0.windowOwner === owner })?.surface() }
        } else if needsPrimary || restoresPrimary {
            showExternalPresenter(of: owner, activate: mayActivate)
        } else if preferredPrimary(of: owner) != nil || owner.store.savedWindowRestore != nil {
            openPrimary(owner, activate: mayActivate)
        }
        checkAutomaticallyIfNeeded(owner.store)
    }
    func syncQuickWindows(_ owner: BrowserWindowOwner, orderFront: Bool = true) {
        guard !owner.isClosed, !owner.store.awaitingInitialMetadata, !preparingMetadataOwners.contains(owner.id) else { return }
        let pages = owner.store.allQuickPages
        let ids = Set(pages.map(\.id))
        let removed = quickWindows.values.filter { $0.windowOwner === owner && !ids.contains($0.pageID) }
        for controller in removed { controller.modelDidRemovePage() }
        func present(_ window: NSWindow?) {
            if orderFront { window?.orderFront(nil) }
            else { window?.orderBack(nil) }
        }
        for page in pages {
            let key = QuickWindowKey(ownerID: owner.id, pageID: page.id)
            if let existing = quickWindows[key] {
                if existing.window?.isVisible == false { present(existing.window) }
                continue
            }
            do {
                let controller = try QuickBrowseWindowController(owner: owner, pageID: page.id,
                    requestPrimary: { [weak self, weak owner] in if let owner { self?.openPrimary(owner) } },
                    requestProfiles: { [weak self] in self?.manageProfiles() },
                    didClose: { [weak self] in self?.quickWindows.removeValue(forKey: key) })
                quickWindows[key] = controller; present(controller.window)
            } catch { owner.store.message = error.localizedDescription }
        }
    }
    func openWindow(isPrivate: Bool) {
        if !isPrivate { openPrimary(ensureNormalOwner()); return }
        let store = BrowserStore(isPrivate: true)
        if let normal = normalOwner?.store {
            store.preferences.appearance = normal.preferences.appearance
            store.session.spaces[0].theme = normal.space.theme; store.session.spaces[0].customTheme = normal.space.customTheme
        }
        openPrimary(makeOwner(store))
    }
    func openPrimary(_ owner: BrowserWindowOwner, startupPlaceholder: Bool = false, activate: Bool = true) {
        guard !owner.isClosed else { return }
        if startupPlaceholder { temporaryStartupOwners.insert(owner.id) } else { temporaryStartupOwners.remove(owner.id) }
        let existing = preferredPrimary(of: owner)
        let store = owner.store
        if !store.isPrivate, store.savingEnabled, !store.awaitingInitialMetadata, store.vault != nil {
            do {
                let restored = try owner.restorePrimaryStores(reusing: existing.flatMap { primaryLeases[$0] })
                if !restored.isEmpty {
                    var focused: NSWindow?
                    for entry in restored {
                        let window: NSWindow
                        if entry.store === store, let existing { window = existing }
                        else { window = makePrimaryWindow(entry.store, owner: owner, lease: entry.lease) }
                        applyRestoredFrame(entry.frame, to: window)
                        if entry.focused { focused = window }
                        if window !== existing { window.orderBack(nil) }
                    }
                    if let focused {
                        normalWindow = focused
                        if activate { surfacePrimary(focused) }
                    }
                    return
                }
                if let existing {
                    if let lease = primaryLeases[existing] { try owner.adoptPrimaryLease(lease) }
                    if activate { surfacePrimary(existing) }
                } else {
                    let member = try owner.acquirePrimaryStore()
                    let window = makePrimaryWindow(member.store, owner: owner, lease: member.lease)
                    if activate { surfacePrimary(window) }
                }
            } catch { store.message = error.localizedDescription }
            return
        }
        if let existing { if activate { surfacePrimary(existing) }; return }
        guard let lease = try? owner.acquirePrimary() else { return }
        let window = makePrimaryWindow(store, owner: owner, lease: lease)
        if activate { surfacePrimary(window) }
    }
    private func preferredPrimary(of owner: BrowserWindowOwner) -> NSWindow? {
        if let activeBrowserWindow, primaryOwners[activeBrowserWindow] === owner,
           windows[activeBrowserWindow]?.extensionPopupProfileID == nil { return activeBrowserWindow }
        if let window = owner.store.windowGroup?.focusedPrimary?.extensionWindows[.primary]?.window,
           primaryOwners[window] === owner { return window }
        if let normalWindow, primaryOwners[normalWindow] === owner { return normalWindow }
        return primaryOwners.first(where: { $0.value === owner && windows[$0.key]?.extensionPopupProfileID == nil })?.key
    }
    private func surfacePrimary(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }
    private func showExternalPresenter(of owner: BrowserWindowOwner, activate: Bool = true) {
        if let presenter = owner.store.windowGroup?.focusedPrimary,
           let window = presenter.extensionWindows[.primary]?.window, primaryOwners[window] === owner {
            if activate { surfacePrimary(window) }
        } else { openPrimary(owner, activate: activate) }
    }
    private func makePrimaryWindow(_ store: BrowserStore, owner: BrowserWindowOwner, lease: UUID) -> NSWindow {
        let compact = store.extensionPopupProfileID != nil
        let frame = NSRect(x: 0, y: 0, width: compact ? 760 : 1260, height: compact ? 600 : 820)
        let window = ExtensionCommandWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.extensionStore=store;window.extensionCommandSource={[weak store] in store?.primaryPeekView ?? store?.currentView}
        window.title = store.isPrivate ? "Alcove — Private" : "Alcove"; window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false; window.delegate = self
        window.minSize = compact ? NSSize(width: 440, height: 340) : NSSize(width: 800, height: 540)
        let hosting = NSHostingView(rootView: BrowserUI(store: store).environmentObject(updates))
        hosting.safeAreaRegions = []; hosting.sizingOptions = [.minSize]; window.contentView = hosting
        windows[window] = store; primaryOwners[window] = owner; primaryLeases[window] = lease
        if store !== owner.store { configurePrimaryActions(store, owner: owner) }
        store.registerExtensionWindow(window,kind:.primary)
        if !store.isPrivate, !compact { normalWindow = window }
        window.center()
        checkAutomaticallyIfNeeded(store)
        return window
    }
    private func applyRestoredFrame(_ frame: BrowserWindowFrame?, to window: NSWindow) {
        guard let frame else { return }
        let saved = CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
        let screens = NSScreen.screens
        let screen = screens.first { $0.frame.intersects(saved) } ?? window.screen ?? NSScreen.main
        if let screen, let adjusted = frame.constrained(to: screen.visibleFrame, minimumSize: window.minSize) {
            window.setFrame(adjusted, display: false)
        }
    }
    @available(macOS 15.4, *)
    func openExtensionWindow(for writer: BrowserStore, profileID: UUID, configuration: WKWebExtension.WindowConfiguration,
                             moving tabIDs: [UUID]) throws -> BrowserStore {
        guard let owner = normalOwner, owner.store === writer, !owner.isClosed, !writer.isPrivate else {
            throw ExtensionHostError.stale
        }
        let frame = configuration.frame
        let dimensions = [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height]
        guard dimensions.allSatisfy({ $0.isFinite || $0.isNaN }),
              frame.size.width.isNaN || frame.size.width > 0, frame.size.height.isNaN || frame.size.height > 0 else {
            throw ExtensionHostError.native("The requested window frame is unavailable.")
        }
        try writer.requireQuickProfile(profileID)
        let previous = normalWindow
        let popupProfileID = configuration.windowType == .popup ? profileID : nil
        let member = try owner.acquirePrimaryStore(copying: writer.windowGroup?.focusedPrimary,
                                                   focus: configuration.shouldBeFocused, claimSelection: false,
                                                   popupProfileID: popupProfileID)
        do { try member.store.prepareExtensionWindowTabs(profileID: profileID, URLs: configuration.tabURLs, moving: tabIDs) }
        catch { owner.release(member.lease); throw error }

        let window = makePrimaryWindow(member.store, owner: owner, lease: member.lease)
        let defaultFrame = window.frame
        applyRestoredFrame(BrowserWindowFrame(x: frame.origin.x.isNaN ? defaultFrame.origin.x : frame.origin.x,
                                              y: frame.origin.y.isNaN ? defaultFrame.origin.y : frame.origin.y,
                                              width: frame.size.width.isNaN ? defaultFrame.width : frame.size.width,
                                              height: frame.size.height.isNaN ? defaultFrame.height : frame.size.height), to: window)
        if configuration.shouldBeFocused { surfacePrimary(window) }
        else {
            if let previous { normalWindow = previous }
            window.orderBack(nil)
        }
        switch configuration.windowState {
        case .normal: break
        case .minimized: window.miniaturize(nil)
        case .maximized: window.zoom(nil)
        case .fullscreen: window.toggleFullScreen(nil)
        @unknown default: break
        }
        return member.store
    }
    func checkAutomaticallyIfNeeded(_ store: BrowserStore) {
        guard !store.isPrivate, !store.onboardingVisible, store.savingEnabled, store.preferences.automaticUpdateChecks == true, !updates.checking else { return }
        let defaults = UserDefaults.standard; let now = Date()
        guard UpdateCheckSchedule.isDue(lastAttempt: defaults.object(forKey: "lastAutomaticUpdateAttempt") as? Date, now: now) else { return }
        defaults.set(now, forKey: "lastAutomaticUpdateAttempt")
        let channel = UpdateChannel(rawValue: store.preferences.updateChannel ?? "preview") ?? .preview
        Task { await updates.check(channel: channel) }
    }
    func checkNormalWindowAutomatically() { if let store = normalOwner?.store { checkAutomaticallyIfNeeded(store) } }
    func applicationDidBecomeActive(_ notification: Notification) { checkNormalWindowAutomatically() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { openWindow(isPrivate: false); return true }
    func applicationDidResignActive(_ notification: Notification) {
        for store in windows.values { store.cancelRecentTabSwitcher() }
    }
    func windowDidResignKey(_ notification: Notification) {
        if let window = notification.object as? NSWindow { windows[window]?.cancelRecentTabSwitcher() }
    }
    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let store = windows[window], !store.isPrivate,
              store.extensionPopupProfileID == nil else { return }
        normalWindow = window
        store.windowGroup?.focusPrimary(store)
    }
    func windowDidMove(_ notification: Notification) { recordPrimaryFrame(notification) }
    func windowDidResize(_ notification: Notification) { recordPrimaryFrame(notification) }
    private func recordPrimaryFrame(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let store = windows[window],
              !window.styleMask.contains(.fullScreen), !window.isMiniaturized else { return }
        let frame = window.frame
        store.windowGroup?.recordFrame(BrowserWindowFrame(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height), for: store)
    }
    func windowShouldClose(_ window: NSWindow) -> Bool {
        guard !terminating, let store = windows[window], store.extensionPopupProfileID != nil else { return true }
        do { try store.closeExtensionPopupTabs(); return true }
        catch { store.message = error.localizedDescription; return false }
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        pageOutput.cancel(in: window)
        let owner = primaryOwners.removeValue(forKey: window); let lease = primaryLeases.removeValue(forKey: window)
        let store = windows.removeValue(forKey: window); window.contentView = nil
        store?.cancelRecentTabSwitcher()
        store?.unregisterExtensionWindow(kind:.primary)
        if normalWindow === window { normalWindow = owner.flatMap { preferredPrimary(of: $0) } }
        guard !terminating else { return }
        if store?.windowGroupID == nil { store?.closePrimaryWindowPages() }
        if let lease { owner?.release(lease) }
    }
    func applicationWillTerminate(_ notification: Notification) {
        updateTimer?.invalidate()
        for owner in Array(owners.values) { owner.shutdown() }
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        if let paneFocusMonitor { NSEvent.removeMonitor(paneFocusMonitor) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func terminationDecision(reply: @escaping (Bool) -> Void) -> NSApplication.TerminateReply { outputTermination.decision(reply: reply) }
    func resurfaceQuitChoices() -> Bool { outputTermination.resurface() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let decision = terminationDecision { [weak self] allowed in
            if allowed { self?.terminating = true }
            sender.reply(toApplicationShouldTerminate: allowed)
        }
        if decision == .terminateNow { terminating = true }
        return decision
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        let owner = ensureNormalOwner()
        if !owner.store.awaitingInitialMetadata, owner.store.savedWindowRestore != nil, owner.store.windowGroup == nil {
            openPrimary(owner, activate: false)
        }
        for url in urls where QuickBrowseRouting.host(for: url) != nil {
            do {
                switch try owner.dispatchExternal(url) {
                case .space: showExternalPresenter(of: owner)
                case .pending:
                    let temporary = temporaryStartupOwners.contains(owner.id) || !primaryOwners.values.contains { $0 === owner }
                    openPrimary(owner, startupPlaceholder: temporary)
                case .quick: break
                }
            }
            catch { openPrimary(owner); owner.store.message = "This link could not open. " + error.localizedDescription }
        }
    }
    func buildMenu() {
        let main = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(); item.title = title; let menu = NSMenu(title: title); item.submenu = menu; main.addItem(item); return menu
        }
        func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.keyEquivalentModifierMask = modifiers; item.target = self; menu.addItem(item)
        }
        let app = submenu("Alcove")
        add(app, "About Alcove", #selector(about), ""); add(app, "Settings…", #selector(settings), ",")
        add(app, "Site Search Settings…", #selector(siteSearchSettings), "")
        add(app, "Link Routing Settings…", #selector(linkRoutingSettings), "")
        add(app, "Website Boosts…", #selector(websiteBoosts), "")
        add(app, "Extensions…", #selector(manageExtensions), "")
        add(app, "Customize…", #selector(customize), ",", [.command, .shift])
        add(app, "Manage Profiles…", #selector(manageProfiles), "")
        add(app, "Check for Updates…", #selector(checkUpdates), "")
        add(app, "Welcome to Alcove…", #selector(welcome), "")
        app.addItem(.separator()); add(app, "Quit Alcove", #selector(quit), "q")
        let file = submenu("File")
        add(file, "New Window", #selector(newBrowserWindow), "n"); add(file, "Open Main Window", #selector(openMain), "")
        add(file, "New Quick Browse", #selector(newQuick), "n", [.command, .option])
        add(file, "New Tab", #selector(newTab), "t"); add(file, "New Private Window", #selector(privateWindow), "n", [.command, .shift])
        add(file, "Duplicate Tab", #selector(duplicateTab), "")
        add(file, "New Space…", #selector(newSpace), "n", [.command, .control]); add(file, "Open Location…", #selector(location), "l")
        add(file, "New Folder…", #selector(newFolder), "")
        add(file, "Import Bookmarks HTML…", #selector(importBookmarks), "")
        add(file, "Export Bookmarks HTML…", #selector(exportBookmarks), "")
        add(file, "Import Preview Session…", #selector(importSession), "")
        file.addItem(.separator())
        add(file, "Save Page As…", #selector(savePage), "s", [.command, .shift])
        add(file, "Export as PDF…", #selector(exportPDF), "")
        add(file, "Print…", #selector(printPage), "p")
        file.addItem(.separator())
        add(file, "Close Tab", #selector(closeTab), "w"); add(file, "Reopen Closed Tab", #selector(reopen), "t", [.command, .shift])
        let edit = submenu("Edit")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] { edit.addItem(NSMenuItem(title: title, action: Selector(action), keyEquivalent: key)) }
        add(edit, "Find in Page…", #selector(find), "f")
        let view = submenu("View")
        add(view, "Reload", #selector(reload), "r"); add(view, "Toggle Sidebar", #selector(sidebar), "s")
        add(view, "Toggle Split View", #selector(split), "d", [.command, .shift]); add(view, "Pin / Unpin Tab", #selector(pin), "p", [.command, .shift])
        add(view, "Show Reader", #selector(toggleReader), "")
        add(view, "Close Peek", #selector(closePeek), "\u{1b}", [])
        add(view, "Next Recent Tab", #selector(nextTab), "\t", .control); add(view, "Previous Recent Tab", #selector(previousTab), "\t", [.control, .shift])
        add(view, "Next Space", #selector(nextSpace), "\u{f703}", [.command, .option]); add(view, "Previous Space", #selector(previousSpace), "\u{f702}", [.command, .option])
        add(view, "Zoom In", #selector(zoomIn), "="); add(view, "Zoom Out", #selector(zoomOut), "-"); add(view, "Actual Size", #selector(resetZoom), "0")
        spacesMenu = submenu("Spaces"); spacesMenu?.delegate = self
        if let spacesMenu { rebuildSpacesMenu(spacesMenu) }
        let library = submenu("Library")
        add(library, "Show Library", #selector(showLibrary), "b", [.command, .shift])
        add(library, "Show Downloads", #selector(showDownloads), "l", [.command, .option])
        add(library, "Bookmark This Page", #selector(bookmark), "d")
        let history = submenu("History")
        add(history, "Back", #selector(back), "["); add(history, "Forward", #selector(forward), "]")
        let window = submenu("Window"); NSApp.windowsMenu = window
        window.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        NSApp.mainMenu = main
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if ExtensionManagerWindowController.active != nil {
            return [#selector(closeTab),#selector(quit),#selector(about),#selector(manageExtensions)].contains(menuItem.action)
        }
        if menuItem.action == #selector(manageExtensions) {return activeStore != nil}
        if menuItem.action == #selector(closePeek), hasMarkedText(in: NSApp.keyWindow) { return false }
        if menuItem.action == #selector(toggleReader) {
            guard let target = outputTarget(in: activeBrowserWindow) else { return false }
            menuItem.title = target.store.readerSession(for: target.web) == nil ? "Show Reader" : "Exit Reader"
            return target.window.attachedSheet == nil && target.store.canToggleReader(for: target.web)
        }
        let outputActions: Set<Selector> = [#selector(printPage), #selector(exportPDF), #selector(savePage)]
        if let action = menuItem.action, outputActions.contains(action) {
            guard let target = outputTarget(in: activeBrowserWindow) else { return false }
            let reading = target.store.readerSession(for: target.web) != nil
            if action == #selector(printPage) { menuItem.title = reading ? "Print Original Page…" : "Print…" }
            else if action == #selector(exportPDF) { menuItem.title = reading ? "Export Original Page as PDF…" : "Export as PDF…" }
            else { menuItem.title = reading ? "Save Original Page As…" : "Save Page As…" }
            return pageOutput.canBegin(web: target.web, store: target.store, window: target.window)
        }
        if activeStore?.awaitingInitialMetadata == true {
            return [#selector(openMain), #selector(newBrowserWindow), #selector(newQuick), #selector(privateWindow), #selector(closeTab), #selector(quit), #selector(about)].contains(menuItem.action)
        }
        let general: Set<Selector> = [#selector(openMain), #selector(newBrowserWindow), #selector(privateWindow), #selector(manageProfiles), #selector(quit), #selector(about), #selector(settings), #selector(customize), #selector(checkUpdates), #selector(siteSearchSettings), #selector(linkRoutingSettings), #selector(websiteBoosts), #selector(manageSpaces), #selector(recentlyDeletedSpaces)]
        if let action = menuItem.action, general.contains(action) { return true }
        guard let store = activeStore else { return menuItem.action == #selector(newTab) || menuItem.action == #selector(newQuick) || menuItem.action == #selector(location) }
        if menuItem.action == #selector(selectSpaceMenu(_:)),let id = menuItem.representedObject as? UUID {
            return store.session.spaces.contains(where:{$0.id == id})
        }
        if menuItem.action == #selector(undoSpaceDeletion) { return store.canUndoSpaceDeletion }
        if [#selector(renameCurrentSpace),#selector(deleteCurrentSpace),#selector(moveCurrentSpaceLeft),#selector(moveCurrentSpaceRight)].contains(menuItem.action) {
            guard activeQuick == nil,store.canManageSpace(store.space.id) else { return false }
            if menuItem.action == #selector(moveCurrentSpaceLeft) { return store.spaceIndex > 0 }
            if menuItem.action == #selector(moveCurrentSpaceRight) { return store.spaceIndex < store.session.spaces.count - 1 }
            return true
        }
        let quick = activeQuick
        let profile = quick.flatMap { store.quickProfileID($0.pageID) } ?? store.activeProfileID
        let available = !store.profileUnavailable(profile)
        if quick != nil {
            switch menuItem.action {
            case #selector(sidebar), #selector(split), #selector(pin), #selector(reopen), #selector(nextTab), #selector(previousTab), #selector(nextSpace), #selector(previousSpace), #selector(newSpace), #selector(newFolder), #selector(importSession), #selector(importBookmarks), #selector(exportBookmarks): return false
            default: break
            }
        }
        switch menuItem.action {
        case #selector(newQuick), #selector(newSpace), #selector(newFolder): return store.canModifyLocalMetadata && !store.profileDataOperationInProgress && available
        case #selector(pin), #selector(reopen): return store.canModifyLocalMetadata && available
        case #selector(duplicateTab): return quick == nil && (store.focusedID.map(store.canDuplicateSidebarTab) ?? false)
        case #selector(bookmark): return !store.isPrivate && store.savingEnabled && available && activeWebView?.url != nil
        case #selector(importBookmarks): return store.canImportBookmarkHTML
        case #selector(exportBookmarks): return activeBrowserWindow.map { bookmarkExports.canBegin(store: store, window: $0) } ?? false
        case #selector(importSession): return !store.isPrivate && store.savingEnabled && available
        case #selector(welcome): return !store.isPrivate && store.savingEnabled
        case #selector(back): return activeWebView?.canGoBack == true && available
        case #selector(forward): return activeWebView?.canGoForward == true && available
        case #selector(reload), #selector(find), #selector(zoomIn), #selector(zoomOut), #selector(resetZoom): return activeWebView != nil && available
        default: return true
        }
    }
    @objc func about() { NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Alcove", .applicationVersion: updates.installedTag + " · Unsigned Preview", .credits: NSAttributedString(string: "An independent, open-source WebKit browser for Mac. Not notarized by Apple.")]) }
    @objc func quit() { if !resurfaceQuitChoices() { NSApp.terminate(nil) } }
    @objc func openMain() { openWindow(isPrivate: false) }
    @objc func newBrowserWindow() {
        let owner = ensureNormalOwner()
        guard preferredPrimary(of: owner) != nil, owner.store.savingEnabled, !owner.store.awaitingInitialMetadata else {
            openPrimary(owner)
            return
        }
        openPrimary(owner, activate: false)
        let source = preferredPrimary(of: owner).flatMap { windows[$0] }
        do {
            let member = try owner.acquirePrimaryStore(copying: source)
            surfacePrimary(makePrimaryWindow(member.store, owner: owner, lease: member.lease))
        } catch { (source ?? owner.store).message = error.localizedDescription }
    }
    @objc func newQuick() {
        if let quick = activeQuick { quick.newQuick(); return }
        let owner = activeBrowserWindow.flatMap { primaryOwners[$0] } ?? ensureNormalOwner()
        if owner.store.awaitingInitialMetadata {
            let count=pendingStartupQuickRequests[owner.id,default:0]
            guard count<8 else {owner.store.message="Eight Quick Browse windows are already waiting for this profile to unlock.";return}
            pendingStartupQuickRequests[owner.id]=count+1
            let temporary=temporaryStartupOwners.contains(owner.id) || !primaryOwners.values.contains(where:{$0 === owner})
            openPrimary(owner,startupPlaceholder:temporary);return
        }
        let source = activeBrowserWindow.flatMap { windows[$0] } ?? owner.store
        do { _ = try source.openQuickPage() }
        catch { openPrimary(owner); owner.store.message = error.localizedDescription }
    }
    @objc func newTab() {
        guard ExtensionManagerWindowController.active == nil else {return}
        if let quick = activeQuick { quick.newQuick(); return }
        if activeStore == nil { openMain() }
        guard let store = activeStore else { return }
        store.presentedPanel = nil; if store.onboardingVisible { store.finishOnboarding() }; store.showCommand(new: true)
    }
    @objc func privateWindow() { openWindow(isPrivate: true) }
    @objc func closePeek() {
        if let quick = activeQuick { quick.escape(); return }
        guard let store = activeStore else { return }
        if store.presentedPanel != nil { store.presentedPanel = nil }
        else if store.commandVisible { store.commandVisible = false }
        else if store.findVisible { store.findVisible = false }
        else { store.closePrimaryPeek() }
    }
    func stepTab(_ delta: Int) {
        guard activeQuick == nil, NSApp.keyWindow?.sheetParent == nil,
              ExtensionManagerWindowController.active == nil,
              let store = activeStore, store.advanceRecentTab(delta) else { return }
        store.chooseRecentTab()
    }
    func stepSpace(_ delta: Int) {
        guard activeQuick == nil, let store = activeStore else { return }
        let spaces = store.session.spaces; store.selectSpace(spaces[(store.spaceIndex + delta + spaces.count) % spaces.count].id)
    }
    @objc func nextTab() { stepTab(1) }
    @objc func previousTab() { stepTab(-1) }
    @objc func nextSpace() { stepSpace(1) }
    @objc func previousSpace() { stepSpace(-1) }
    @objc func importSession() { guard activeQuick == nil, let store = activeStore, !store.isPrivate, store.savingEnabled, !store.profileUnavailable(store.activeProfileID) else { return }; store.importLegacySession() }
    @objc func newSpace() { if activeQuick == nil { activeStore?.requestNewSpace() } }
    @objc func newFolder() {if activeQuick == nil {activeStore?.requestNewTabFolder()}}
    @objc func duplicateTab() {
        guard activeQuick == nil, let store = activeStore, let id = store.focusedID else { return }
        store.duplicateSidebarTab(id)
    }
    @objc func location() {
        guard ExtensionManagerWindowController.active == nil else {return}
        if let quick = activeQuick { quick.requestLocation(); return }
        if activeStore == nil { openMain() }
        guard let store = activeStore else { return }
        store.presentedPanel = nil; if store.onboardingVisible { store.finishOnboarding() }; store.showCommand()
    }
    @objc func closeTab() {
        if let manager=ExtensionManagerWindowController.active {manager.closeFrontmost();return}
        if let quick = activeQuick { quick.window?.performClose(nil); return }
        guard let window = activeBrowserWindow,let store = browserStore(in:window) else {return}
        if store.awaitingInitialMetadata {window.performClose(nil);return}
        if store.presentedPanel != nil {store.presentedPanel = nil;return}
        if store.primaryPeekView != nil {store.closePrimaryPeek();return}
        func isLocal(_ id: UUID) -> Bool {
            (store.windowGroup?.presentation(tabID: id, in: store) ?? .owned) == .owned
        }
        let closingID = store.focusedID
        let splitSurvivors = store.splitLayout?.tabIDs.filter { $0 != closingID } ?? []
        if let closingID, isLocal(closingID) { store.close(closingID) }
        if splitSurvivors.contains(where: { store.visiblePaneIDs.contains($0) && store.tab($0)?.url.isEmpty == false && isLocal($0) }) {
            return
        }
        let visibleTabs = store.extensionPopupProfileID == nil ? store.space.tabs : store.extensionPopupTabs
        guard let next = visibleTabs.first(where: { !$0.pinned && !$0.url.isEmpty && isLocal($0.id) }) else {
            window.performClose(nil)
            return
        }
        if store.focusedID.map(isLocal) != true {
            if store.extensionPopupProfileID == nil { store.select(next.id) }
            else { store.selectExtensionPopupTab(next.id) }
        }
    }
    @objc func reopen() { guard activeQuick == nil, let store = activeStore, store.canModifyLocalMetadata, !store.profileUnavailable(store.activeProfileID) else { return }; store.reopenClosed() }
    @objc func reload() { activeWebView?.reload() }
    @objc func sidebar() { if activeQuick == nil, let store = activeStore, store.extensionPopupProfileID == nil { store.sidebarVisible.toggle() } }
    @objc func split() { if activeQuick == nil { activeStore?.toggleSplit() } }
    @objc func pin() { if activeQuick == nil, let store = activeStore, store.canModifyLocalMetadata, !store.profileUnavailable(store.activeProfileID), let id = store.focusedID { store.togglePin(id) } }
    @objc func back() { activeWebView?.goBack() }
    @objc func forward() { activeWebView?.goForward() }
    @objc func find() {
        if let source = activeWebView, let reader = activeStore?.readerSession(for: source) { reader.requestFind(); return }
        if let quick = activeQuick { quick.state.showFind() } else { activeStore?.findVisible = true }
    }
    func zoom(_ amount: Double) { if let source = activeWebView { let web = activeStore?.readerSession(for: source)?.reader ?? source; web.pageZoom = min(3, max(0.5, web.pageZoom + amount)) } }
    @objc func zoomIn() { zoom(0.1) }
    @objc func zoomOut() { zoom(-0.1) }
    @objc func resetZoom() { if let source = activeWebView { (activeStore?.readerSession(for: source)?.reader ?? source).pageZoom = 1 } }
    func primaryForActive() -> BrowserStore {
        let owner = activeQuick?.windowOwner ?? activeBrowserWindow.flatMap { primaryOwners[$0] } ?? ensureNormalOwner()
        openPrimary(owner)
        return preferredPrimary(of: owner).flatMap { windows[$0] } ?? owner.store
    }
    @objc func showLibrary() { showLibrarySection() }
    @objc func showDownloads() { showLibrarySection(.downloads) }
    private func showLibrarySection(_ section: LibrarySection? = nil) {
        let profile = activeQuick.flatMap { $0.store.quickProfileID($0.pageID) }
        let store = primaryForActive()
        do {
            if let profile { try store.focusProfileSpace(profile) }
            if let section { store.librarySection = section }
            store.libraryVisible = true
        } catch { store.message = error.localizedDescription }
    }
    @objc func bookmark() {
        guard let store = activeStore, let web = activeWebView else { return }
        do { try store.bookmarkWebsite(web) } catch { store.message = error.localizedDescription }
    }
    @objc func settings() { primaryForActive().settingsVisible = true }
    @objc func siteSearchSettings() { primaryForActive().presentedPanel = .siteSearch }
    @objc func linkRoutingSettings() { primaryForActive().presentedPanel = .links }
    @objc func websiteBoosts() {
        if let quick = activeQuick { quick.requestBoosts(); return }
        let web = activeStore?.presentedPanel == nil ? activeWebView : nil
        let store = primaryForActive()
        do { try store.requestBoostEditor(for: web) } catch { store.message = error.localizedDescription }
    }
    @objc func manageExtensions() {
        if let manager=ExtensionManagerWindowController.active {manager.surface();return}
        guard let store=activeStore,let window=activeBrowserWindow else {return}
        store.requestExtensionManager(from:window,profileID:activeQuick.flatMap{store.quickProfileID($0.pageID)})
    }
    @objc func customize() { primaryForActive().appearanceVisible = true }
    @objc func manageProfiles() {
        let owner = ensureNormalOwner()
        openPrimary(owner)
        guard let window = preferredPrimary(of: owner), let store = windows[window] else { return }
        store.commandVisible = false; store.onboardingVisible = false; store.profilesVisible = true
    }
    @objc func welcome() {
        let store = primaryForActive()
        if !store.isPrivate && store.savingEnabled { store.presentedPanel = nil; store.onboardingVisible = true }
    }
    @objc func checkUpdates() {
        let store = primaryForActive(); store.updatesVisible = true
        let channel = UpdateChannel(rawValue: store.preferences.updateChannel ?? "preview") ?? .preview
        Task { await updates.check(channel: channel) }
    }
}
