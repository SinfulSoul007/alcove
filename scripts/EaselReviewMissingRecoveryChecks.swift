import AppKit
import BrowserCore
import CryptoKit

@main struct EaselReviewMissingRecoveryChecks {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited); setbuf(stdout, nil)
        var checks = 0, failures = 0
        func check(_ value: Bool, _ name: String) { checks += 1; print("\(value ? "PASS" : "FAIL"): \(name)"); if !value { failures += 1 } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Alcove.MissingRecovery." + UUID().uuidString)
        var stores: [BrowserStore] = []
        defer { stores.forEach { $0.shutdown() }; try? FileManager.default.removeItem(at: root) }
        func fixture() throws -> (BrowserStore, EaselDraftState) {
            let key = SymmetricKey(size: .bits256)
            let store = BrowserStore(dataRoot: root.appendingPathComponent(UUID().uuidString), keyProvider: { _ in key }); stores.append(store)
            let tab = try store.createEasel(), board = store.easelContext(for: tab)!.easel
            let note = try EaselItem(frame: EaselFrame(x: 80, y: 80, width: 320, height: 220), content: .note(text: "Saved"))
            _ = try store.editEasel(in: tab, expectedRevision: board.revision, edits: [.insert(note)])
            try store.easelDrafts.update("Complete retained draft 日本", tabID: tab, itemID: note.id, from: store)
            var document = store.makeDocument(), library = document.library(for: BrowserProfile.defaultID)
            library.easels = []; document.setLibrary(library, for: BrowserProfile.defaultID); try store.commitProfileDocument(document)
            do { try store.easelDrafts.flushAll() } catch {}
            return (store, store.easelDrafts.state(for: EaselDraftKey(profileID: BrowserProfile.defaultID, easelID: board.id, tabID: tab, itemID: note.id))!)
        }
        let (store, state) = try fixture()
        check(store.easelDrafts.failures(in: store).first?.text == state.text, "A missing original canvas still exposes its draft in the owning profile")
        let recovered = try? store.easelDrafts.saveAsNewNote(state, recoveredTitle: "Recovered 🌲")
        let replacement = store.library.easels?.first
        check(recovered != nil && replacement?.title == "Recovered 🌲" && replacement?.id != state.key.easelID && replacement?.items.first?.id == recovered && replacement?.items.first?.content == .note(text: state.text) && store.easelDrafts.state(for: state.key) == nil && store.space.tabs.contains { EaselRoute.parse($0.url)?.id == replacement?.id }, "Explicit missing-canvas recovery atomically creates a named canvas, complete note and native tab")
        let (failing, retained) = try fixture()
        try FileManager.default.removeItem(at: failing.sessionURL)
        try FileManager.default.createDirectory(at: failing.sessionURL, withIntermediateDirectories: false)
        let failed = try? failing.easelDrafts.saveAsNewNote(retained)
        check(failed == nil && failing.library.easels?.isEmpty == true && failing.easelDrafts.state(for: retained.key)?.text == retained.text, "A failed recovery save retains the whole draft and publishes no empty replacement canvas")
        print("Easel missing-canvas recovery checks: \(checks) checked, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
