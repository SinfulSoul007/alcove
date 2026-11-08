import AppKit
import SwiftUI
import BrowserCore

struct SidebarResizeHandle: NSViewRepresentable {
    let onBegin: () -> Void
    let onDrag: (Double) -> Void
    let onEnd: () -> Void
    let onCancel: () -> Void
    let onReset: () -> Void
    final class Handle: NSView {
        var begin: () -> Void = {}
        var drag: (Double) -> Void = { _ in }
        var end: () -> Void = {}
        var cancel: () -> Void = {}
        var reset: () -> Void = {}
        private var origin = 0.0
        private var dragging = false
        private var observations: [NSObjectProtocol] = []
        override var acceptsFirstResponder: Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
        override func mouseDown(with event: NSEvent) {
            guard event.windowNumber == window?.windowNumber else { return }
            cancelResize()
            window?.makeFirstResponder(self)
            if event.clickCount >= 2 { reset(); return }
            origin = event.locationInWindow.x; dragging = true; begin()
        }
        override func mouseDragged(with event: NSEvent) {
            if dragging, event.windowNumber == window?.windowNumber { drag(event.locationInWindow.x - origin) }
        }
        override func mouseUp(with event: NSEvent) {
            guard dragging, event.windowNumber == window?.windowNumber else { return }; dragging = false; end()
        }
        @discardableResult func cancelResize() -> Bool {
            guard dragging else { return false }; dragging = false; cancel(); return true
        }
        override func keyDown(with event: NSEvent) {
            guard event.windowNumber == window?.windowNumber else { return }
            if event.keyCode == 53, cancelResize() { return }
            if event.keyCode == 123 || event.keyCode == 124 {
                guard !dragging else { return }
                begin(); drag(event.keyCode == 123 ? -12 : 12); end()
            }
            else { super.keyDown(with: event) }
        }
        override func resignFirstResponder() -> Bool {
            let resigned = super.resignFirstResponder()
            if resigned { cancelResize() }
            return resigned
        }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if window !== newWindow { cancelResize() }
            observations.forEach(NotificationCenter.default.removeObserver); observations.removeAll()
            super.viewWillMove(toWindow: newWindow)
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
                observations.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] notification in
                    MainActor.assumeIsolated {
                        guard let self, let sender = notification.object as? NSWindow, self.window === sender else { return }
                        self.cancelResize()
                    }
                })
            }
        }
        deinit { observations.forEach(NotificationCenter.default.removeObserver) }
    }
    func makeNSView(context: Context) -> Handle {
        let view = Handle(); view.setAccessibilityLabel("Resize sidebar. Double-click to reset."); view.setAccessibilityRole(.splitter)
        updateNSView(view, context: context); return view
    }
    func updateNSView(_ view: Handle, context: Context) { view.begin = onBegin; view.drag = onDrag; view.end = onEnd; view.cancel = onCancel; view.reset = onReset }
    static func dismantleNSView(_ view: Handle, coordinator: ()) { view.cancelResize() }
    @MainActor static func cancelActiveResize(in window: NSWindow?) -> Bool {
        (window?.firstResponder as? Handle)?.cancelResize() ?? false
    }
}
