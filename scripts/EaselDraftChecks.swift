import AppKit
import BrowserCore
import CryptoKit

@MainActor private final class OwnedDraftFinisher: EaselDraftEditing {
    let finish: () -> Void
    init(_ finish: @escaping () -> Void) { self.finish = finish }
    func finishEaselDraftEditing() { finish() }
}

@main struct EaselDraftChecks {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        setbuf(stdout, nil)
        var checks = 0, failures = 0
        func check(_ value: Bool, _ name: String) {
            checks += 1; print("\(value ? "PASS" : "FAIL"): \(name)")
            if !value { failures += 1 }
        }
        func rejects(_ name: String, _ body: () throws -> Void) {
            do { try body(); check(false, name) } catch { check(true, name) }
        }
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("Alcove.Drafts." + UUID().uuidString)
        defer { try? files.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256)
        let store = BrowserStore(dataRoot: root, keyProvider: { _ in key })
        defer { store.shutdown() }
        let tab = try store.createEasel(title: "Draft test")
        let board = store.easelContext(for: tab)!.easel
        let frame = try EaselFrame(x: 80, y: 80, width: 320, height: 200)
        let note = try EaselItem(frame: frame, content: .note(text: "Original"))
        _ = try store.editEasel(in: tab, expectedRevision: board.revision, edits: [.insert(note)])
        let drafts = store.easelDrafts
        let draftKey = EaselDraftKey(profileID: BrowserProfile.defaultID, easelID: board.id, tabID: tab, itemID: note.id)
        try drafts.update("First input", tabID: tab, itemID: note.id, from: store)
        try drafts.update("Latest input", tabID: tab, itemID: note.id, from: store)
        check(store.easelContext(for: tab)?.easel.items.first?.content == .note(text: "Original") && drafts.state(for: draftKey)?.text == "Latest input", "Typing retains the latest draft immediately without synchronous metadata writes")
        for _ in 0..<300 {
            if store.easelContext(for: tab)?.easel.items.first?.content == .note(text: "Latest input") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        check(store.easelContext(for: tab)?.easel.items.first?.content == .note(text: "Latest input") && drafts.state(for: draftKey) == nil, "The debounce commits the latest text and releases its dirty draft")
        try drafts.update("Composing input", tabID: tab, itemID: note.id, from: store)
        let finisher = OwnedDraftFinisher {
            drafts.discard(draftKey)
            try? drafts.update("Final composed input", tabID: tab, itemID: note.id, from: store)
        }
        drafts.attach(finisher, for: draftKey)
        try drafts.flush(tabID: tab)
        check(store.easelContext(for: tab)?.easel.items.first?.content == .note(text: "Final composed input") && drafts.state(for: draftKey) == nil, "Finishing native text input cannot leave its final replacement draft unsaved")
        try drafts.update("Survives navigation", tabID: tab, itemID: note.id, from: store)
        _ = store.newTab()
        let retained = drafts.state(for: draftKey)?.text == "Survives navigation"
        let committed = store.library.easels?.first?.items.first?.content == .note(text: "Survives navigation")
        check(retained || committed, "Leaving the canvas cannot silently discard its text")
        try drafts.flush(tabID: tab)
        try drafts.update("Pending while moved", tabID: tab, itemID: note.id, from: store)
        var incoming = store.makeDocument(); var library = incoming.library(for: BrowserProfile.defaultID)
        var latest = library.easels!.first!
        let moved = try EaselItem(id: note.id, frame: EaselFrame(x: 600, y: 400, width: 320, height: 200), content: latest.items[0].content)
        try latest.apply(.replace(moved), expectedRevision: latest.revision)
        library.easels = [latest]; incoming.setLibrary(library, for: BrowserProfile.defaultID); try store.commitProfileDocument(incoming)
        try drafts.flush(tabID: tab)
        let rebased = store.easelContext(for: tab)!.easel
        check(rebased.items[0].frame.x == 600 && rebased.items[0].content == .note(text: "Pending while moved"), "A safe text rebase preserves another edit's latest geometry")
        try drafts.update("Keep my conflicting text", tabID: tab, itemID: note.id, from: store)
        incoming = store.makeDocument(); library = incoming.library(for: BrowserProfile.defaultID); latest = library.easels!.first!
        let otherText = try EaselItem(id: note.id, frame: latest.items[0].frame, content: .note(text: "Other editor"))
        try latest.apply(.replace(otherText), expectedRevision: latest.revision)
        library.easels = [latest]; incoming.setLibrary(library, for: BrowserProfile.defaultID); try store.commitProfileDocument(incoming)
        rejects("A stale text draft cannot overwrite the other editor") { try drafts.flush(tabID: tab) }
        check(drafts.state(for: draftKey)?.text == "Keep my conflicting text" && store.easelContext(for: tab)?.easel.items.first?.content == .note(text: "Other editor"), "Conflict handling keeps both the full draft and newer saved text")
        let recoveredID = try drafts.saveAsNewNote(draftKey)
        let recovered = store.easelContext(for: tab)!.easel
        check(recovered.items.contains(where: { $0.id == recoveredID && $0.content == .note(text: "Keep my conflicting text") }) && recovered.items.contains(where: { $0.id == note.id && $0.content == .note(text: "Other editor") }), "Explicit recovery saves a separate note and preserves the other editor's note")
        try drafts.update("Bounded draft", tabID: tab, itemID: note.id, from: store)
        rejects("An oversized replacement is rejected without truncating a retained draft") { try drafts.update(String(repeating: "😀", count: 4097), tabID: tab, itemID: note.id, from: store) }
        check(drafts.state(for: draftKey)?.text == "Bounded draft", "Rejected input leaves the prior draft complete")
        drafts.discard(draftKey)
        check(drafts.state(for: draftKey) == nil && store.easelContext(for: tab)?.easel.items.first?.content == .note(text: "Other editor"), "Explicit discard removes only the unsaved draft")

        store.update(tab) { $0.pinned = false; $0.homeURL = nil; $0.pinnedTitle = nil }
        try drafts.update("Keep this after failed save", tabID: tab, itemID: note.id, from: store)
        let backup = root.appendingPathComponent("previous-ciphertext")
        try files.moveItem(at: store.sessionURL, to: backup)
        try files.createDirectory(at: store.sessionURL, withIntermediateDirectories: false)
        rejects("A failed metadata write retains its note draft") { try drafts.flush(tabID: tab) }
        store.close(tab)
        check(store.tab(tab) != nil && drafts.state(for: draftKey)?.text == "Keep this after failed save", "Cmd-W cannot destroy a note whose save failed")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let delegate = AppDelegate(); delegate.windows[window] = store
        check(!delegate.windowShouldClose(window), "Window closure stays canceled while a note cannot save")
        check(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel, "Application quit stays canceled while a note cannot save")
        delegate.windows = [:]
        try files.removeItem(at: store.sessionURL); try files.moveItem(at: backup, to: store.sessionURL)
        check(store.unlockLocalData(), "A failed draft can retry through the already unlocked vault")
        for _ in 0..<500 {
            if !store.unlocking { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try drafts.flush(tabID: tab)
        check(store.easelContext(for: tab)?.easel.items.first?.content == .note(text: "Keep this after failed save"), "Retry persists the complete retained draft")
        store.close(tab)
        check(store.tab(tab) == nil && store.library.easels?.first?.items.first?.content == .note(text: "Keep this after failed save"), "Closing the saved tab keeps its canvas available in Library")

        let grouped = BrowserStore(dataRoot: root.appendingPathComponent("windows"), keyProvider: { _ in key })
        let owner = BrowserWindowOwner(store: grouped)
        let firstWindow = try owner.acquirePrimaryStore()
        let movingTab = try grouped.createEasel(title: "Moving draft")
        let movingBoard = grouped.easelContext(for: movingTab)!.easel
        _ = try grouped.editEasel(in: movingTab, expectedRevision: movingBoard.revision, edits: [.insert(note)])
        let movingDrafts = grouped.easelDrafts
        let movingKey = EaselDraftKey(profileID: BrowserProfile.defaultID, easelID: movingBoard.id, tabID: movingTab, itemID: note.id)
        try movingDrafts.update("Follows the window", tabID: movingTab, itemID: note.id, from: grouped)
        let secondWindow = try owner.acquirePrimaryStore(copying: grouped)
        let destination = secondWindow.store
        let transferFlushed = destination.flushEaselDrafts()
        check(transferFlushed && destination.easelContext(for: movingTab)?.easel.items.first?.content == .note(text: "Follows the window") && movingDrafts.state(for: movingKey) == nil, "Closing the new presenter flushes the draft after its tab moves between windows")
        rejects("The former window cannot edit the transferred note") { try movingDrafts.update("Late old window", tabID: movingTab, itemID: note.id, from: grouped) }
        let otherSpace = try destination.createSpace(name: "Second editor")
        let otherTab = try destination.openEasel(movingBoard.id, in: otherSpace)
        try movingDrafts.update("First editor text", tabID: movingTab, itemID: note.id, from: destination)
        try movingDrafts.update("Second editor text", tabID: otherTab, itemID: note.id, from: destination)
        try? movingDrafts.flush(tabID: movingTab)
        rejects("Two independent tab drafts cannot silently overwrite each other") { try movingDrafts.flush(tabID: otherTab) }
        let otherKey = EaselDraftKey(profileID: BrowserProfile.defaultID, easelID: movingBoard.id, tabID: otherTab, itemID: note.id)
        check(destination.easelContext(for: otherTab)?.easel.items.first?.content == .note(text: "First editor text") && movingDrafts.state(for: otherKey)?.text == "Second editor text", "Both editors keep their complete text when the second draft conflicts")
        movingDrafts.discard(movingKey); movingDrafts.discard(otherKey)
        owner.release(secondWindow.lease); owner.release(firstWindow.lease)

        let lifecycle = BrowserStore(dataRoot: root.appendingPathComponent("lifecycle"), keyProvider: { _ in key })
        defer { lifecycle.shutdown() }
        let sourceProfile = try lifecycle.createProfile(name: "Source profile")
        let sourceSpace = lifecycle.space.id
        let lifecycleTab = try lifecycle.createEasel()
        let lifecycleBoard = lifecycle.easelContext(for: lifecycleTab)!.easel
        _ = try lifecycle.editEasel(in: lifecycleTab, expectedRevision: lifecycleBoard.revision, edits: [.insert(note)])
        let lifecycleDrafts = lifecycle.easelDrafts
        let lifecycleKey = EaselDraftKey(profileID: sourceProfile, easelID: lifecycleBoard.id, tabID: lifecycleTab, itemID: note.id)
        try lifecycleDrafts.update("Before changing profile", tabID: lifecycleTab, itemID: note.id, from: lifecycle)
        try lifecycle.assignProfile(BrowserProfile.defaultID, to: sourceSpace)
        check(lifecycle.library(for: sourceProfile).easels?.first?.items.first?.content == .note(text: "Before changing profile") && lifecycleDrafts.state(for: lifecycleKey) == nil, "Changing a Space profile first saves its complete note in the original profile")
        try await lifecycle.deleteProfile(sourceProfile, removeStore: { _ in })
        check(!lifecycle.profiles.contains(where: { $0.id == sourceProfile }) && lifecycleDrafts.state(for: lifecycleKey) == nil, "Confirmed profile deletion retires its draft state")
        rejects("A stale editor cannot restore a deleted profile") { try lifecycleDrafts.update("Resurrect", tabID: lifecycleTab, itemID: note.id, from: lifecycle) }

        let archivedSpace = try lifecycle.createSpace(name: "Archive a Space")
        let archiveTab = try lifecycle.createEasel()
        let archiveBoard = lifecycle.easelContext(for: archiveTab)!.easel
        _ = try lifecycle.editEasel(in: archiveTab, expectedRevision: archiveBoard.revision, edits: [.insert(note)])
        try lifecycleDrafts.update("Before Space deletion", tabID: archiveTab, itemID: note.id, from: lifecycle)
        _ = try lifecycle.deleteSpace(archivedSpace)
        check(lifecycle.library.easels?.first(where: { $0.id == archiveBoard.id })?.items.first?.content == .note(text: "Before Space deletion"), "Deleting a Space saves its canvas drafts before removing their tabs")
        let moveTab = try lifecycle.createEasel()
        let moveBoard = lifecycle.easelContext(for: moveTab)!.easel
        _ = try lifecycle.editEasel(in: moveTab, expectedRevision: moveBoard.revision, edits: [.insert(note)])
        try lifecycleDrafts.update("Before moving profiles", tabID: moveTab, itemID: note.id, from: lifecycle)
        let targetProfile = try lifecycle.createProfile(name: "Move destination")
        let targetSpace = lifecycle.space.id
        check(lifecycle.placeTab(moveTab, in: targetSpace, section: .pinned, allowProfileChange: true), "A confirmed cross-profile tab move completes")
        check(lifecycle.library(for: BrowserProfile.defaultID).easels?.first(where: { $0.id == moveBoard.id })?.items.first?.content == .note(text: "Before moving profiles") && lifecycle.library(for: targetProfile).easels == nil, "A cross-profile move saves the draft in its original canvas without exposing it in the destination")

        let navigationStore = BrowserStore(dataRoot: root.appendingPathComponent("navigation"), keyProvider: { _ in key })
        defer { navigationStore.shutdown() }
        let navigationTab = try navigationStore.createEasel()
        let navigationBoard = navigationStore.easelContext(for: navigationTab)!.easel
        _ = try navigationStore.editEasel(in: navigationTab, expectedRevision: navigationBoard.revision, edits: [.insert(note)])
        try navigationStore.easelDrafts.update("Keep this conflicting draft", tabID: navigationTab, itemID: note.id, from: navigationStore)
        let changed = try EaselItem(id: note.id, frame: note.frame, content: .note(text: "New saved version"))
        _ = try navigationStore.commitEaselEdits(in: navigationTab, expectedRevision: navigationStore.easelContext(for: navigationTab)!.easel.revision, edits: [.replace(changed)])
        navigationStore.navigate("http://127.0.0.1:9/owned-unserved-test")
        check(navigationStore.tab(navigationTab)?.url == EaselRoute(id: navigationBoard.id).url.absoluteString && navigationStore.views[navigationTab] == nil, "Replacing a canvas tab with a website is canceled when its draft cannot save")

        let privateRoot = root.appendingPathComponent("private-must-not-exist")
        var privateKeys = 0
        let privateStore = BrowserStore(isPrivate: true, dataRoot: privateRoot, keyProvider: { _ in privateKeys += 1; return key })
        let privateTab = try privateStore.createEasel()
        let privateBoard = privateStore.easelContext(for: privateTab)!.easel
        _ = try privateStore.editEasel(in: privateTab, expectedRevision: privateBoard.revision, edits: [.insert(note)])
        let privateDrafts = privateStore.easelDrafts
        try privateDrafts.update("Private draft", tabID: privateTab, itemID: note.id, from: privateStore)
        try privateDrafts.flushAll()
        check(privateStore.easelContext(for: privateTab)?.easel.items.first?.content == .note(text: "Private draft") && privateKeys == 0 && !files.fileExists(atPath: privateRoot.path), "Private drafts save only to private memory without a key or files")
        try privateDrafts.update("Saved before website clearing", tabID: privateTab, itemID: note.id, from: privateStore)
        try await privateStore.clearProfileData(BrowserProfile.defaultID, removeData: { _ in })
        check(privateStore.library.easels?.first?.items.first?.content == .note(text: "Saved before website clearing"), "Clearing website data preserves the complete canvas draft in Library")
        rejects("A callback from a cleared tab cannot recreate its draft") { try privateDrafts.update("Late clear", tabID: privateTab, itemID: note.id, from: privateStore) }
        let reopened = try privateStore.openEasel(privateBoard.id)
        try await Task.sleep(for: .milliseconds(300))
        check(privateStore.easelContext(for: reopened)?.easel.items.first?.content == .note(text: "Saved before website clearing"), "Canceled draft timers cannot republish old text after website clearing")
        privateStore.shutdown()
        rejects("A late draft callback cannot republish into a closed private store") { try privateDrafts.update("Too late", tabID: privateTab, itemID: note.id, from: privateStore) }
        print("Easel draft checks: \(checks) checked, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
