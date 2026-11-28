import AppKit
import BrowserCore
import CryptoKit

@main struct EaselDrawingInteractionChecks {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited); setbuf(stdout, nil)
        var checked = 0, failed = 0
        func check(_ ok: Bool, _ name: String) { checked += 1; if !ok { failed += 1 }; print("\(ok ? "PASS" : "FAIL"): \(name)") }
        let store = BrowserStore(isPrivate: true); defer { store.shutdown() }
        let tab = try store.createEasel(title: "Owned interaction canvas")
        let note = try EaselItem(frame: EaselFrame(x: 80, y: 80, width: 320, height: 220), content: .note(text: "Keep this editor"))
        _ = try store.editEasel(in: tab, expectedRevision: store.easelContext(for: tab)!.easel.revision, edits: [.insert(note)])
        let canvas = EaselCanvasView(store: store, tabID: tab)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = canvas; canvas.layoutSubtreeIfNeeded()
        defer { window.contentView = nil; window.close() }
        let card = canvas.cards[note.id]!, text = card.noteView!
        window.makeFirstResponder(text)
        text.insertText(" input", replacementRange: NSRange(location: (text.string as NSString).length, length: 0))
        check(canvas.setDrawingTool(.pen), "Choosing a drawing tool can finish a current note safely")
        check(store.easelContext(for: tab)!.easel.items.first?.content == .note(text: "Keep this editor input"), "Tool selection saves complete note input before drawing")
        let before = store.easelContext(for: tab)!.easel
        check(canvas.drawing.begin(at: NSPoint(x: 140, y: 170)), "A current canvas starts a pen mark above existing cards")
        canvas.drawing.append(NSPoint(x: 180, y: 200)); canvas.drawing.append(NSPoint(x: 220, y: 240))
        check(canvas.drawing.preview != nil && store.easelContext(for: tab)!.easel == before, "Continuous previews never persist intermediate revisions")
        check(canvas.cards[note.id] === card && card.noteView === text, "Sampling keeps the existing native note editor mounted")
        check(canvas.drawing.finish(), "Releasing a pen gesture commits its complete mark")
        let drawn = store.easelContext(for: tab)!.easel
        check(drawn.items.count == 2 && drawn.revision != before.revision, "A completed gesture creates one drawing item")
        canvas.undoManager?.undo()
        check(store.easelContext(for: tab)!.easel.items == before.items, "One native Undo removes the whole gesture")
        canvas.undoManager?.redo()
        check(store.easelContext(for: tab)!.easel.items == drawn.items, "One native Redo restores all sampled ink")
        _ = canvas.drawing.begin(at: NSPoint(x: 400, y: 300)); canvas.drawing.cancel()
        check(!canvas.drawing.isDrawing && store.easelContext(for: tab)!.easel.items == drawn.items, "Cancel leaves the saved canvas untouched")
        _ = canvas.drawing.begin(at: NSPoint(x: 400, y: 300))
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        canvas.canvas.keyDown(with: escape)
        check(!canvas.drawing.isDrawing && store.easelContext(for: tab)!.easel.items == drawn.items, "Canvas Escape cancels an in-flight mark")
        _ = canvas.setDrawingTool(.pen); _ = canvas.drawing.begin(at: NSPoint(x: 400, y: 300))
        window.makeFirstResponder(text)
        check(!canvas.drawing.isDrawing, "Leaving canvas focus cancels an incomplete gesture")
        let penKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9)!
        canvas.canvas.keyDown(with: penKey)
        check(canvas.drawingTool == .pen, "Canvas tool shortcuts cannot hijack a note's responder")
        text.setMarkedText("字", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        canvas.canvas.keyDown(with: penKey)
        check(text.hasMarkedText() && canvas.drawingTool == .pen, "Marked note input remains outside canvas keyboard shortcuts")
        text.unmarkText(); try store.easelDrafts.flush(tabID: tab)
        _ = canvas.setDrawingTool(.line)
        canvas.setZoom(0.5)
        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            let location = canvas.drawingOverlay.convert(point, to: nil)
            return NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        let priorNative = store.easelContext(for: tab)!.easel.items.count
        canvas.drawingOverlay.mouseDown(with: event(.leftMouseDown, NSPoint(x: 120, y: 140)))
        canvas.drawingOverlay.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: 320, y: 240)))
        canvas.drawingOverlay.mouseUp(with: event(.leftMouseUp, NSPoint(x: 320, y: 240)))
        let nativeItem = store.easelContext(for: tab)!.easel.items.last!
        check(store.easelContext(for: tab)!.easel.items.count == priorNative + 1, "Real native drag events commit while the viewport is magnified")
        if case .drawing(let d) = nativeItem.content {
            check(abs(nativeItem.frame.x + d.points[0].x - 120) < 0.001 && abs(nativeItem.frame.y + d.points[1].y - 240) < 0.001, "Native event conversion keeps board coordinates at half zoom")
        } else { check(false, "Native events produce typed drawing content") }
        check(canvas.drawingOverlay.hitTest(NSPoint(x: 100, y: 100)) === canvas.drawingOverlay, "Drawing mode intercepts input above existing cards")
        _ = canvas.setDrawingTool(.select)
        check(canvas.drawingOverlay.hitTest(NSPoint(x: 100, y: 100)) == nil, "Select mode restores click-through to the note editor")
        _ = canvas.setDrawingTool(.pen)
        _ = canvas.drawing.begin(at: NSPoint(x: 500, y: 400)); canvas.drawing.append(NSPoint(x: 550, y: 450))
        let current = store.easelContext(for: tab)!.easel
        _ = try store.editEasel(in: tab, expectedRevision: current.revision, edits: [.rename("Newer editor title")])
        check(!canvas.drawing.finish(), "A changed board cannot accept stale drawing publication")
        let retained = store.easelDrafts.failures(in: store)
        check(retained.count == 1 && retained[0].pendingDrawing != nil && store.easelContext(for: tab)!.easel.title == "Newer editor title", "A revision conflict retains the complete mark and the newer board")
        if let state = retained.first {
            let recovered = try store.easelDrafts.saveAsNewNote(state, from: store)
            check(store.easelContext(for: tab)!.easel.items.last?.id == recovered && store.easelDrafts.failures(in: store).isEmpty, "Explicit drawing recovery appends a new mark without replacing the newer board")
        }
        let retiredDrafts = store.easelDrafts
        _ = canvas.drawing.begin(at: NSPoint(x: 600, y: 400)); store.shutdown()
        check(!canvas.drawing.finish() && retiredDrafts.failures(in: store).isEmpty, "Retired ownership cancels an in-flight mark without resurrecting data")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Alcove.DrawingRecovery." + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256)
        let normal = BrowserStore(dataRoot: root, keyProvider: { _ in key }); defer { normal.shutdown() }
        let normalTab = try normal.createEasel(title: "Failed drawing recovery")
        normal.update(normalTab) { $0.pinned = false; $0.homeURL = nil; $0.pinnedTitle = nil }
        var normalCanvas: EaselCanvasView? = EaselCanvasView(store: normal, tabID: normalTab)
        _ = normalCanvas!.setDrawingTool(.pen)
        _ = normalCanvas!.drawing.begin(at: NSPoint(x: 200, y: 200))
        normalCanvas!.drawing.append(NSPoint(x: 250, y: 220))
        let expectedMark = normalCanvas!.drawing.preview!
        let old = normal.easelContext(for: normalTab)!.easel
        let backup = root.appendingPathComponent("prior-ciphertext")
        try FileManager.default.moveItem(at: normal.sessionURL, to: backup)
        try FileManager.default.createDirectory(at: normal.sessionURL, withIntermediateDirectories: false)
        check(!normalCanvas!.drawing.finish(), "A real metadata write failure is reported to the drawing editor")
        check(normal.easelContext(for: normalTab)!.easel == old && normal.easelDrafts.failures(in: normal).first?.pendingDrawing == expectedMark, "A failed save preserves previous data and the entire pending mark")
        normal.close(normalTab)
        check(normal.tab(normalTab) != nil, "Cmd-W cannot discard a completed mark whose save failed")
        let weakCanvases = NSHashTable<EaselCanvasView>.weakObjects()
        weakCanvases.add(normalCanvas!)
        normalCanvas = nil
        check(weakCanvases.allObjects.isEmpty && normal.easelDrafts.failures(in: normal).first?.pendingDrawing == expectedMark, "A failed completed mark survives destruction of its canvas view")
        try FileManager.default.removeItem(at: normal.sessionURL); try FileManager.default.moveItem(at: backup, to: normal.sessionURL)
        _ = normal.unlockLocalData()
        for _ in 0..<1000 { if !normal.unlocking { break }; try await Task.sleep(for: .milliseconds(10)) }
        if let state = normal.easelDrafts.failures(in: normal).first {
            check(normal.easelDrafts.retry(state, from: normal), "The retained drawing can retry after actual metadata recovery")
        } else { check(false, "The retained drawing remains available for retry") }
        check(normal.easelContext(for: normalTab)!.easel.items == [expectedMark], "Retry persists the same item identity, samples and style exactly once")
        let originalSpace = normal.space.id
        let scopedCanvas = EaselCanvasView(store: normal, tabID: normalTab)
        _ = scopedCanvas.setDrawingTool(.pen); _ = scopedCanvas.drawing.begin(at: NSPoint(x: 300, y: 300))
        _ = try normal.createProfile(name: "Other drawing profile")
        check(!scopedCanvas.drawing.finish() && normal.library.easels?.isEmpty != false && normal.easelDrafts.failures(in: normal).isEmpty, "Switching profiles cancels transient ink without copying it into another profile")
        check(!scopedCanvas.setDrawingTool(.arrow), "A stale toolbar cannot change a background profile's canvas")
        normal.selectSpace(originalSpace); scopedCanvas.reconcile()
        _ = scopedCanvas.setDrawingTool(.pen); _ = scopedCanvas.drawing.begin(at: NSPoint(x: 300, y: 300))
        let destinationProfile = normal.profiles.first { $0.id != BrowserProfile.defaultID }!.id
        try normal.assignProfile(destinationProfile, to: originalSpace)
        check(!scopedCanvas.drawing.finish() && normal.easelDrafts.failures(in: normal).isEmpty, "Reassigning a canvas tab to a different profile cannot publish its old gesture")
        let removedStore = BrowserStore(isPrivate: true); defer { removedStore.shutdown() }
        let removedTab = try removedStore.createEasel(title: "Deleted during a gesture")
        let removedCanvas = EaselCanvasView(store: removedStore, tabID: removedTab)
        _ = removedCanvas.setDrawingTool(.pen); _ = removedCanvas.drawing.begin(at: NSPoint(x: 200, y: 200))
        let removedBoard = removedStore.easelContext(for: removedTab)!.easel
        try removedStore.deleteLibraryEasel(removedBoard.id, profileID: BrowserProfile.defaultID)
        check(!removedCanvas.drawing.finish() && removedStore.easelDrafts.failures(in: removedStore).isEmpty, "Deleting the source board cancels incomplete ink without a recoverable stale record")
        print("Easel drawing interaction checks: \(checked) checked, \(failed) failed")
        if failed != 0 { exit(1) }
    }
}
