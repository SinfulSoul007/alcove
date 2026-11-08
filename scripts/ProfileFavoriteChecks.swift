import AppKit
import WebKit
import CryptoKit
import BrowserCore

@main struct ProfileFavoriteChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        var failures = 0
        func check(_ value: Bool, _ name: String) { print("\(value ? "PASS" : "FAIL"): \(name)"); if !value { failures += 1 } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256)
        var favorite = BrowserCore.Tab(title: "Personal Favorite", url: "https://example.com/a", pinned: true); favorite.favorite = true
        let first = Space(name: "First", tabs: [favorite])
        let second = Space(name: "Second")
        var session = Session(); session.spaces = [first, second]; session.selectedSpace = first.id
        let storage = MetadataStore(url: root.appendingPathComponent("session-v2.sealed"), key: key)
        try storage.save(BrowserDocument(session: session))
        let store = BrowserStore(dataRoot: root, keyProvider: { _ in key })
        var originalPage: WKWebView? = store.view(for: favorite.id)
        store.selectSpace(second.id); store.selectAny(favorite.id)
        check(store.space.id == second.id && store.selectedID == favorite.id, "Selecting a shared Favorite keeps the current Space")
        check(store.view(for: favorite.id) === originalPage, "Selecting a Favorite in another same-profile Space preserves its native page")
        store.update(favorite.id) { $0.url = "https://example.com/a/new" }
        let named = try store.createProfile(name: "Work")
        let workSpace = store.space.id
        let workFavorite = store.newTab(url: URL(string: "https://example.com/b")!); store.toggleFavorite(workFavorite)
        try store.assignProfile(named, to: first.id)
        try store.assignProfile(named, to: second.id)
        check(store.favorites.map(\.id) == [workFavorite], "Reassigning a Space shows only its destination profile's Favorites")
        check(store.profileID(for: favorite.id) == BrowserProfile.defaultID && store.tab(favorite.id)?.url == "https://example.com/a/new", "A profile retains its Favorite even after its last Space changes profile")
        check(!store.profileTabs.contains(where: { $0.id == favorite.id }), "Another profile's unmounted Favorite is absent from command search")
        check(store.views[favorite.id] == nil, "Reassigning a Favorite's backing Space releases its old native page")
        try store.assignProfile(BrowserProfile.defaultID, to: first.id)
        store.selectSpace(first.id)
        check(store.favorites.map(\.id) == [favorite.id] && store.profileTabs.contains(where: { $0.id == favorite.id }), "Returning to a profile restores its shared Favorites and command search")
        store.flush(); store.shutdown(); originalPage = nil
        let reopened = BrowserStore(dataRoot: root, keyProvider: { _ in key })
        check(reopened.favorites.map(\.id) == [favorite.id] && reopened.tab(favorite.id)?.url == "https://example.com/a/new", "Unmounted Favorites survive encrypted save and relaunch")
        reopened.selectAny(favorite.id); reopened.close(favorite.id)
        check(reopened.favorites.count == 1 && reopened.tab(favorite.id)?.url == favorite.url, "Closing a Favorite resets its saved home without removing the profile's Favorite")
        reopened.toggleFavorite(favorite.id)
        check(reopened.favorites.isEmpty && reopened.tab(favorite.id)?.pinned == true, "Removing Favorite status preserves a pinned tab in its current Space")
        reopened.toggleFavorite(favorite.id)
        let denied = reopened.move(favorite.id, to: workSpace)
        check(!denied && reopened.favorites.map(\.id) == [favorite.id], "An unconsented cross-profile Favorite move preserves ownership")
        let moved = reopened.move(favorite.id, to: workSpace, allowProfileChange: true)
        check(moved && reopened.favorites.isEmpty && reopened.profileID(for: favorite.id) == named, "An explicit cross-profile Favorite move updates both profile collections")
        reopened.selectSpace(workSpace)
        reopened.removeFromSidebar(favorite.id)
        check(!reopened.favorites.contains(where: { $0.id == favorite.id }) && reopened.library.closedTabs.first?.id == favorite.id, "Removing a Favorite updates its profile collection and recently closed tabs")
        try await reopened.clearProfileData(named, removeData: { _ in })
        check(reopened.favorites.isEmpty, "Clearing profile data also clears its shared Favorites")
        let unpinStore = BrowserStore(isPrivate: true)
        unpinStore.library.favoriteTabs = [favorite]
        unpinStore.togglePin(favorite.id)
        check(unpinStore.favorites.isEmpty && unpinStore.tab(favorite.id)?.pinned == false && unpinStore.space.tabs.contains(where: { $0.id == favorite.id }), "Unpinning an unmounted Favorite preserves it as a regular tab")
        unpinStore.shutdown()
        reopened.shutdown(); reopened.namedDataStores.removeAll()
        try? await WKWebsiteDataStore.remove(forIdentifier: named)
        exit(failures == 0 ? 0 : 1)
    }
}
