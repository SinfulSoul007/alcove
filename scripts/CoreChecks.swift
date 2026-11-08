import Foundation
import BrowserCore
import CryptoKit
var failures = 0
func check(_ value: @autoclosure () -> Bool, _ name: String) {
    if value() { print("PASS: \(name)") } else { print("FAIL: \(name)"); failures += 1 }
}
check(Address.resolve("example.com")?.absoluteString == "https://example.com", "Domain defaults to HTTPS")
check(Address.resolve("localhost:8080")?.absoluteString == "http://localhost:8080", "Local development uses HTTP")
check(Address.resolve("https://example.com/a?q=x")?.absoluteString == "https://example.com/a?q=x", "Explicit URL preserved")
check(Address.resolve("cats & dogs")?.absoluteString.contains("q=cats%20%26%20dogs") == true, "Search escapes query separators")
check(Address.resolve("  ") == nil, "Empty address rejected")
check(Address.resolve("javascript:alert(1)") == nil, "JavaScript address rejected")
check(Address.resolve("file:///etc/passwd") == nil, "File address rejected")
var session = Session()
let original = session.spaces[0].tabs[0].id
session.close(original, in: session.selectedSpace)
check(session.spaces[0].tabs.count == 1 && session.spaces[0].tabs[0].id != original, "Closing last tab creates usable empty tab")
check(session.spaces[0].selected == session.spaces[0].tabs[0].id, "Selection repaired after close")
session.spaces[0].tabs.append(Tab(title: "Docs", url: "https://webkit.org", pinned: true))
let decoded = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(session))
check(decoded.spaces[0].tabs == session.spaces[0].tabs && decoded.selectedSpace == session.selectedSpace, "Session persists URLs, pins and selection")

var library = BrowserLibrary()
library.record(title: "Example", url: "https://example.com")
library.record(title: "Example updated", url: "https://example.com")
check(library.history.count == 1 && library.history.first?.title == "Example updated", "History coalesces consecutive same-page visits")
library.record(title: "Inline secret", url: "data:text/html,private")
check(library.history.count == 1, "History excludes non-web URLs")
library.bookmark(title: "Docs", url: "https://webkit.org")
library.bookmark(title: "Docs updated", url: "https://webkit.org")
check(library.bookmarks.count == 1 && library.bookmarks.first?.title == "Docs updated", "Bookmarks deduplicate by URL")
var archiveSession = Session()
var old = Tab(title: "Old", url: "https://example.com")
old.lastAccessed = Date(timeIntervalSince1970: 1)
var pinned = old; pinned.id = UUID(); pinned.pinned = true
var active = old; active.id = UUID()
var unknown = old; unknown.id = UUID(); unknown.lastAccessed = nil
archiveSession.spaces[0].tabs = [old, pinned, active, unknown]
archiveSession.spaces[0].selected = active.id
let archived = archiveSession.archiveInactive(before: Date(timeIntervalSince1970: 100), excluding: [active.id])
check(archived.map(\.id) == [old.id], "Archive preserves pinned, active and undated tabs")
check(archiveSession.spaces[0].tabs.map(\.id) == [pinned.id, active.id, unknown.id], "Archive removes only eligible tabs")
let legacy = Data("{\"id\":\"00000000-0000-0000-0000-000000000001\",\"title\":\"Legacy\",\"url\":\"https://example.com\",\"pinned\":false}".utf8)
let legacyTab = try JSONDecoder().decode(Tab.self, from: legacy)
check(legacyTab.folder == nil, "Old tabs decode without folder or access-date fields")
let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: temp) }
let store = MetadataStore(url: temp.appendingPathComponent("data.sealed"), key: SymmetricKey(size: .bits256))
try store.save(BrowserDocument(session: session, library: library))
let restored = try store.load(BrowserDocument.self)
check(restored?.session.spaces[0].tabs == session.spaces[0].tabs, "Encrypted metadata restores tabs")
check(restored?.library.bookmarks.first?.url == "https://webkit.org", "Encrypted metadata restores library")
if FileManager.default.fileExists(atPath: store.url.path) {
    let bytes = try Data(contentsOf: store.url)
    check(!String(decoding: bytes, as: UTF8.self).contains("https://webkit.org"), "Metadata URLs are not plaintext on disk")
    let mode = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? NSNumber
    check(mode?.intValue == 0o600, "Metadata readable only by owner")
    let directoryMode = try FileManager.default.attributesOfItem(atPath: temp.path)[.posixPermissions] as? NSNumber
    check(directoryMode?.intValue == 0o700, "Metadata directory accessible only by owner")
    var damaged = bytes; damaged[damaged.count - 1] ^= 1
    try damaged.write(to: store.url)
    var tamperRejected = false
    do { let _: BrowserDocument? = try store.load(BrowserDocument.self) } catch { tamperRejected = true }
    check(tamperRejected, "Tampered ciphertext is rejected")
} else { check(false, "Encrypted metadata file is created") }
let privateURL = temp.appendingPathComponent("private.sealed")
let privateStore = MetadataStore(url: privateURL, key: SymmetricKey(size: .bits256), isPrivate: true)
try privateStore.save(BrowserDocument(session: session, library: library))
check(!FileManager.default.fileExists(atPath: privateURL.path), "Private metadata never creates a file")
let privateRead = try MetadataStore(url: store.url, key: store.key, isPrivate: true).load(BrowserDocument.self)
check(privateRead == nil, "Private metadata never reads normal files")
check(SidebarSizing.width(saved: 100, windowWidth: 1000) == 196, "Sidebar resizing preserves usable minimum width")
check(SidebarSizing.width(saved: 500, windowWidth: 1000) == 360, "Sidebar resizing clamps excessive width")
check(SidebarSizing.width(saved: 350, windowWidth: 600) == 270, "Narrow windows reserve space for web content")
var dragSession = Session()
let dragSpace = dragSession.selectedSpace
let dragged = dragSession.spaces[0].tabs[0].id
let anchor = Tab(title: "Anchor", url: "https://example.com")
dragSession.spaces[0].tabs[0].url = "https://webkit.org"
dragSession.spaces[0].tabs.append(anchor)
dragSession.placeTab(dragged, in: dragSpace, section: .pinned, before: anchor.id)
check(dragSession.spaces[0].tabs.first?.pinned == true && dragSession.spaces[0].tabs.first?.homeURL == "https://webkit.org", "Dragging into pins captures the saved destination")
let destination = Space(name: "Destination")
dragSession.spaces.append(destination)
dragSession.placeTab(dragged, in: destination.id, section: .favorites)
check(dragSession.spaces[1].tabs.last?.id == dragged && dragSession.spaces[1].tabs.last?.favorite == true, "Dragging across Spaces moves the tab and applies Favorites")
check(!dragSession.spaces[0].tabs.contains(where: { $0.id == dragged }) && dragSession.spaces[0].selected == anchor.id, "Cross-Space drag repairs source selection")
dragSession.placeTab(dragged, in: destination.id, section: .today)
check(dragSession.spaces[1].tabs.last?.pinned == false && dragSession.spaces[1].tabs.last?.favorite != true, "Dragging to Today removes persistent pin and Favorite state")
check(!BrowserCommand.unpin.matches("pin tab"), "Pin command search never selects the inverse Unpin action")
check(!BrowserCommand.unfavorite.matches("favorite"), "Favorite command search never selects Unfavorite")
check(BrowserCommand.sidebar.matches("toggle side"), "Command search accepts word prefixes")
exit(failures == 0 ? 0 : 1)
