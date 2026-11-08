import AppKit
import CryptoKit
import BrowserCore

@main
struct StoreChecks {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        var failures = 0
        func check(_ result: Bool, _ name: String) {
            print("\(result ? "PASS" : "FAIL"): \(name)"); if !result { failures += 1 }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256)
        let normal = BrowserStore(dataRoot: root, keyProvider: { _ in key })
        normal.session.spaces[0].tabs[0].url = "https://webkit.org"
        normal.session.spaces[0].tabs[0].title = "WebKit"
        normal.library.bookmark(title: "WebKit", url: "https://webkit.org")
        normal.flush()
        let bytes = try Data(contentsOf: normal.sessionURL)
        let restored = BrowserStore(dataRoot: root, keyProvider: { _ in key })
        check(restored.selectedTab?.url == "https://webkit.org", "Browser restores encrypted session")
        check(restored.library.bookmarks.first?.title == "WebKit", "Browser restores encrypted bookmarks")
        var keyRequests = 0
        let privateRoot = root.appendingPathComponent("private")
        let privateStore = BrowserStore(isPrivate: true, dataRoot: privateRoot, keyProvider: { _ in keyRequests += 1; return key })
        privateStore.session = normal.session
        privateStore.library = normal.library
        privateStore.flush(); privateStore.save()
        check(keyRequests == 0, "Private window never requests a persistent encryption key")
        check(!FileManager.default.fileExists(atPath: privateRoot.path), "Private browser never creates a metadata directory")
        check(privateStore.privateDataStore?.isPersistent == false, "Private browser selects ephemeral website storage")
        let wrongKey = BrowserStore(dataRoot: root, keyProvider: { _ in SymmetricKey(size: .bits256) })
        wrongKey.flush()
        check(!wrongKey.savingEnabled, "Wrong key disables saving")
        check(try Data(contentsOf: normal.sessionURL) == bytes, "Decryption failure preserves existing metadata")
        let unavailable = BrowserStore(dataRoot: root, keyProvider: { _ in throw CocoaError(.fileReadNoPermission) })
        unavailable.flush()
        check(!unavailable.savingEnabled, "Unavailable Keychain disables saving")
        check(try Data(contentsOf: normal.sessionURL) == bytes, "Keychain failure preserves existing metadata")
        let second = normal.newTab(url: URL(string: "https://example.com"))
        let first = normal.session.spaces[0].tabs[0].id
        normal.splitID = first
        normal.close(second)
        check(normal.splitID == nil && normal.selectedID == first, "Closing primary split pane keeps a single live tab")
        normal.reopenClosed()
        check(normal.selectedTab?.url == "https://example.com" && normal.selectedID != second, "Reopen restores closed URL with fresh tab identity")
        for i in 0..<501 {
            var tab = BrowserCore.Tab(title: "Archived \(i)", url: "https://example.com/\(i)")
            tab.lastAccessed = Date(timeIntervalSince1970: 1)
            normal.session.spaces[0].tabs.append(tab)
        }
        normal.preferences.archiveAfterDays = 1; normal.archiveOldTabs()
        check(normal.library.archive.count == 501, "Auto-archive preserves more than 500 tabs without silent loss")
        let popup = normal.newTab(url: URL(string: "https://example.com/popup"))
        let otherSpace = Space(name: "Other")
        normal.session.spaces.append(otherSpace); normal.selectSpace(otherSpace.id)
        normal.close(popup)
        check(normal.tab(popup) == nil, "Closing background popup removes tab from its owning Space")
        let pinnedID = normal.newTab(url: URL(string: "https://example.com/home"))
        normal.togglePin(pinnedID)
        normal.update(pinnedID) { $0.url = "https://example.com/deeper" }
        normal.close(pinnedID)
        check(normal.tab(pinnedID)?.pinned == true && normal.tab(pinnedID)?.url == "https://example.com/home", "Closing a pinned tab preserves it and resets its home URL")
        let beforeCommand = normal.space.tabs.count
        normal.showCommand(new: true)
        check(normal.space.tabs.count == beforeCommand && normal.command.isEmpty, "New-tab command does not create a tab until submitted")
        normal.commandVisible = false
        let favoriteID = normal.newTab(url: URL(string: "https://example.com/favorite"))
        normal.runCommand(.favorite)
        check(normal.favorites.contains(where: { $0.id == favoriteID }) && normal.tab(favoriteID)?.homeURL == "https://example.com/favorite", "Favorite command preserves the tab and its saved destination")
        normal.runCommand(.favorite)
        check(normal.favorites.filter { $0.id == favoriteID }.count == 1, "Repeating Favorite command never toggles it off")
        normal.runCommand(.unfavorite)
        check(!normal.favorites.contains(where: { $0.id == favoriteID }) && normal.tab(favoriteID)?.pinned == true, "Unfavorite keeps the tab pinned in its owning Space")
        let primaryID = normal.selectedID!
        let side = normal.newTab(url: URL(string: "https://example.com/side"))
        normal.select(primaryID); normal.splitID = side; normal.focusPane(side)
        check(normal.selectedID == primaryID && normal.selectedTab?.id == side, "Focusing split pane routes actions without replacing the main pane")
        normal.close(side)
        check(normal.focusedID == primaryID && normal.splitID == nil, "Closing active split pane returns focus to the main page")
        let host = EdgeToEdgeWebHost()
        let firstView = NSView(); let secondView = NSView()
        host.setContent(firstView); host.setContent(secondView)
        check(host.subviews.count == 1 && host.subviews.first === secondView, "Replacing Peek content mounts only the new native page")
        let scroll = NSScrollView(); scroll.automaticallyAdjustsContentInsets = true
        scroll.contentInsets = NSEdgeInsets(top: 28, left: 0, bottom: 0, right: 0)
        host.setContent(scroll)
        check(!scroll.automaticallyAdjustsContentInsets && scroll.contentInsets.top == 0, "Browser page host removes overlapping titlebar gaps")
        let unlockFirst = wrongKey.unlockLocalData(keyProvider: { key })
        let unlockSecond = wrongKey.unlockLocalData(keyProvider: { key })
        check(unlockFirst && !unlockSecond, "Repeated Unlock clicks start only one restore")
        normal.archiveTimer?.invalidate(); restored.archiveTimer?.invalidate()
        exit(failures == 0 ? 0 : 1)
    }
}
