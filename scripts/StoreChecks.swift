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
        normal.archiveTimer?.invalidate(); restored.archiveTimer?.invalidate()
        exit(failures == 0 ? 0 : 1)
    }
}
