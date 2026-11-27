import AppKit
import BrowserCore
import CryptoKit

@main struct EaselDraftRecoveryChecks {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        setbuf(stdout, nil)
        var checks = 0, failures = 0
        func check(_ value: Bool, _ name: String) {
            checks += 1; print("\(value ? "PASS" : "FAIL"): \(name)")
            if !value { failures += 1 }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Alcove.DraftRecovery." + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256)
        let store = BrowserStore(dataRoot: root, keyProvider: { _ in key })
        defer { store.shutdown() }
        let tab = try store.createEasel()
        let board = store.easelContext(for: tab)!.easel
        let note = try EaselItem(frame: EaselFrame(x: 50, y: 50, width: 300, height: 200), content: .note(text: "Original"))
        _ = try store.editEasel(in: tab, expectedRevision: board.revision, edits: [.insert(note)])
        let drafts = store.easelDrafts
        let draftKey = EaselDraftKey(profileID: BrowserProfile.defaultID, easelID: board.id, tabID: tab, itemID: note.id)
        try drafts.update("Full unsaved text", tabID: tab, itemID: note.id, from: store)
        let context = store.easelContext(for: tab)!
        let replacement = try EaselItem(id: note.id, frame: note.frame, content: .note(text: "Saved by another editor"))
        _ = try store.commitEaselEdits(in: tab, expectedRevision: context.easel.revision, edits: [.replace(replacement)])
        do { try drafts.flushAll() } catch { }
        let old = drafts.state(for: draftKey)!
        check(drafts.failures(in: store).first?.text == "Full unsaved text", "Recovery presents the complete failed note draft")
        try drafts.update("Newer unsaved text", tabID: tab, itemID: note.id, from: store)
        check(!drafts.discard(old) && drafts.state(for: draftKey)?.text == "Newer unsaved text", "A stale discard confirmation cannot erase newer typing")
        do { _ = try drafts.saveAsNewNote(old); check(false, "A stale recovery action cannot save or remove a newer draft") }
        catch { check(drafts.state(for: draftKey)?.text == "Newer unsaved text", "A stale recovery action cannot save or remove a newer draft") }
        let current = drafts.state(for: draftKey)!
        check(!drafts.retry(current) && drafts.state(for: draftKey)?.text == "Newer unsaved text", "Retrying a text conflict retains the draft and the saved note")
        let newID = try drafts.saveAsNewNote(current)
        let items = store.easelContext(for: tab)!.easel.items
        check(items.contains(where: { $0.id == newID && $0.content == .note(text: "Newer unsaved text") }) && items.contains(where: { $0.id == note.id && $0.content == .note(text: "Saved by another editor") }) && drafts.failures(in: store).isEmpty, "Save as New Note resolves recovery without overwriting the other editor")
        try drafts.update("Explicitly discarded", tabID: tab, itemID: note.id, from: store)
        let discard = drafts.state(for: draftKey)!
        check(drafts.discard(discard) && drafts.state(for: draftKey) == nil && store.easelContext(for: tab)?.easel.items.first?.content == .note(text: "Saved by another editor"), "An explicit current discard preserves saved content")
        try drafts.update("Do not archive this conflict", tabID: tab, itemID: note.id, from: store)
        let conflict = try EaselItem(id: note.id, frame: note.frame, content: .note(text: "Another saved update"))
        _ = try store.commitEaselEdits(in: tab, expectedRevision: store.easelContext(for: tab)!.easel.revision, edits: [.replace(conflict)])
        store.update(tab) { $0.pinned = false; $0.homeURL = nil; $0.pinnedTitle = nil; $0.lastAccessed = Date(timeIntervalSinceNow: -3 * 86400) }
        _ = store.newTab()
        store.preferences.archiveAfterDays = 1
        store.archiveOldTabs()
        check(store.tab(tab) != nil && drafts.state(for: draftKey)?.text == "Do not archive this conflict", "Automatic tab cleanup keeps a canvas with an unsaved conflicting note open")
        drafts.discard(draftKey)
        print("Easel draft recovery checks: \(checks) checked, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
