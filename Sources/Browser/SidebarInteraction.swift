import AppKit
import SwiftUI
import BrowserCore

struct SidebarResizeHandle: View {
    var interactionEnabled = true
    let width: Double
    let canInteract: () -> Bool
    let onBegin: () -> Void
    let onDrag: (Double) -> Void
    let onEnd: () -> Void
    let onCancel: () -> Void
    let onReset: () -> Void
    let onSetWidth: (Double) -> Void
    let onFocusChange: (Bool) -> Void
    private final class Connection: ObservableObject { weak var handle: Handle? }
    @StateObject private var connection = Connection()
    var body: some View {
        Native(enabled: interactionEnabled, width: width, canInteract: canInteract, onBegin: onBegin, onDrag: onDrag, onEnd: onEnd,
               onCancel: onCancel, onReset: onReset, onSetWidth: onSetWidth, onFocusChange: onFocusChange, connection: connection)
            .onChange(of: interactionEnabled, initial: true) { _, enabled in
                // Cancel outside updateNSView so state changes do not occur during rendering.
                if !enabled { connection.handle?.deactivate() }
            }
    }
    final class Handle: NSView {
        var begin: () -> Void = {}
        var drag: (Double) -> Void = { _ in }
        var end: () -> Void = {}
        var cancel: () -> Void = {}
        var reset: () -> Void = {}
        var width = 236.0
        var setWidth: (Double) -> Void = { _ in }
        var focusChanged: (Bool) -> Void = { _ in }
        var canInteract: () -> Bool = { true }
        var interactionEnabled = true {
            didSet { if oldValue != interactionEnabled { window?.invalidateCursorRects(for: self) } }
        }
        private var origin = 0.0
        private var originWidth = 236.0
        private var dragging = false
        private var closed = false
        private var keyboardFocused = false
        private var observations: [NSObjectProtocol] = []
        override init(frame: NSRect) {
            super.init(frame: frame); configureAccessibility()
        }
        required init?(coder: NSCoder) {
            super.init(coder: coder); configureAccessibility()
        }
        private func configureAccessibility() {
            setAccessibilityElement(true); setAccessibilityRole(.splitter)
            setAccessibilityLabel("Sidebar width"); setAccessibilityHelp("Use Left and Right to resize. Double-click or use Reset Sidebar Width to restore the default.")
            setAccessibilityOrientation(.vertical); focusRingType = .exterior
        }
        private var available: Bool { interactionEnabled && !closed && window != nil && !isHiddenOrHasHiddenAncestor && canInteract() }
        private var viewportWidth: Double { Double(window?.contentView?.bounds.width ?? 0) }
        private var currentWidth: Double { SidebarSizing.width(saved: width, windowWidth: viewportWidth) }
        override var acceptsFirstResponder: Bool { available }
        override func resetCursorRects() { if available { addCursorRect(bounds, cursor: .resizeLeftRight) } }
        override func accessibilityValue() -> Any? { currentWidth }
        override func accessibilityMinValue() -> Any? { 196.0 }
        override func accessibilityMaxValue() -> Any? { SidebarSizing.width(saved: 360, windowWidth: viewportWidth) }
        override func accessibilityValueDescription() -> String? { "\(Int(currentWidth.rounded())) points" }
        override func isAccessibilityEnabled() -> Bool { available }
        override func isAccessibilityFocused() -> Bool { available && keyboardFocused && window?.firstResponder === self }
        override func setAccessibilityFocused(_ focused: Bool) {
            if focused { if available { window?.makeFirstResponder(self) } }
            else if window?.firstResponder === self { window?.makeFirstResponder(nil) }
        }
        override func setAccessibilityValue(_ value: Any?) {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return }
            _ = commitWidth(number.doubleValue)
        }
        override func accessibilityPerformIncrement() -> Bool { commitWidth(currentWidth + 12) }
        override func accessibilityPerformDecrement() -> Bool { commitWidth(currentWidth - 12) }
        override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
            [NSAccessibilityCustomAction(name: "Reset Sidebar Width", handler: { [weak self] in self?.commitWidth(236) ?? false })]
        }
        @discardableResult private func commitWidth(_ value: Double) -> Bool {
            guard available, !dragging, value.isFinite else { return false }
            let clamped = SidebarSizing.width(saved: value, windowWidth: viewportWidth)
            // Keep consecutive AX/keyboard actions coherent before the next SwiftUI update.
            width = clamped; setWidth(clamped)
            NSAccessibility.post(element: self, notification: .valueChanged)
            return true
        }
        override var focusRingMaskBounds: NSRect { bounds }
        override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 2), xRadius: 2, yRadius: 2).fill() }
        private func reportFocus(_ focused: Bool) {
            guard keyboardFocused != focused else { return }
            keyboardFocused = focused; needsDisplay = true; noteFocusRingMaskChanged(); focusChanged(focused)
        }
        override func becomeFirstResponder() -> Bool {
            guard available, super.becomeFirstResponder() else { return false }
            reportFocus(true); return true
        }
        func deactivate() {
            cancelResize()
            if window?.firstResponder === self { window?.makeFirstResponder(nil) }
            reportFocus(false)
        }
        override func mouseDown(with event: NSEvent) {
            guard available, event.windowNumber == window?.windowNumber else { return }
            cancelResize()
            window?.makeFirstResponder(self)
            if event.clickCount >= 2 { width = SidebarSizing.width(saved: 236, windowWidth: viewportWidth); reset(); return }
            origin = event.locationInWindow.x; originWidth = currentWidth; dragging = true; begin()
        }
        override func mouseDragged(with event: NSEvent) {
            guard event.windowNumber == window?.windowNumber else { return }
            guard available else { deactivate(); return }
            if dragging {
                width = SidebarSizing.width(saved: originWidth + event.locationInWindow.x - origin, windowWidth: viewportWidth)
                drag(event.locationInWindow.x - origin)
            }
        }
        override func mouseUp(with event: NSEvent) {
            guard event.windowNumber == window?.windowNumber else { return }
            guard available else { deactivate(); return }
            guard dragging else { return }; dragging = false; end()
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
        @discardableResult func cancelResize() -> Bool {
            guard dragging else { return false }; dragging = false; width = originWidth; cancel(); return true
        }
        override func keyDown(with event: NSEvent) {
            guard event.windowNumber == window?.windowNumber else { return }
            if event.keyCode == 53, cancelResize() { return }
            guard available else { return }
            if event.keyCode == 123 || event.keyCode == 124 {
                guard !dragging else { return }
                commitWidth(currentWidth + (event.keyCode == 123 ? -12 : 12))
            }
            else { super.keyDown(with: event) }
        }
        override func resignFirstResponder() -> Bool {
            let resigned = super.resignFirstResponder()
            if resigned { cancelResize(); reportFocus(false) }
            return resigned
        }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if window !== newWindow { deactivate() }
            observations.forEach(NotificationCenter.default.removeObserver); observations.removeAll()
            super.viewWillMove(toWindow: newWindow)
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }; closed = false
            for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
                observations.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] notification in
                    MainActor.assumeIsolated {
                        guard let self, let sender = notification.object as? NSWindow, self.window === sender else { return }
                        if notification.name == NSWindow.willCloseNotification { self.closed = true }
                        self.deactivate()
                    }
                })
            }
        }
        deinit { observations.forEach(NotificationCenter.default.removeObserver) }
    }
    private struct Native: NSViewRepresentable {
        let enabled: Bool
        let width: Double
        let canInteract: () -> Bool
        let onBegin: () -> Void
        let onDrag: (Double) -> Void
        let onEnd: () -> Void
        let onCancel: () -> Void
        let onReset: () -> Void
        let onSetWidth: (Double) -> Void
        let onFocusChange: (Bool) -> Void
        let connection: Connection
        func makeCoordinator() -> Connection { connection }
        func makeNSView(context: Context) -> Handle {
            let view = Handle(); context.coordinator.handle = view
            updateNSView(view, context: context); return view
        }
        func updateNSView(_ view: Handle, context: Context) {
            view.begin = onBegin; view.drag = onDrag; view.end = onEnd; view.cancel = onCancel; view.reset = onReset
            view.width = width; view.setWidth = onSetWidth; view.focusChanged = onFocusChange; view.canInteract = canInteract
            view.interactionEnabled = enabled
        }
        static func dismantleNSView(_ view: Handle, coordinator: Connection) {
            view.deactivate()
            if coordinator.handle === view { coordinator.handle = nil }
        }
    }
    @MainActor static func cancelActiveResize(in window: NSWindow?) -> Bool {
        (window?.firstResponder as? Handle)?.cancelResize() ?? false
    }
}
