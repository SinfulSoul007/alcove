import SwiftUI
import BrowserCore

@MainActor
final class SidebarRevealController: ObservableObject {
    @Published private(set) var state = SidebarHoverState()
    private var pending: Task<Void, Never>?
    var revealed: Bool { state.revealed }
    func edgeEntered() {
        pending?.cancel()
        let token = state.schedule()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled else { return }; self?.state.completeReveal(token)
        }
    }
    func panelEntered() { pending?.cancel(); state.cancelPending() }
    func panelExited() {
        pending?.cancel()
        let token = state.schedule()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(240))
            guard !Task.isCancelled else { return }; self?.state.completeHide(token)
        }
    }
    func reset() { pending?.cancel(); state.reset() }
}

struct SidebarResizeHandle: NSViewRepresentable {
    let onBegin: () -> Void
    let onDrag: (Double) -> Void
    let onEnd: () -> Void
    let onReset: () -> Void
    final class Handle: NSView {
        var begin: () -> Void = {}
        var drag: (Double) -> Void = { _ in }
        var end: () -> Void = {}
        var reset: () -> Void = {}
        private var origin = 0.0
        override var acceptsFirstResponder: Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            if event.clickCount == 2 { reset(); return }
            origin = event.locationInWindow.x; begin()
        }
        override func mouseDragged(with event: NSEvent) { drag(event.locationInWindow.x - origin) }
        override func mouseUp(with event: NSEvent) { end() }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 123 || event.keyCode == 124 { begin(); drag(event.keyCode == 123 ? -12 : 12); end() }
            else { super.keyDown(with: event) }
        }
    }
    func makeNSView(context: Context) -> Handle {
        let view = Handle(); view.setAccessibilityLabel("Resize sidebar. Double-click to reset."); view.setAccessibilityRole(.splitter)
        updateNSView(view, context: context); return view
    }
    func updateNSView(_ view: Handle, context: Context) { view.begin = onBegin; view.drag = onDrag; view.end = onEnd; view.reset = onReset }
}
