import AppKit
import SwiftUI
import BrowserCore

/// Tracking observes movement without participating in click or focus routing.
struct SidebarTracking: NSViewRepresentable {
    enum Region { case edge, panel }
    let controller: SidebarRevealController
    let region: Region
    let enabled: Bool

    final class Host: NSView {
        private let controller: SidebarRevealController
        private let region: Region
        private var enabled = false
        private var inside = false
        private var area: NSTrackingArea?
        private var observations: [NSObjectProtocol] = []

        init(controller: SidebarRevealController, region: Region) {
            self.controller = controller; self.region = region; super.init(frame: .zero)
            // Modern AppKit visibleRect can extend beyond bounds when clipping is off.
            clipsToBounds = true
        }
        required init?(coder: NSCoder) { fatalError("Use init(controller:region:)") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        func configure(enabled: Bool) {
            guard self.enabled != enabled else { return }
            self.enabled = enabled; updateTrackingAreas()
        }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            observations.forEach(NotificationCenter.default.removeObserver); observations.removeAll()
            send(inside: false)
            if let window, window !== newWindow { controller.untrack(self, in: window) }
            super.viewWillMove(toWindow: newWindow)
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                controller.track(self, in: window)
                for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                    observations.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.synchronizePointer() }
                    })
                }
            }
            updateTrackingAreas()
        }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area); self.area = nil }
            if enabled, window != nil {
                let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .enabledDuringMouseDrag], owner: self)
                addTrackingArea(area); self.area = area
            }
            synchronizePointer()
        }
        override func layout() { super.layout(); synchronizePointer() }
        private func synchronizePointer() {
            guard enabled, let window, window.isKeyWindow else { send(inside: false); return }
            send(inside: visibleRect.intersection(bounds).contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)))
        }
        private func send(inside: Bool) {
            guard self.inside != inside else { return }; self.inside = inside
            guard let window, controller.owns(self, in: window) else { return }
            switch (region, inside) {
            case (.edge, true): controller.edgeEntered()
            case (.edge, false): controller.edgeExited()
            case (.panel, true): controller.panelEntered()
            case (.panel, false): controller.panelExited()
            }
        }
        override func mouseEntered(with event: NSEvent) {
            guard enabled, let window, window.isKeyWindow, event.windowNumber == window.windowNumber else { return }
            synchronizePointer()
        }
        override func mouseExited(with event: NSEvent) {
            guard event.windowNumber == window?.windowNumber else { return }; synchronizePointer()
        }
        deinit { observations.forEach(NotificationCenter.default.removeObserver) }
    }
    func makeNSView(context: Context) -> Host {
        let view = Host(controller: controller, region: region); view.configure(enabled: enabled); return view
    }
    func updateNSView(_ view: Host, context: Context) { view.configure(enabled: enabled) }
}

struct SidebarSpaceSwipeRegion: ViewModifier {
    struct Spaces: Equatable {
        let current: UUID
        let previous: UUID?
        let next: UUID?
    }

    let spaces: Spaces
    let reveal: SidebarRevealController
    let enabled: Bool
    let motion: Animation?
    let select: (UUID) -> Void
    @State private var offset: Double = 0

    func body(content: Content) -> some View {
        let available = enabled && (spaces.previous != nil || spaces.next != nil)
        content
            .offset(x: available && motion != nil ? offset : 0)
            .clipped()
            .background(Reader(enabled: available, spaces: spaces, reveal: reveal) { update in
                switch update {
                case .passThrough:
                    break
                case .track(let travel):
                    let hasDestination = travel < 0 ? spaces.next != nil : spaces.previous != nil
                    offset = max(-30, min(30, travel * (hasDestination ? 0.23 : 0.08)))
                case .reset:
                    withAnimation(motion) { offset = 0 }
                case .switchSpace(let direction):
                    withAnimation(motion) { offset = 0 }
                    if let destination = direction == .next ? spaces.next : spaces.previous {
                        select(destination)
                    }
                }
            })
            .onChange(of: available) { _, _ in offset = 0 }
            .onChange(of: spaces) { _, _ in offset = 0 }
    }

    struct Reader: NSViewRepresentable {
        let enabled: Bool
        let spaces: Spaces
        let reveal: SidebarRevealController
        let onUpdate: (SidebarSpaceSwipe.Update) -> Void

        func makeNSView(context: Context) -> Host {
            let host = Host()
            updateNSView(host, context: context)
            return host
        }

        func updateNSView(_ host: Host, context: Context) {
            host.configure(enabled: enabled, spaces: spaces, reveal: reveal, onUpdate: onUpdate)
        }
    }

    final class Host: NSView {
        private var swipe = SidebarSpaceSwipe()
        private var enabled = false
        private var spaces: Spaces?
        private var monitor: Any?
        private var observations: [NSObjectProtocol] = []
        private weak var reveal: SidebarRevealController?
        private var onUpdate: ((SidebarSpaceSwipe.Update) -> Void)?
        private var consumesMomentum = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func configure(enabled: Bool, spaces: Spaces, reveal: SidebarRevealController,
                       onUpdate: @escaping (SidebarSpaceSwipe.Update) -> Void) {
            self.reveal = reveal
            self.onUpdate = onUpdate
            guard self.enabled != enabled || self.spaces != spaces else { return }
            swipe = SidebarSpaceSwipe()
            self.enabled = enabled
            self.spaces = spaces
            updateMonitor()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            stopMonitoring()
            swipe = SidebarSpaceSwipe()
            consumesMomentum = false
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateMonitor()
        }

        private func updateMonitor() {
            guard enabled, let window else {
                stopMonitoring()
                consumesMomentum = false
                return
            }
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return event }
                return self.route(event, in: event.window, at: event.locationInWindow)
            }
            observeInterruption(NSWindow.didResignKeyNotification, object: window)
            observeInterruption(NSMenu.didBeginTrackingNotification, object: nil)
        }

        private func observeInterruption(_ name: Notification.Name, object: AnyObject?) {
            let observer = NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancelSwipe() }
            }
            observations.append(observer)
        }

        private func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            observations.forEach(NotificationCenter.default.removeObserver)
            observations.removeAll()
        }

        private func cancelSwipe() {
            consumesMomentum = false
            if swipe.update(.cancelled) == .reset { onUpdate?(.reset) }
        }

        func route(_ event: NSEvent, in eventWindow: NSWindow?, at pointInWindow: NSPoint) -> NSEvent? {
            guard enabled, event.type == .scrollWheel, let window, eventWindow === window,
                  window.isKeyWindow else { return event }
            let modifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
            guard event.hasPreciseScrollingDeltas, event.modifierFlags.intersection(modifiers).isEmpty,
                  window.attachedSheet == nil, reveal?.hasTrackingMenu == false else {
                cancelSwipe()
                return event
            }
            if !event.momentumPhase.isEmpty {
                let consume = consumesMomentum
                if event.momentumPhase.contains(.ended) { consumesMomentum = false }
                return consume ? nil : event
            }
            let phase: SidebarSpaceSwipe.Phase
            switch event.phase {
            case .began:
                cancelSwipe()
                let point = convert(pointInWindow, from: nil)
                guard !isHiddenOrHasHiddenAncestor, bounds.intersection(visibleRect).contains(point) else { return event }
                phase = .began
            case .changed:
                phase = .changed
            case .ended:
                phase = .ended
            case .cancelled:
                phase = .cancelled
            default:
                return event
            }
            let update = swipe.update(phase, x: event.scrollingDeltaX, y: event.scrollingDeltaY)
            guard update != .passThrough else { return event }
            if phase == .ended { consumesMomentum = true }
            onUpdate?(update)
            return nil
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
            observations.forEach(NotificationCenter.default.removeObserver)
        }
    }
}
