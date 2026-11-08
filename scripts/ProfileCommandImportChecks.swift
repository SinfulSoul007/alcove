import AppKit
import CryptoKit
import BrowserCore

@main struct ProfileCommandImportChecks {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        var failures = 0
        func check(_ value: Bool, _ name: String) { print("\(value ? "PASS" : "FAIL"): \(name)"); if !value { failures += 1 } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256)
        let store = BrowserStore(dataRoot: root, keyProvider: { _ in key })
        let id = store.newTab(url: URL(string: "https://example.com/current"))
        store.savingEnabled = false
        check(!store.availableCommands.contains(.pin) && !store.availableCommands.contains(.favorite), "Locked data hides metadata-changing command-bar actions")
        store.runCommand(.favorite)
        check(store.tab(id)?.pinned == false && store.favorites.isEmpty, "Executing a stale Favorite command cannot mutate locked metadata")
        store.savingEnabled = true; store.runCommand(.favorite)
        store.profiles[0].pendingDataClear = true
        check(!store.availableCommands.contains(.unpin) && !store.availableCommands.contains(.unfavorite), "A pending profile cannot expose metadata-changing commands")
        store.runCommand(.unfavorite)
        check(store.tab(id)?.favorite == true, "Executing a stale Unfavorite command cannot change a pending profile")
        store.profiles[0].pendingDataClear = false; store.runCommand(.unfavorite)
        let named = try store.createProfile(name: "Import destination")
        let namedSpace = store.space.id
        store.selectSpace(store.session.spaces[0].id)
        var incomingFavorite = BrowserCore.Tab(title: "Imported Favorite", url: "https://example.com/imported", pinned: true); incomingFavorite.favorite = true
        var incoming = Session(); incoming.spaces = [Space(name: "Legacy", tabs: [incomingFavorite])]
        try store.importSession(incoming, into: named)
        check(store.favorites.isEmpty && store.activeProfileID == BrowserProfile.defaultID, "Import uses its captured target profile without switching the active Space")
        store.selectSpace(namedSpace)
        check(store.favorites.count == 1 && store.favorites.first?.url == incomingFavorite.url && store.favorites.first?.id != incomingFavorite.id, "Imported Favorites immediately appear in the target profile with fresh identities")
        let saved = try MetadataStore(url: store.sessionURL, key: key).load(BrowserDocument.self)!
        check(saved.library(for: named).favoriteTabs?.first?.url == incomingFavorite.url, "Imported Favorites and Spaces are encrypted in one commit")
        let before = try Data(contentsOf: store.sessionURL); let count = store.session.spaces.count
        store.vault = MetadataStore(url: root, key: key)
        do { try store.importSession(incoming, into: named) } catch { }
        let after = try Data(contentsOf: store.sessionURL)
        check(!store.savingEnabled && store.session.spaces.count == count && after == before, "A failed import save leaves live Spaces and existing ciphertext unchanged")
        store.shutdown()
        let privateStore = BrowserStore(isPrivate: true)
        var privateRejected = false
        do { try privateStore.importSession(incoming, into: BrowserProfile.defaultID) } catch { privateRejected = true }
        check(privateRejected && privateStore.favorites.isEmpty, "Private windows reject persistent session imports")
        privateStore.shutdown()
        exit(failures == 0 ? 0 : 1)
    }
}
