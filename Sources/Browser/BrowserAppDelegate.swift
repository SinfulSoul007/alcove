import AppKit
import SwiftUI
import WebKit
import BrowserCore

struct QuickWindowKey: Hashable { let ownerID: UUID; let pageID: UUID }

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    var windows: [NSWindow: BrowserStore] = [:]
    var primaryOwners: [NSWindow: BrowserWindowOwner] = [:]
    var primaryLeases: [NSWindow: UUID] = [:]
    var owners: [UUID: BrowserWindowOwner] = [:]
    var normalOwner: BrowserWindowOwner?
    var quickWindows: [QuickWindowKey: QuickBrowseWindowController] = [:]
    let updates = UpdateController(installedTag: Bundle.main.object(forInfoDictionaryKey: "AlcoveReleaseTag") as? String ?? "unknown")
    var normalWindow: NSWindow?
    var escapeMonitor: Any?
    var paneFocusMonitor: Any?
    var updateTimer: Timer?
    var activeBrowserWindow: NSWindow? { NSApp.keyWindow?.sheetParent ?? NSApp.keyWindow ?? NSApp.mainWindow }
    var activeQuick: QuickBrowseWindowController? { quickWindows.values.first { $0.window === activeBrowserWindow } }
    var activeStore: BrowserStore? { activeQuick?.store ?? activeBrowserWindow.flatMap { windows[$0] } ?? normalOwner?.store }
    var activeWebView: WKWebView? {
        if let quick = activeQuick { return quick.activeWebView }
        guard let store = activeStore else { return nil }
        return store.primaryPeekView ?? store.currentView
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular); buildMenu()
        let owner = ensureNormalOwner()
        if owner.store.onboardingVisible || owner.store.allQuickPages.isEmpty { openPrimary(owner) }
        else { syncQuickWindows(owner); quickWindows.values.first(where: { $0.windowOwner === owner })?.surface() }
        NSApp.activate(ignoringOtherApps: true)
        updateTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkNormalWindowAutomatically() }
        }
        updateTimer?.tolerance = 60
        paneFocusMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let window = event.window, let store = self.windows[window],
                  store.primaryPeekView == nil, !store.commandVisible else { return event }
            for (id, web) in store.views where web.window === window {
                if web.convert(web.bounds, to: nil).contains(event.locationInWindow) { store.focusPane(id); break }
            }
            return event
        }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self else { return event }
            if SidebarResizeHandle.cancelActiveResize(in: event.window) { return nil }
            if let quick = self.activeQuick, event.window === quick.window,
               quick.state.findVisible || quick.state.isEditingAddress || quick.store.quickPeekView(quick.pageID) != nil {
                quick.escape(); return nil
            }
            guard let window = event.window, let store = self.windows[window],
                  store.presentedPanel != nil || store.primaryPeekView != nil || store.commandVisible || store.findVisible else { return event }
            self.closePeek(); return nil
        }
    }
    func makeOwner(_ store: BrowserStore) -> BrowserWindowOwner {
        let owner = BrowserWindowOwner(store: store) { [weak self, weak store] in
            guard let self, let store else { return }
            self.owners = self.owners.filter { $0.value.store !== store }
            if self.normalOwner?.store === store { self.normalOwner = nil }
        }
        owners[owner.id] = owner
        store.onboardingDidFinish = { [weak self, weak store] in if let store { self?.checkAutomaticallyIfNeeded(store) } }
        store.automaticUpdatesDidChange = { [weak self, weak store] in if let store { self?.checkAutomaticallyIfNeeded(store) } }
        store.quickPagesDidChange = { [weak self, weak owner] in if let owner { self?.syncQuickWindows(owner) } }
        store.quickPageRequested = { [weak self, weak owner] id in
            guard let self, let owner else { return }
            self.syncQuickWindows(owner); self.quickWindows[QuickWindowKey(ownerID: owner.id, pageID: id)]?.surface()
        }
        return owner
    }
    func ensureNormalOwner() -> BrowserWindowOwner {
        if let normalOwner, !normalOwner.isClosed { return normalOwner }
        let owner = makeOwner(BrowserStore()); normalOwner = owner
        // Restored records have no native media yet; expire them before mounting windows.
        owner.store.archiveInactiveQuickPages(); syncQuickWindows(owner)
        return owner
    }
    func syncQuickWindows(_ owner: BrowserWindowOwner) {
        guard !owner.isClosed else { return }
        let pages = owner.store.allQuickPages
        let ids = Set(pages.map(\.id))
        let removed = quickWindows.values.filter { $0.windowOwner === owner && !ids.contains($0.pageID) }
        for controller in removed { controller.modelDidRemovePage() }
        for page in pages {
            let key = QuickWindowKey(ownerID: owner.id, pageID: page.id)
            guard quickWindows[key] == nil else { continue }
            do {
                let controller = try QuickBrowseWindowController(owner: owner, pageID: page.id,
                    requestPrimary: { [weak self, weak owner] in if let owner { self?.openPrimary(owner) } },
                    requestProfiles: { [weak self] in self?.manageProfiles() },
                    didClose: { [weak self] in self?.quickWindows.removeValue(forKey: key) })
                quickWindows[key] = controller; controller.window?.orderFront(nil)
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
    func openPrimary(_ owner: BrowserWindowOwner) {
        guard !owner.isClosed else { return }
        if let window = primaryOwners.first(where: { $0.value === owner })?.key {
            if window.isMiniaturized { window.deminiaturize(nil) }; window.makeKeyAndOrderFront(nil); return
        }
        let store = owner.store
        guard let lease = try? owner.acquirePrimary() else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1260, height: 820), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = store.isPrivate ? "Alcove — Private" : "Alcove"; window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false; window.delegate = self; window.minSize = NSSize(width: 800, height: 540)
        let hosting = NSHostingView(rootView: BrowserUI(store: store).environmentObject(updates))
        hosting.safeAreaRegions = []; hosting.sizingOptions = [.minSize]; window.contentView = hosting
        windows[window] = store; primaryOwners[window] = owner; primaryLeases[window] = lease
        if !store.isPrivate { normalWindow = window }
        window.center(); window.makeKeyAndOrderFront(nil); checkAutomaticallyIfNeeded(store)
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
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let owner = primaryOwners.removeValue(forKey: window); let lease = primaryLeases.removeValue(forKey: window)
        let store = windows.removeValue(forKey: window); window.contentView = nil
        store?.closePrimaryWindowPages()
        if normalWindow === window { normalWindow = nil }
        if let lease { owner?.release(lease) }
    }
    func applicationWillTerminate(_ notification: Notification) {
        updateTimer?.invalidate()
        for owner in owners.values { owner.store.flush() }
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        if let paneFocusMonitor { NSEvent.removeMonitor(paneFocusMonitor) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func application(_ application: NSApplication, open urls: [URL]) {
        let owner = ensureNormalOwner()
        for url in urls where QuickBrowseRouting.host(for: url) != nil {
            do { if case .space = try owner.dispatchExternal(url) { openPrimary(owner) } }
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
        add(app, "Customize…", #selector(customize), ",", [.command, .shift])
        add(app, "Manage Profiles…", #selector(manageProfiles), "")
        add(app, "Check for Updates…", #selector(checkUpdates), "")
        add(app, "Welcome to Alcove…", #selector(welcome), "")
        app.addItem(.separator()); add(app, "Quit Alcove", #selector(quit), "q")
        let file = submenu("File")
        add(file, "Open Main Window", #selector(openMain), "n"); add(file, "New Quick Browse", #selector(newQuick), "n", [.command, .option])
        add(file, "New Tab", #selector(newTab), "t"); add(file, "New Private Window", #selector(privateWindow), "n", [.command, .shift])
        add(file, "New Space…", #selector(newSpace), "n", [.command, .control]); add(file, "Open Location…", #selector(location), "l")
        add(file, "Import Preview Session…", #selector(importSession), "")
        add(file, "Close Tab", #selector(closeTab), "w"); add(file, "Reopen Closed Tab", #selector(reopen), "t", [.command, .shift])
        let edit = submenu("Edit")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] { edit.addItem(NSMenuItem(title: title, action: Selector(action), keyEquivalent: key)) }
        add(edit, "Find in Page…", #selector(find), "f")
        let view = submenu("View")
        add(view, "Reload", #selector(reload), "r"); add(view, "Toggle Sidebar", #selector(sidebar), "s")
        add(view, "Toggle Split View", #selector(split), "d", [.command, .shift]); add(view, "Pin / Unpin Tab", #selector(pin), "p", [.command, .shift])
        add(view, "Close Peek", #selector(closePeek), "\u{1b}", [])
        add(view, "Next Tab", #selector(nextTab), "\t", .control); add(view, "Previous Tab", #selector(previousTab), "\t", [.control, .shift])
        add(view, "Next Space", #selector(nextSpace), "\u{f703}", [.command, .option]); add(view, "Previous Space", #selector(previousSpace), "\u{f702}", [.command, .option])
        add(view, "Zoom In", #selector(zoomIn), "="); add(view, "Zoom Out", #selector(zoomOut), "-"); add(view, "Actual Size", #selector(resetZoom), "0")
        let library = submenu("Library")
        add(library, "Show Library", #selector(showLibrary), "b", [.command, .shift]); add(library, "Bookmark This Page", #selector(bookmark), "d")
        let history = submenu("History")
        add(history, "Back", #selector(back), "["); add(history, "Forward", #selector(forward), "]")
        let window = submenu("Window"); NSApp.windowsMenu = window
        window.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        NSApp.mainMenu = main
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let general: Set<Selector> = [#selector(openMain), #selector(privateWindow), #selector(manageProfiles), #selector(quit), #selector(about), #selector(settings)]
        if let action = menuItem.action, general.contains(action) { return true }
        guard let store = activeStore else { return menuItem.action == #selector(newTab) || menuItem.action == #selector(newQuick) || menuItem.action == #selector(location) }
        let quick = activeQuick
        let profile = quick.flatMap { store.quickProfileID($0.pageID) } ?? store.activeProfileID
        let available = !store.profileUnavailable(profile)
        if quick != nil {
            switch menuItem.action {
            case #selector(sidebar), #selector(split), #selector(pin), #selector(reopen), #selector(nextTab), #selector(previousTab), #selector(nextSpace), #selector(previousSpace), #selector(newSpace), #selector(importSession): return false
            default: break
            }
        }
        switch menuItem.action {
        case #selector(newQuick), #selector(newSpace): return store.canModifyLocalMetadata && !store.profileDataOperationInProgress && available
        case #selector(pin), #selector(reopen): return store.canModifyLocalMetadata && available
        case #selector(bookmark): return !store.isPrivate && store.savingEnabled && available && activeWebView?.url != nil
        case #selector(importSession): return !store.isPrivate && store.savingEnabled && available
        case #selector(welcome): return !store.isPrivate && store.savingEnabled
        case #selector(back): return activeWebView?.canGoBack == true && available
        case #selector(forward): return activeWebView?.canGoForward == true && available
        case #selector(reload), #selector(find), #selector(zoomIn), #selector(zoomOut), #selector(resetZoom): return activeWebView != nil && available
        default: return true
        }
    }
    @objc func about() { NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Alcove", .applicationVersion: updates.installedTag + " · Unsigned Preview", .credits: NSAttributedString(string: "An independent, open-source WebKit browser for Mac. Not notarized by Apple.")]) }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func openMain() { openWindow(isPrivate: false) }
    @objc func newQuick() {
        if let quick = activeQuick { quick.newQuick(); return }
        let owner = activeBrowserWindow.flatMap { primaryOwners[$0] } ?? ensureNormalOwner()
        do { _ = try owner.store.openQuickPage() }
        catch { openPrimary(owner); owner.store.message = error.localizedDescription }
    }
    @objc func newTab() {
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
        guard activeQuick == nil, let store = activeStore else { return }
        let tabs = store.space.tabs
        guard let index = tabs.firstIndex(where: { $0.id == store.focusedID }), !tabs.isEmpty else { return }
        store.select(tabs[(index + delta + tabs.count) % tabs.count].id)
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
    @objc func location() {
        if let quick = activeQuick { quick.requestLocation(); return }
        if activeStore == nil { openMain() }
        guard let store = activeStore else { return }
        store.presentedPanel = nil; if store.onboardingVisible { store.finishOnboarding() }; store.showCommand()
    }
    @objc func closeTab() {
        if let quick = activeQuick { quick.window?.performClose(nil); return }
        guard let store = activeStore else { return }
        if store.presentedPanel != nil { store.presentedPanel = nil; return }; if let id = store.focusedID { store.close(id) }
    }
    @objc func reopen() { guard activeQuick == nil, let store = activeStore, store.canModifyLocalMetadata, !store.profileUnavailable(store.activeProfileID) else { return }; store.reopenClosed() }
    @objc func reload() { activeWebView?.reload() }
    @objc func sidebar() { if activeQuick == nil { activeStore?.sidebarVisible.toggle() } }
    @objc func split() { if activeQuick == nil { activeStore?.toggleSplit() } }
    @objc func pin() { if activeQuick == nil, let store = activeStore, store.canModifyLocalMetadata, !store.profileUnavailable(store.activeProfileID), let id = store.focusedID { store.togglePin(id) } }
    @objc func back() { activeWebView?.goBack() }
    @objc func forward() { activeWebView?.goForward() }
    @objc func find() { if let quick = activeQuick { quick.state.showFind() } else { activeStore?.findVisible = true } }
    func zoom(_ amount: Double) { if let web = activeWebView { web.pageZoom = min(3, max(0.5, web.pageZoom + amount)) } }
    @objc func zoomIn() { zoom(0.1) }
    @objc func zoomOut() { zoom(-0.1) }
    @objc func resetZoom() { activeWebView?.pageZoom = 1 }
    func primaryForActive() -> BrowserStore {
        let owner = activeQuick?.windowOwner ?? activeBrowserWindow.flatMap { primaryOwners[$0] } ?? ensureNormalOwner()
        openPrimary(owner); return owner.store
    }
    @objc func showLibrary() {
        let profile = activeQuick.flatMap { $0.store.quickProfileID($0.pageID) }
        let store = primaryForActive()
        do { if let profile { try store.focusProfileSpace(profile) }; store.libraryVisible = true }
        catch { store.message = error.localizedDescription }
    }
    @objc func bookmark() {
        guard let store = activeStore, let web = activeWebView else { return }
        do { try store.bookmarkWebsite(web) } catch { store.message = error.localizedDescription }
    }
    @objc func settings() { primaryForActive().settingsVisible = true }
    @objc func customize() { primaryForActive().appearanceVisible = true }
    @objc func manageProfiles() {
        openWindow(isPrivate: false)
        guard let store = normalOwner?.store else { return }
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
