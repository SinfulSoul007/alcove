import AppKit
import SwiftUI
import BrowserCore

struct SidebarResizeHandle: View {
    var interactionEnabled = true
    let onBegin: () -> Void
    let onDrag: (Double) -> Void
    let onEnd: () -> Void
    let onCancel: () -> Void
    let onReset: () -> Void
    private final class Connection: ObservableObject { weak var handle: Handle? }
    @StateObject private var connection = Connection()
    var body: some View {
        Native(enabled: interactionEnabled, onBegin: onBegin, onDrag: onDrag, onEnd: onEnd,
               onCancel: onCancel, onReset: onReset, connection: connection)
            .onChange(of: interactionEnabled, initial: true) { _, enabled in
                // Cancel outside updateNSView so state changes do not occur during rendering.
                if !enabled { connection.handle?.cancelResize() }
            }
    }
    final class Handle: NSView {
        var begin: () -> Void = {}
        var drag: (Double) -> Void = { _ in }
        var end: () -> Void = {}
        var cancel: () -> Void = {}
        var reset: () -> Void = {}
        var interactionEnabled = true {
            didSet { if oldValue != interactionEnabled { window?.invalidateCursorRects(for: self) } }
        }
        private var origin = 0.0
        private var dragging = false
        private var observations: [NSObjectProtocol] = []
        override var acceptsFirstResponder: Bool { interactionEnabled }
        override func resetCursorRects() { if interactionEnabled { addCursorRect(bounds, cursor: .resizeLeftRight) } }
        override func mouseDown(with event: NSEvent) {
            guard interactionEnabled, event.windowNumber == window?.windowNumber else { return }
            cancelResize()
            window?.makeFirstResponder(self)
            if event.clickCount >= 2 { reset(); return }
            origin = event.locationInWindow.x; dragging = true; begin()
        }
        override func mouseDragged(with event: NSEvent) {
            guard event.windowNumber == window?.windowNumber else { return }
            guard interactionEnabled else { cancelResize(); return }
            if dragging { drag(event.locationInWindow.x - origin) }
        }
        override func mouseUp(with event: NSEvent) {
            guard event.windowNumber == window?.windowNumber else { return }
            guard interactionEnabled else { cancelResize(); return }
            guard dragging else { return }; dragging = false; end()
        }
        @discardableResult func cancelResize() -> Bool {
            guard dragging else { return false }; dragging = false; cancel(); return true
        }
        override func keyDown(with event: NSEvent) {
            guard event.windowNumber == window?.windowNumber else { return }
            if event.keyCode == 53, cancelResize() { return }
            guard interactionEnabled else { return }
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
    private struct Native: NSViewRepresentable {
        let enabled: Bool
        let onBegin: () -> Void
        let onDrag: (Double) -> Void
        let onEnd: () -> Void
        let onCancel: () -> Void
        let onReset: () -> Void
        let connection: Connection
        func makeCoordinator() -> Connection { connection }
        func makeNSView(context: Context) -> Handle {
            let view = Handle(); context.coordinator.handle = view
            view.setAccessibilityLabel("Resize sidebar. Double-click to reset."); view.setAccessibilityRole(.splitter)
            updateNSView(view, context: context); return view
        }
        func updateNSView(_ view: Handle, context: Context) {
            view.begin = onBegin; view.drag = onDrag; view.end = onEnd; view.cancel = onCancel; view.reset = onReset
            view.interactionEnabled = enabled
        }
        static func dismantleNSView(_ view: Handle, coordinator: Connection) {
            view.cancelResize()
            if coordinator.handle === view { coordinator.handle = nil }
        }
    }
    @MainActor static func cancelActiveResize(in window: NSWindow?) -> Bool {
        (window?.firstResponder as? Handle)?.cancelResize() ?? false
    }
}
