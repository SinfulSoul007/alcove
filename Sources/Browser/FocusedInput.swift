import AppKit
import SwiftUI

/// Native first-responder handling keeps browser shortcuts usable after a web page had focus.
struct FocusedInput: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var size: CGFloat = 20
    var selectAll = false
    var focusRequest = 0
    var onSubmit: () -> Void
    var onCancel: () -> Void
    var onMove: (Int) -> Void = { _ in }
    var onTab: () -> Bool = { false }
    var onEmptyDelete: () -> Bool = { false }
    final class Field: NSTextField {
        var focusOnAttach = true
        var selectAllOnAttach = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard focusOnAttach, window != nil else { return }
            focusOnAttach = false
            requestFocus(selectAll: selectAllOnAttach)
        }
        func requestFocus(selectAll: Bool) {
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self)
                if selectAll { self.selectText(nil) }
            }
        }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FocusedInput
        var lastFocusRequest: Int
        init(_ parent: FocusedInput) { self.parent = parent; lastFocusRequest = parent.focusRequest }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { parent.text = field.stringValue }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch NSStringFromSelector(selector) {
            case "insertNewline:": parent.onSubmit(); return true
            case "cancelOperation:": parent.onCancel(); return true
            case "moveDown:": parent.onMove(1); return true
            case "moveUp:": parent.onMove(-1); return true
            case "insertTab:":
                guard parent.onTab() else { return false }; sync(control, editor: textView); return true
            case "deleteBackward:":
                guard parent.text.isEmpty, parent.onEmptyDelete() else { return false }; sync(control, editor: textView); return true
            default: return false
            }
        }
        @MainActor private func sync(_ control: NSControl, editor: NSTextView) {
            (control as? NSTextField)?.stringValue = parent.text; editor.string = parent.text
            editor.setSelectedRange(NSRange(location: (parent.text as NSString).length, length: 0))
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> Field {
        let field = Field(string: text)
        field.placeholderString = placeholder; field.font = .systemFont(ofSize: size)
        field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.textColor = .labelColor; field.delegate = context.coordinator
        field.selectAllOnAttach = selectAll; field.setAccessibilityLabel(placeholder)
        return field
    }
    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        field.font = .systemFont(ofSize: size); field.placeholderString = placeholder; field.setAccessibilityLabel(placeholder)
        if field.stringValue != text { field.stringValue = text }
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest; field.requestFocus(selectAll: selectAll)
        }
    }
}
