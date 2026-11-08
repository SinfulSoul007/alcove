import AppKit
import SwiftUI

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
