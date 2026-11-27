import AppKit
import BrowserCore
import CryptoKit

@main struct EaselCanvasChecks {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        setbuf(stdout, nil)
        var checks = 0, failures = 0
        func check(_ value: Bool, _ name: String) {
            checks += 1; print("\(value ? "PASS" : "FAIL"): \(name)")
            if !value { failures += 1 }
        }
        let store = BrowserStore(isPrivate: true)
        defer { store.shutdown() }
        let tab = try store.createEasel(title: "Canvas checks")
        let board = store.easelContext(for: tab)!.easel
        let note = try EaselItem(frame: EaselFrame(x: 80, y: 80, width: 320, height: 220), content: .note(text: "Owned note"))
        let link = try EaselItem(frame: EaselFrame(x: 480, y: 120, width: 280, height: 140), content: .link(title: "Owned link", url: "https://example.com/owned"))
        _ = try store.editEasel(in: tab, expectedRevision: board.revision, edits: [.insert(note), .insert(link)])
        let canvas = EaselCanvasView(store: store, tabID: tab)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 650), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = canvas
        defer { window.contentView = nil; window.close() }
        canvas.reconcile()
        let first = canvas.cards[note.id]!
        let text = first.noteView!
        window.makeFirstResponder(text)
        text.setSelectedRange(NSRange(location: 3, length: 2))
        canvas.reconcile()
        check(canvas.cards[note.id] === first && first.noteView === text && window.firstResponder === text && text.selectedRange() == NSRange(location: 3, length: 2), "An ordinary canvas redraw preserves the native text view, focus and selection")
        text.insertText(" input", replacementRange: NSRange(location: (text.string as NSString).length, length: 0))
        let draftKey = EaselDraftKey(profileID: BrowserProfile.defaultID, easelID: board.id, tabID: tab, itemID: note.id)
        check(store.easelDrafts.state(for: draftKey)?.text == "Owned note input", "Real native text input immediately retains the complete draft")
        text.undoManager?.undo()
        check(text.string == "Owned note", "Native note Undo restores its previous text")
        text.undoManager?.redo()
        check(text.string == "Owned note input", "Native note Redo restores the complete input")
        let beforeOversize = text.string
        text.insertText(String(repeating: "😀", count: 4097), replacementRange: NSRange(location: 0, length: (text.string as NSString).length))
        check(text.string == beforeOversize, "Native paste rejects oversized Unicode input before replacing the note")
        text.setMarkedText(String(repeating: "字", count: 6000), selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: 0, length: (text.string as NSString).length))
        check(text.string == beforeOversize, "Oversized input-method composition preserves the previous complete text")
        try store.easelDrafts.flush(tabID: tab)
        text.insertText(" 2", replacementRange: NSRange(location: (text.string as NSString).length, length: 0))
        try store.easelDrafts.flush(tabID: tab)
        text.insertText(" 3", replacementRange: NSRange(location: (text.string as NSString).length, length: 0))
        var ownSaveContinues = true
        do { try store.easelDrafts.flush(tabID: tab) } catch { ownSaveContinues = false }
        check(ownSaveContinues && store.easelContext(for: tab)!.easel.items[0].content == .note(text: "Owned note input 2 3"), "Typing can continue after its own save before the next native redraw")
        let handle = first.subviews.first!
        let start = handle.convert(NSPoint(x: 8, y: 12), to: nil)
        func mouse(_ type: NSEvent.EventType, _ dx: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: start.x + dx, y: start.y), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        handle.mouseDown(with: mouse(.leftMouseDown, 0))
        handle.mouseDragged(with: mouse(.leftMouseDragged, 10))
        handle.mouseDragged(with: mouse(.leftMouseDragged, 20))
        handle.mouseUp(with: mouse(.leftMouseUp, 20))
        check(store.easelContext(for: tab)!.easel.items[0].frame.x == 100, "Successive native drag events use the fixed gesture origin")
        canvas.undoManager?.undo()
        canvas.select(note.id)
        let beforeDrag = store.easelContext(for: tab)!.easel
        check(canvas.beginGesture(itemID: note.id, resizing: false), "A current canvas can begin a geometry gesture")
        canvas.previewGesture(dx: -1000, dy: 20000)
        check(store.easelContext(for: tab)!.easel == beforeDrag, "Geometry previews do not write intermediate canvas revisions")
        check(canvas.endGesture(), "Completing a geometry gesture commits its final frame")
        let dragged = store.easelContext(for: tab)!.easel
        check(dragged.items[0].frame.x == 0 && dragged.items[0].frame.y == 16164, "Dragging clamps the complete card inside the canvas")
        canvas.undoManager?.undo()
        check(store.easelContext(for: tab)!.easel.items[0].frame == beforeDrag.items[0].frame, "Canvas undo restores the successful geometry edit")
        canvas.undoManager?.redo()
        check(store.easelContext(for: tab)!.easel.items[0].frame == dragged.items[0].frame, "Canvas redo restores the completed geometry gesture")
        _ = canvas.beginGesture(itemID: note.id, resizing: true)
        canvas.previewGesture(dx: -1000, dy: -1000)
        _ = canvas.endGesture()
        check(store.easelContext(for: tab)!.easel.items[0].frame.width == 40 && store.easelContext(for: tab)!.easel.items[0].frame.height == 40, "Resizing preserves a usable minimum card size")
        _ = canvas.beginGesture(itemID: note.id, resizing: false)
        canvas.previewGesture(dx: 100, dy: 0)
        let newer = store.easelContext(for: tab)!.easel
        _ = try store.editEasel(in: tab, expectedRevision: newer.revision, edits: [.rename("Other editor")])
        check(!canvas.endGesture() && store.easelContext(for: tab)!.easel.items[0].frame.x == 0, "A stale gesture cannot overwrite another editor's revision")
        canvas.select(note.id); _ = canvas.bringSelectedToFront()
        check(store.easelContext(for: tab)!.easel.items.last?.id == note.id, "Bring to Front updates actual persisted layer ordering")
        canvas.setZoom(99); check(canvas.magnification == 2, "Zoom clamps to the maximum readable magnification")
        canvas.setZoom(0); check(canvas.magnification == 0.25, "Zoom clamps to the minimum magnification")
        canvas.setZoom(.nan); check(canvas.magnification == 0.25, "Invalid zoom input leaves the viewport unchanged")
        canvas.setZoom(1)
        canvas.applyTheme(store.activeTheme, reduceMotion: true)
        canvas.reconcile()
        check(canvas.cards[note.id] === first && canvas.layer?.animationKeys()?.isEmpty != false, "Theme and reduced-motion updates retain card identity without decorative animation")
        window.makeFirstResponder(text)
        let delete = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51)!
        canvas.canvas.keyDown(with: delete)
        check(store.easelContext(for: tab)!.easel.items.count == 2, "Canvas delete routing cannot remove a card while its text editor is first responder")
        window.makeFirstResponder(canvas.canvas)
        canvas.canvas.keyDown(with: delete)
        check(store.easelContext(for: tab)!.easel.items.count == 1 && store.easelContext(for: tab)!.easel.items[0].id == link.id, "The focused canvas deletes only its selected card")
        canvas.undoManager?.undo()
        check(store.easelContext(for: tab)!.easel.items.contains(where: { $0.id == note.id }), "Deleting a card has a working native undo")
        let current = store.easelContext(for: tab)!.easel
        _ = try store.editEasel(in: tab, expectedRevision: current.revision, edits: [.rename("Keep newer canvas")])
        canvas.undoManager?.undo()
        check(store.easelContext(for: tab)!.easel.title == "Keep newer canvas", "A stale undo preserves newer canvas work")
        canvas.reconcile()
        let staleCard = canvas.cards[note.id]!
        let staleText = staleCard.noteView!
        let beforeExternal = store.easelContext(for: tab)!.easel
        let externalNote = try EaselItem(id: note.id, frame: beforeExternal.items.first(where: { $0.id == note.id })!.frame, content: .note(text: "New external note"))
        _ = try store.editEasel(in: tab, expectedRevision: beforeExternal.revision, edits: [.replace(externalNote)])
        staleText.insertText("Typing before redraw", replacementRange: NSRange(location: 0, length: (staleText.string as NSString).length))
        var rejectedStaleText = false
        do { try store.easelDrafts.flush(tabID: tab) } catch { rejectedStaleText = true }
        check(rejectedStaleText && store.easelContext(for: tab)!.easel.items.first(where: { $0.id == note.id })?.content == .note(text: "New external note") && store.easelDrafts.state(for: draftKey)?.text == "Typing before redraw", "Typing into a view awaiting redraw keeps both its draft and a newer saved note")
        store.easelDrafts.discard(draftKey)
        canvas.reconcile()
        let removedEditor = canvas.cards[note.id]!.noteView!
        _ = try store.editEasel(in: tab, expectedRevision: store.easelContext(for: tab)!.easel.revision, edits: [.remove([note.id])])
        removedEditor.insertText("Typed after removal", replacementRange: NSRange(location: 0, length: (removedEditor.string as NSString).length))
        check(store.easelDrafts.state(for: draftKey)?.text == "Typed after removal", "Input awaiting redraw after a note is removed remains a complete recoverable draft")
        if store.easelDrafts.state(for: draftKey) != nil {
            let replacementID = try store.easelDrafts.saveAsNewNote(draftKey)
            check(store.easelContext(for: tab)!.easel.items.contains(where: { $0.id == replacementID && $0.content == .note(text: "Typed after removal") }), "A removed note's retained draft can explicitly recover as a new note")
        } else { check(false, "A removed note's retained draft can explicitly recover as a new note") }
        let scopedRoot = FileManager.default.temporaryDirectory.appendingPathComponent("Alcove.CanvasScope." + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scopedRoot) }
        let scoped = BrowserStore(dataRoot: scopedRoot, keyProvider: { _ in SymmetricKey(data: Data(repeating: 8, count: 32)) })
        defer { scoped.shutdown() }
        let sourceSpace = scoped.space.id
        let scopedTab = try scoped.createEasel()
        _ = try scoped.editEasel(in: scopedTab, expectedRevision: scoped.easelContext(for: scopedTab)!.easel.revision, edits: [.insert(note)])
        let original = scoped.easelContext(for: scopedTab)!.easel
        let targetProfile = try scoped.createProfile(name: "Other canvas profile")
        var scopedDocument = scoped.makeDocument(), targetLibrary = scoped.library
        targetLibrary.easels = [original]; scopedDocument.setLibrary(targetLibrary, for: targetProfile)
        try scoped.commitProfileDocument(scopedDocument); scoped.selectSpace(sourceSpace)
        let scopedCanvas = EaselCanvasView(store: scoped, tabID: scopedTab)
        _ = scopedCanvas.beginGesture(itemID: note.id, resizing: false)
        scopedCanvas.previewGesture(dx: 20, dy: 0)
        let oldCard = scopedCanvas.cards[note.id]!
        let oldEditor = oldCard.noteView!
        try scoped.assignProfile(targetProfile, to: sourceSpace)
        check(!scopedCanvas.endGesture() && scoped.library(for: targetProfile).easels?.first == original, "A captured gesture cannot write into another profile with matching board identity and revision")
        oldEditor.insertText("Old profile callback", replacementRange: NSRange(location: 0, length: (oldEditor.string as NSString).length))
        try? scoped.easelDrafts.flushAll()
        check(scoped.library(for: targetProfile).easels?.first?.items.first?.content == .note(text: "Owned note"), "An editor callback from a retired profile cannot publish into the new profile")
        scopedCanvas.reconcile()
        check(scopedCanvas.cards[note.id] !== oldCard, "Matching card identities in another profile get fresh native editors")
        try scoped.assignProfile(BrowserProfile.defaultID, to: sourceSpace)
        scopedCanvas.undoManager?.removeAllActions(); scopedCanvas.reconcile(); scopedCanvas.select(note.id)
        _ = scopedCanvas.moveSelected(dx: 10, dy: 0)
        let movedInSource = scoped.easelContext(for: scopedTab)!.easel
        scopedDocument = scoped.makeDocument(); targetLibrary = scoped.library(for: targetProfile)
        targetLibrary.easels = [movedInSource]; scopedDocument.setLibrary(targetLibrary, for: targetProfile)
        try scoped.commitProfileDocument(scopedDocument); try scoped.assignProfile(targetProfile, to: sourceSpace)
        scopedCanvas.undoManager?.undo()
        check(scoped.library(for: targetProfile).easels?.first == movedInSource, "Undo stays bound to its original profile even when the destination has matching revisions")
        scopedCanvas.reconcile()
        let beforeKind = scopedCanvas.cards[note.id]!
        let kindBoard = scoped.easelContext(for: scopedTab)!.easel
        let changedKind = try EaselItem(id: note.id, frame: kindBoard.items[0].frame, content: .link(title: "A link now", url: "https://example.com/changed-kind"))
        _ = try scoped.editEasel(in: scopedTab, expectedRevision: kindBoard.revision, edits: [.replace(changedKind)])
        scopedCanvas.reconcile()
        check(scopedCanvas.cards[note.id] !== beforeKind && scopedCanvas.cards[note.id]?.noteView == nil, "Changing a card kind replaces its editor without retaining old note content")
        print("Easel canvas checks: \(checks) checked, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
