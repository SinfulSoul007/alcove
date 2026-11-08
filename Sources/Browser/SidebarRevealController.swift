import AppKit
import SwiftUI
import BrowserCore

/// Pointer bookkeeping and timers are private; only a visibility change redraws SwiftUI.
@MainActor final class SidebarRevealController: ObservableObject {
    @Published private(set) var revealed = false
    private var state = SidebarHoverState()
    private var enabled: Bool
    private var edgeInside = false
    private var panelInside = false
    private var resizing = false
    private var menus = Set<ObjectIdentifier>()
    private var pending: Task<Void, Never>?
    private var scheduledToken: Int?
    private weak var window: NSWindow?
    private var hasWindow = false
    private var windowClosed = false
    private var observations: [NSObjectProtocol] = []
    private var sources = Set<ObjectIdentifier>()

    init(enabled: Bool = false) { self.enabled = enabled }

    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        if !value {
            cancelPending(); state.reset(); edgeInside = false; panelInside = false; resizing = false
            publish()
        } else { reconcile() }
    }
    private var receivesPointer: Bool { !windowClosed && (!hasWindow || window?.isKeyWindow == true) }
    func edgeEntered() { guard receivesPointer, !edgeInside else { return }; edgeInside = true; reconcile() }
    func edgeExited() { guard edgeInside else { return }; edgeInside = false; reconcile() }
    func panelEntered() { guard receivesPointer, revealed, !panelInside else { return }; panelInside = true; reconcile() }
    func panelExited() { guard panelInside else { return }; panelInside = false; reconcile() }
    func beginResize() { guard !resizing else { return }; resizing = true; reconcile() }
    func endResize() { guard resizing else { return }; resizing = false; reconcile() }
    func reset() {
        cancelPending(); state.reset(); edgeInside = false; panelInside = false; resizing = false; menus.removeAll()
        publish()
    }
    private func publish() { if revealed != state.revealed { revealed = state.revealed } }
    private func cancelPending() {
        pending?.cancel(); pending = nil; scheduledToken = nil; state.cancelPending()
    }
    private func reconcile() {
        cancelPending()
        guard enabled, !windowClosed, !hasWindow || window != nil else { state.reset(); publish(); return }
        guard !hasWindow || window?.isKeyWindow == true || !menus.isEmpty else { state.reset(); publish(); return }
        guard !resizing, menus.isEmpty else { return }
        if edgeInside && !revealed { schedule(reveal: true) }
        else if revealed && !edgeInside && !panelInside { schedule(reveal: false) }
    }
    private func schedule(reveal: Bool) {
        let token = state.schedule(); scheduledToken = token
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(reveal ? 90 : 240))
            guard !Task.isCancelled else { return }
            self?.complete(token, reveal: reveal)
        }
    }
    private func complete(_ token: Int, reveal: Bool) {
        guard scheduledToken == token else { return }
        scheduledToken = nil; pending = nil
        guard enabled, receivesPointer, !resizing, menus.isEmpty else { return }
        if reveal {
            guard edgeInside else { return }; state.completeReveal(token)
        } else {
            guard !edgeInside, !panelInside else { return }; state.completeHide(token)
        }
        publish()
    }

    func attach(to window: NSWindow) {
        guard self.window !== window else { return }
        observations.forEach(NotificationCenter.default.removeObserver); observations.removeAll()
        reset(); sources.removeAll(); self.window = window; hasWindow = true; windowClosed = false
        observe(NSWindow.didResignKeyNotification, object: window) { controller, _ in
            if controller.menus.isEmpty { controller.reset() } else { controller.cancelPending() }
        }
        observe(NSWindow.willCloseNotification, object: window) { controller, _ in
            controller.windowClosed = true; controller.reset()
        }
        observe(NSMenu.didBeginTrackingNotification, object: nil) { controller, notification in
            guard controller.window?.isKeyWindow == true, !controller.windowClosed,
                  let menu = notification.object as? NSMenu else { return }
            controller.menus.insert(ObjectIdentifier(menu)); controller.reconcile()
        }
        observe(NSMenu.didEndTrackingNotification, object: nil) { controller, notification in
            guard let menu = notification.object as? NSMenu,
                  controller.menus.remove(ObjectIdentifier(menu)) != nil else { return }
            controller.reconcile()
        }
    }
    func track(_ source: AnyObject, in window: NSWindow) {
        attach(to: window); sources.insert(ObjectIdentifier(source))
    }
    func owns(_ source: AnyObject, in window: NSWindow) -> Bool {
        !windowClosed && self.window === window && sources.contains(ObjectIdentifier(source))
    }
    func untrack(_ source: AnyObject, in window: NSWindow) {
        guard self.window === window, sources.remove(ObjectIdentifier(source)) != nil, sources.isEmpty else { return }
        reset(); observations.forEach(NotificationCenter.default.removeObserver); observations.removeAll()
        self.window = nil; windowClosed = true
    }
    private func observe(_ name: Notification.Name, object: AnyObject?, action: @escaping @MainActor (SidebarRevealController, Notification) -> Void) {
        observations.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] notification in
            // Native menu begin/end ordering is significant; .main delivers synchronously.
            MainActor.assumeIsolated { if let self { action(self, notification) } }
        })
    }
    deinit {
        pending?.cancel()
        observations.forEach(NotificationCenter.default.removeObserver)
    }
}
