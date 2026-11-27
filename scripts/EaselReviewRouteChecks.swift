import AppKit
import BrowserCore
import CryptoKit

@main struct EaselReviewRouteChecks {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited); setbuf(stdout, nil)
        var checks = 0, failures = 0
        func check(_ value: Bool, _ name: String) { checks += 1; print("\(value ? "PASS" : "FAIL"): \(name)"); if !value { failures += 1 } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Alcove.RouteReview." + UUID().uuidString)
        let key = SymmetricKey(size: .bits256)
        let store = BrowserStore(dataRoot: root.appendingPathComponent("archive"), keyProvider: { _ in key })
        defer { store.shutdown(); try? FileManager.default.removeItem(at: root) }
        let tab = try store.createEasel(), original = store.tab(tab)!
        let board = store.easelContext(for: tab)!.easel
        let note = try EaselItem(frame: EaselFrame(x: 80, y: 80, width: 320, height: 220), content: .note(text: "Saved"))
        _ = try store.editEasel(in: tab, expectedRevision: board.revision, edits: [.insert(note)])
        try store.easelDrafts.update("Unsaved", tabID: tab, itemID: note.id, from: store)
        check(store.pinnedAddressActions(for: tab) == .unavailable && store.pinnedAddressActions(forLocalTab: store.tab(tab)!, in: store.space.id) == .unavailable, "Native canvas pins do not offer website-only pinned address actions")
        let stale = BrowserStore.PinnedAddressEdit(tabID: tab, profile: BrowserProfile.defaultID, originalHome: original.homeURL, displayedAddress: original.url)
        var rejected = false
        do { try store.setPinnedAddress(stale, to: "https://example.com/replacement") } catch { rejected = true }
        check(rejected && store.tab(tab)?.url == original.url && store.easelDrafts.dirtyTabIDs.contains(tab), "A retained pinned URL editor cannot replace a native route or strand its draft")
        // Restore the owned fixture route if the baseline incorrectly replaced it.
        store.update(tab) { $0 = original }
        try store.easelDrafts.flushAll()
        store.update(tab) { $0.pinned = false; $0.homeURL = nil; $0.pinnedTitle = nil; $0.lastAccessed = Date(timeIntervalSinceNow: -3 * 86400) }
        _ = store.newTab(); store.preferences.archiveAfterDays = 1; store.archiveOldTabs()
        check(store.tab(tab) == nil && store.library.archive.contains { $0.id == tab }, "A clean old unpinned native canvas can be automatically archived")
        store.restoreArchived(tab)
        check(!store.library.archive.contains { $0.id == tab } && store.space.tabs.contains { EaselRoute.parse($0.url)?.id == board.id } && store.library.easels?.first?.items.first?.content == .note(text: "Unsaved"), "The Library Restore action reopens an archived native canvas with its saved content")
        let scoped = BrowserStore(dataRoot: root.appendingPathComponent("scope"), keyProvider: { _ in key })
        defer { scoped.shutdown() }
        let owned = try scoped.createEasel(), archived = scoped.tab(owned)!
        let other = try scoped.createProfile(name: "Other profile")
        var candidate = scoped.makeDocument(), library = candidate.library(for: other)
        library.archive = [archived]; candidate.setLibrary(library, for: other); try scoped.commitProfileDocument(candidate)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(scoped.makeDocument())
        var isolated = false
        do { _ = try scoped.restoreArchivedRouted(archived.id, profileID: other) } catch { isolated = true }
        let after = try encoder.encode(scoped.makeDocument())
        check(isolated && after == before, "An archived native route cannot resolve a matching board identifier in a different profile")
        print("Easel review route checks: \(checks) checked, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
