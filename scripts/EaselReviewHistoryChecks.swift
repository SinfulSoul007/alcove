import AppKit
import BrowserCore

@main struct EaselReviewHistoryChecks {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited); setbuf(stdout, nil)
        var checks = 0, failures = 0
        func check(_ value: Bool, _ name: String) { checks += 1; print("\(value ? "PASS" : "FAIL"): \(name)"); if !value { failures += 1 } }
        let store = BrowserStore(isPrivate: true)
        defer { store.shutdown() }
        let tab = try store.createEasel(), canvas = EaselCanvasView(store: store, tabID: tab)
        let first = canvas.addLink(title: "First", url: "https://example.com/first")!
        let second = canvas.addLink(title: "Second", url: "https://example.com/second")!
        canvas.undoManager?.undo(); canvas.undoManager?.undo()
        check(store.easelContext(for: tab)!.easel.items.isEmpty, "Two successive native Undo actions restore the canvas before both edits")
        canvas.undoManager?.redo(); canvas.undoManager?.redo()
        check(store.easelContext(for: tab)!.easel.items.map(\.id) == [first, second], "Two successive native Redo actions restore both completed edits")
        _ = try store.editEasel(in: tab, expectedRevision: store.easelContext(for: tab)!.easel.revision, edits: [.rename("External work")])
        _ = canvas.addLink(title: "Third", url: "https://example.com/third")
        canvas.undoManager?.undo()
        let external = store.easelContext(for: tab)!.easel
        canvas.undoManager?.undo()
        check(store.easelContext(for: tab)!.easel == external && external.title == "External work" && external.items.count == 2, "An external edit invalidates older snapshots before a new local undo sequence")
        canvas.select(first); _ = canvas.deleteSelected()
        canvas.select(second, extending: true)
        check(canvas.selection == [second], "Removing a card also removes its identifier from the selection")
        check(canvas.deleteSelected() && store.easelContext(for: tab)!.easel.items.isEmpty, "Shift-select and delete still work after the previously selected card was removed")
        print("Easel review history checks: \(checks) checked, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
