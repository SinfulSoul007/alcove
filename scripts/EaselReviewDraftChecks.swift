import AppKit
import BrowserCore
import CryptoKit

@MainActor private final class ReviewDraftWindow: NSWindow { override var isKeyWindow: Bool { true } }

@main struct EaselReviewDraftChecks {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited); setbuf(stdout, nil)
        var checks = 0, failures = 0
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Alcove.ReviewDraft." + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        var stores: [BrowserStore] = [], windows: [NSWindow] = []
        defer { windows.forEach { $0.contentView = nil; $0.close() }; stores.forEach { $0.shutdown() }; try? FileManager.default.removeItem(at: root) }
        func check(_ value: Bool, _ name: String) { checks += 1; print("\(value ? "PASS" : "FAIL"): \(name)"); if !value { failures += 1 } }
        func fixture(isPrivate: Bool = true) throws -> (store: BrowserStore, tab: UUID, note: EaselItem, canvas: EaselCanvasView, text: EaselNoteTextView) {
            let key = SymmetricKey(size: .bits256)
            let store = BrowserStore(isPrivate: isPrivate, dataRoot: root.appendingPathComponent(UUID().uuidString), keyProvider: { _ in key }); stores.append(store)
            store.onboardingVisible = false
            let tab = try store.createEasel()
            let note = try EaselItem(frame: EaselFrame(x: 80, y: 80, width: 320, height: 220), content: .note(text: "Saved before"))
            _ = try store.editEasel(in: tab, expectedRevision: store.easelContext(for: tab)!.easel.revision, edits: [.insert(note)])
            let canvas = EaselCanvasView(store: store, tabID: tab)
            let window = ReviewDraftWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = canvas; windows.append(window)
            let text = canvas.cards[note.id]!.noteView!; window.makeFirstResponder(text)
            return (store,tab,note,canvas,text)
        }
        let discarded = try fixture()
        discarded.text.insertText("Draft A", replacementRange: NSRange(location: 0, length: (discarded.text.string as NSString).length))
        let key = EaselDraftKey(profileID: BrowserProfile.defaultID, easelID: discarded.store.easelContext(for: discarded.tab)!.easel.id, tabID: discarded.tab, itemID: discarded.note.id)
        let durable = try EaselItem(id: discarded.note.id, frame: discarded.note.frame, content: .note(text: "Durable B"))
        _ = try discarded.store.commitEaselEdits(in: discarded.tab, expectedRevision: discarded.store.easelContext(for: discarded.tab)!.easel.revision, edits: [.replace(durable)])
        do { try discarded.store.easelDrafts.flushAll() } catch {}
        discarded.canvas.reconcile()
        let state = discarded.store.easelDrafts.state(for: key)!
        _ = discarded.store.easelDrafts.discard(state)
        check(discarded.text.string == "Durable B" && discarded.text.undoManager?.canUndo == false, "Explicit draft discard synchronously restores durable text and native undo state")
        discarded.text.insertText("!", replacementRange: NSRange(location: (discarded.text.string as NSString).length, length: 0))
        var saved = true
        do { try discarded.store.easelDrafts.flushAll() } catch { saved = false }
        check(saved && discarded.store.easelContext(for: discarded.tab)!.easel.items.first?.content == .note(text: "Durable B!"), "Typing immediately after discard cannot overwrite a newer note with the discarded text")
        let composing = try fixture()
        composing.text.insertText("x", replacementRange: NSRange(location: (composing.text.string as NSString).length, length: 0))
        composing.text.setSelectedRange(NSRange(location: (composing.text.string as NSString).length, length: 0))
        composing.text.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(for: .milliseconds(450))
        check(composing.text.hasMarkedText(), "Debounced autosave preserves an active valid input-method composition")
        composing.text.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        composing.text.unmarkText(); try composing.store.easelDrafts.flushAll()
        check(composing.store.easelContext(for: composing.tab)!.easel.items.first?.content == .note(text: "Saved beforex日本"), "A chosen replacement composition saves as one complete finalized note")
        let scoped = try fixture(isPrivate: false)
        let scopeKey = EaselDraftKey(profileID: BrowserProfile.defaultID, easelID: scoped.store.easelContext(for: scoped.tab)!.easel.id, tabID: scoped.tab, itemID: scoped.note.id)
        try scoped.store.easelDrafts.update("Profile A private draft", tabID: scoped.tab, itemID: scoped.note.id, from: scoped.store)
        let other = try EaselItem(id: scoped.note.id, frame: scoped.note.frame, content: .note(text: "Other saved version"))
        _ = try scoped.store.commitEaselEdits(in: scoped.tab, expectedRevision: scoped.store.easelContext(for: scoped.tab)!.easel.revision, edits: [.replace(other)])
        do { try scoped.store.easelDrafts.flushAll() } catch {}
        let beforeSwitch = scoped.store.easelDrafts.state(for: scopeKey)!, firstSpace = scoped.store.space.id
        _ = try scoped.store.createProfile(name: "Profile B")
        check(scoped.store.easelDrafts.failures(in: scoped.store).isEmpty, "Recovery in profile B never exposes profile A's failed note text")
        check(!scoped.store.easelDrafts.discard(beforeSwitch) && scoped.store.easelDrafts.state(for: scopeKey) != nil, "A recovery action from another active profile cannot discard the original draft")
        check(scoped.store.easelDrafts.recoveryState(beforeSwitch, from: scoped.store) == nil && !scoped.store.easelDrafts.retry(beforeSwitch, from: scoped.store), "A stale Copy or Retry control cannot read or act on another profile's draft")
        scoped.store.selectSpace(firstSpace)
        check(scoped.store.easelDrafts.failures(in: scoped.store).first?.text == "Profile A private draft", "Returning to the owning profile restores its complete recoverable draft")
        let sibling = try fixture(), first = sibling.store.space.id, boardID = sibling.store.easelContext(for: sibling.tab)!.easel.id
        let second = try sibling.store.createSpace(name: "Second editor", profileID: BrowserProfile.defaultID)
        let secondTab = try sibling.store.openEasel(boardID, in: second)
        try sibling.store.easelDrafts.update("Sibling note", tabID: secondTab, itemID: sibling.note.id, from: sibling.store)
        sibling.store.selectSpace(first); sibling.store.select(sibling.tab)
        _ = try sibling.store.easelImageDestination(for: sibling.tab)
        check(sibling.store.easelContext(for: sibling.tab)!.easel.items.first?.content == .note(text: "Sibling note"), "Board export/import preflight includes drafts in another tab for the same board")
        try sibling.store.easelDrafts.update("Conflicting sibling draft", tabID: secondTab, itemID: sibling.note.id, from: sibling.store)
        let latest = try EaselItem(id: sibling.note.id, frame: sibling.note.frame, content: .note(text: "New durable sibling version"))
        _ = try sibling.store.commitEaselEdits(in: sibling.tab, expectedRevision: sibling.store.easelContext(for: sibling.tab)!.easel.revision, edits: [.replace(latest)])
        sibling.canvas.reconcile(); sibling.canvas.select(sibling.note.id)
        let beforeMove = sibling.store.easelContext(for: sibling.tab)!.easel
        check(!sibling.canvas.moveSelected(dx: 20, dy: 0) && sibling.store.easelContext(for: sibling.tab)!.easel == beforeMove, "A board toolbar operation waits for a conflicting sibling draft to be resolved")
        let isolated = try fixture(isPrivate: false), origin = isolated.store.space.id
        let sharedID = isolated.store.easelContext(for: isolated.tab)!.easel.id
        let foreign = try isolated.store.createProfile(name: "Matching board identifiers")
        var document = isolated.store.makeDocument(), foreignLibrary = document.library(for: foreign)
        foreignLibrary.easels = [isolated.store.library(for: BrowserProfile.defaultID).easels!.first!]
        document.setLibrary(foreignLibrary, for: foreign); try isolated.store.commitProfileDocument(document)
        let foreignTab = try isolated.store.openEasel(sharedID)
        try isolated.store.easelDrafts.update("Only in the other profile", tabID: foreignTab, itemID: isolated.note.id, from: isolated.store)
        isolated.store.selectSpace(origin)
        _ = try isolated.store.easelImageDestination(for: isolated.tab)
        let foreignKey = EaselDraftKey(profileID: foreign, easelID: sharedID, tabID: foreignTab, itemID: isolated.note.id)
        check(isolated.store.library(for: foreign).easels?.first?.items.first?.content == .note(text: "Saved before") && isolated.store.easelDrafts.state(for: foreignKey)?.text == "Only in the other profile", "Board-wide preflight never flushes a matching canvas identifier in another profile")
        print("Easel review draft checks: \(checks) checked, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
