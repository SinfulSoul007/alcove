import AppKit
import BrowserCore

extension EaselCanvasView {
    func requestRename() {
        guard let context, let store, store.canModifyLocalMetadata else { return }
        let alert = NSAlert(); alert.messageText = "Rename Easel"
        let name = NSTextField(string: context.easel.title); name.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        name.setAccessibilityLabel("Easel title"); alert.accessoryView = name
        alert.addButton(withTitle: "Rename"); alert.addButton(withTitle: "Cancel"); alert.window.initialFirstResponder = name
        guard alert.runModal() == .alertFirstButtonReturn, let current = self.context,
              current.profileID == context.profileID, current.easel.id == context.easel.id else { return }
        do {
            guard store.flushEaselDrafts(tabID: tabID), let board = self.context?.easel else { return }
            _ = try commit([.rename(name.stringValue)], expected: board.revision, name: "Rename Easel")
        } catch { store.message = error.localizedDescription }
    }
    func requestLink() {
        guard let context, store?.canModifyLocalMetadata == true else { return }
        let alert = NSAlert(); alert.messageText = "Add a link"
        let title = NSTextField(string: ""), address = NSTextField(string: "")
        title.placeholderString = "Title"; title.setAccessibilityLabel("Link title")
        address.placeholderString = "https://example.com"; address.setAccessibilityLabel("Link address")
        let fields = NSStackView(views: [title, address]); fields.orientation = .vertical; fields.spacing = 10
        fields.frame = NSRect(x: 0, y: 0, width: 340, height: 64); fields.alignment = .leading
        for field in [title, address] { field.widthAnchor.constraint(equalToConstant: 340).isActive = true }
        alert.accessoryView = fields; alert.addButton(withTitle: "Add Link"); alert.addButton(withTitle: "Cancel"); alert.window.initialFirstResponder = address
        guard alert.runModal() == .alertFirstButtonReturn, let current = self.context,
              current.profileID == context.profileID, current.easel.id == context.easel.id else { return }
        _ = addLink(title: title.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), url: address.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
