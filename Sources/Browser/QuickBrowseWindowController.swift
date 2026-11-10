import AppKit
import SwiftUI
import Combine
import WebKit
import BrowserCore

@MainActor final class QuickBrowseWindowController: NSWindowController, NSWindowDelegate {
    let windowOwner: BrowserWindowOwner
    let pageID: UUID
    let state = QuickBrowseWindowState()
    private let lease: UUID
    private let requestPrimary: () -> Void
    private let requestProfiles: () -> Void
    private let didClose: () -> Void
    private var activityMonitor: Any?
    private var changeSubscription: AnyCancellable?
    private var archivingUserClose = false
    private var released = false
    var store: BrowserStore { windowOwner.store }
    var activeWebView: WKWebView? { store.foregroundQuickView(pageID) }

    init(owner: BrowserWindowOwner, pageID: UUID, requestPrimary: @escaping () -> Void,
         requestProfiles: @escaping () -> Void, didClose: @escaping () -> Void) throws {
        self.windowOwner = owner; self.pageID = pageID; self.requestPrimary = requestPrimary
        self.requestProfiles = requestProfiles; self.didClose = didClose
        lease = try owner.acquireQuick(pageID)
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let size = NSSize(width: min(760, visible.width), height: min(600, visible.height))
        let frame = NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 480, height: 360)
        window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.animationBehavior = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || !owner.store.appearance.animationsEnabled ? .none : .documentWindow
        super.init(window: window)
        window.delegate = self
        let content = QuickBrowseUI(store: store, id: pageID, state: state,
            onPromoteSpace: { [weak self] in self?.promote(to: $0) },
            onPromotePeek: { [weak self] in self?.promotePeek() },
            onRequestProfile: { [weak self] in self?.chooseProfile($0, remember: $1) },
            onManageProfiles: requestProfiles,
            onOpenSettings: { [weak self] in self?.requestPrimary(); self?.store.settingsVisible = true },
            onClose: { [weak self] in self?.window?.performClose(nil) },
            onNewQuick: { [weak self] in self?.newQuick() },
            onOpenBoosts: { [weak self] in self?.requestBoosts() })
        let hosting = NSHostingView(rootView: content); hosting.safeAreaRegions = []; hosting.sizingOptions = []
        window.contentView = hosting; refreshTitle()
        changeSubscription = store.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.refreshTitle() }
        }
        activityMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            self.store.touchQuickPage(self.pageID)
            return event
        }
    }
    required init?(coder: NSCoder) { fatalError("Use init(owner:pageID:requestPrimary:requestProfiles:didClose:)") }
    func surface() {
        guard !released, store.quickPage(pageID) != nil, let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        showWindow(nil); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func refreshTitle() {
        guard let page = store.quickPage(pageID) else { return }
        window?.title = page.tab.title + (store.isPrivate ? " — Private Quick Browse" : " — Quick Browse")
    }
    func modelDidRemovePage() {
        guard !archivingUserClose, !released else { return }
        // The durable store transition already archived, promoted or cleared this page.
        window?.close()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !released, store.quickPage(pageID) != nil else { return true }
        archivingUserClose = true; defer { archivingUserClose = false }
        do { try store.closeQuickPage(pageID); return true }
        catch { state.navigationError = error.localizedDescription; return false }
    }
    func windowWillClose(_ notification: Notification) {
        guard !released else { return }
        released = true
        if let activityMonitor { NSEvent.removeMonitor(activityMonitor); self.activityMonitor = nil }
        changeSubscription?.cancel(); changeSubscription = nil
        if store.focusedQuickPageID == pageID { store.focusedQuickPageID = nil }
        window?.contentView = nil; window?.delegate = nil
        windowOwner.release(lease); didClose()
    }
    func windowDidBecomeKey(_ notification: Notification) {
        store.focusedQuickPageID = pageID; store.touchQuickPage(pageID); refreshMediaStatus()
    }
    func windowDidResignKey(_ notification: Notification) {
        if store.focusedQuickPageID == pageID { store.focusedQuickPageID = nil }
        store.touchQuickPage(pageID)
    }
    func requestLocation() { state.requestLocation(currentURL: activeWebView?.url?.absoluteString ?? store.quickPage(pageID)?.tab.url ?? "", context: store.searchInputContext(quickID: pageID)) }
    func newQuick() {
        guard let profile = store.quickProfileID(pageID) else { return }
        do { _ = try store.openQuickPage(profileID: profile) } catch { state.navigationError = error.localizedDescription }
    }
    func escape() {
        guard (window?.firstResponder as? NSTextInputClient)?.hasMarkedText() != true else { return }
        if store.boostPicker?.source.window === window { store.cancelBoostPicker() }
        else if state.findVisible { state.dismissFind() }
        else if state.isEditingAddress { state.cancelLocation(currentURL: store.quickPage(pageID)?.tab.url ?? "") }
        else if store.quickPeekView(pageID) != nil { store.closeQuickPeek(pageID) }
    }
    func requestBoosts() {
        do { try store.requestBoostEditor(for: activeWebView); requestPrimary() }
        catch { store.message = error.localizedDescription }
    }
    func refreshMediaStatus() {
        guard let web = activeWebView else { return }
        state.refreshMediaStatus(web: web) { [weak self] candidate in
            guard let self else { return false }; return self.activeWebView === candidate && self.store.quickPage(self.pageID) != nil
        }
    }
    func findNext(backwards: Bool = false) {
        state.findNext(web: activeWebView, backwards: backwards) { [weak self] candidate in
            guard let self else { return false }; return self.activeWebView === candidate && self.store.quickPage(self.pageID) != nil
        }
    }
    private func confirmReload(_ message: String, completion: @escaping () -> Void) {
        guard let window, window.attachedSheet == nil else { return }
        let alert = NSAlert(); alert.messageText = message
        alert.informativeText = "The destination profile has separate website logins. This page will reload, and unsaved forms cannot be transferred."
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Reload in Profile")
        alert.beginSheetModal(for: window) { result in
            guard result == .alertSecondButtonReturn else { return }; completion()
        }
    }
    func chooseProfile(_ profileID: UUID, remember: Bool) {
        guard let snapshot = store.quickActionSnapshot(pageID) else { return }
        let apply: () -> Void = { [weak self] in
            guard let self, self.store.matchesQuickAction(snapshot) else { return }
            do { try self.store.changeQuickProfile(self.pageID, to: profileID, rememberHost: remember, allowReload: true) }
            catch { self.state.navigationError = error.localizedDescription }
        }
        if snapshot.profileID == profileID { apply() }
        else { confirmReload("Use another profile for this page?", completion: apply) }
    }
    func promote(to destination: UUID? = nil) {
        guard let snapshot = store.quickActionSnapshot(pageID) else { return }
        let destinationProfile = destination.flatMap { id in store.session.spaces.first { $0.id == id }?.effectiveProfileID }
        let crossing = !store.isPrivate && destinationProfile != nil && destinationProfile != snapshot.profileID
        let apply: () -> Void = { [weak self] in
            guard let self, self.store.matchesQuickAction(snapshot),
                  destination == nil || self.store.session.spaces.contains(where: { $0.id == destination && $0.effectiveProfileID == destinationProfile }) else { return }
            // Establish the destination lease before the backend callback closes this window.
            self.requestPrimary()
            do { _ = try self.store.promoteQuickPage(self.pageID, to: destination, allowProfileChange: crossing) }
            catch { self.state.navigationError = error.localizedDescription; self.surface() }
        }
        if crossing { confirmReload("Move this page to another profile?", completion: apply) } else { apply() }
    }
    func promotePeek() {
        store.requestExpandPeek(in: .quick(pageID), onComplete: { [weak self] id in
            guard let self else { return }
            if self.store.quickProfileID(id) == nil { self.requestPrimary() }
        }, onError: { [weak self] error in self?.state.navigationError = error.localizedDescription })
    }
}
