import AppKit
import BrowserCore
import CryptoKit

@main struct EaselLibraryChecks {
    @MainActor static func main() throws {
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Alcove.EaselLibrary." + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256)
        let store = BrowserStore(dataRoot: root, keyProvider: { _ in key })
        defer { store.shutdown() }
        let sourceSpace = store.space.id
        let tab = try store.createEasel(title: "Saved canvas")
        let board = store.easelContext(for: tab)!.easel
        store.update(tab) { $0.pinned = false; $0.homeURL = nil; $0.pinnedTitle = nil }; store.close(tab)
        let count = store.session.spaces.flatMap(\.tabs).count
        try store.renameLibraryEasel(board.id, profileID: BrowserProfile.defaultID, title: "Renamed closed canvas")
        check(store.library.easels?.first?.title == "Renamed closed canvas" && store.session.spaces.flatMap(\.tabs).count == count, "Library renames a closed canvas without creating a tab")
        let otherProfile = try store.createProfile(name: "Other profile")
        var document = store.makeDocument(), library = store.library
        library.easels = [try Easel(id: board.id, title: "Separate matching identity")]
        document.setLibrary(library, for: otherProfile); try store.commitProfileDocument(document)
        rejects("A stale Library action cannot edit a profile that is no longer selected") { try store.renameLibraryEasel(board.id, profileID: BrowserProfile.defaultID, title: "Wrong profile") }
        store.selectSpace(sourceSpace)
        let reopened = try store.openEasel(board.id)
        let note = try EaselItem(frame: EaselFrame(x: 80, y: 80, width: 300, height: 220), content: .note(text: "Saved"))
        _ = try store.editEasel(in: reopened, expectedRevision: store.easelContext(for: reopened)!.easel.revision, edits: [.insert(note)])
        try store.easelDrafts.update("Kept before Library rename", tabID: reopened, itemID: note.id, from: store)
        try store.renameLibraryEasel(board.id, profileID: BrowserProfile.defaultID, title: "Renamed with draft")
        check(store.library.easels?.first?.items.first?.content == .note(text: "Kept before Library rename") && store.tab(reopened)?.title == "Renamed with draft", "Library rename flushes its note draft and refreshes the native pin title")
        try store.easelDrafts.update("Explicitly deleted with canvas", tabID: reopened, itemID: note.id, from: store)
        let draftKey = EaselDraftKey(profileID: BrowserProfile.defaultID, easelID: board.id, tabID: reopened, itemID: note.id)
        let backup = root.appendingPathComponent("saved-ciphertext")
        try FileManager.default.moveItem(at: store.sessionURL, to: backup)
        try FileManager.default.createDirectory(at: store.sessionURL, withIntermediateDirectories: false)
        rejects("A failed permanent deletion keeps the canvas") { try store.deleteLibraryEasel(board.id, profileID: BrowserProfile.defaultID) }
        check(store.library.easels?.contains(where: { $0.id == board.id }) == true && store.easelDrafts.state(for: draftKey)?.text == "Explicitly deleted with canvas", "A failed permanent deletion keeps the complete draft and model")
        try FileManager.default.removeItem(at: store.sessionURL); try FileManager.default.moveItem(at: backup, to: store.sessionURL)
        store.savingEnabled = true
        try store.deleteLibraryEasel(board.id, profileID: BrowserProfile.defaultID)
        check(store.library.easels?.contains(where: { $0.id == board.id }) != true && store.tab(reopened) == nil && store.easelDrafts.state(for: draftKey) == nil, "Confirmed permanent deletion retires the board, its native pin and its drafts atomically")
        check(store.library(for: otherProfile).easels?.first?.title == "Separate matching identity", "Deleting a canvas cannot remove another profile's matching identity")
        rejects("A stale editor cannot recreate a permanently deleted canvas") { try store.easelDrafts.update("Late editor", tabID: reopened, itemID: note.id, from: store) }
        let privateStore = BrowserStore(isPrivate: true, dataRoot: root.appendingPathComponent("private-must-not-exist"), keyProvider: { _ in fatalError("Private Library must not request a key") })
        defer { privateStore.shutdown() }
        let privateTab = try privateStore.createEasel()
        let privateBoard = privateStore.easelContext(for: privateTab)!.easel
        try privateStore.deleteLibraryEasel(privateBoard.id, profileID: BrowserProfile.defaultID)
        check(privateStore.library.easels?.isEmpty != false && !FileManager.default.fileExists(atPath: root.appendingPathComponent("private-must-not-exist").path), "Private Library deletion uses only private memory")
        privateStore.runCommand(.newEasel)
        check(privateStore.selectedID.flatMap { privateStore.easelContext(for: $0) } != nil, "The New Easel command creates a usable native private tab")
        print("Easel Library checks: \(checks) checked, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
