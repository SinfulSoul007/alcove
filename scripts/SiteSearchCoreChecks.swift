import Foundation
import CryptoKit
import BrowserCore

var failures = 0
func check(_ value: Bool, _ name: String) { print("\(value ? "PASS" : "FAIL"): \(name)"); if !value { failures += 1 } }
func reject(_ name: String, _ action: () throws -> Void) {
    do { try action(); check(false, name) }
    catch is SiteSearchError { check(true, name) }
    catch { check(false, name + " (unexpected error)") }
}
let firstID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
let secondID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
let thirdID = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
let search = SiteSearch(id: firstID, name: "Example", keyword: "ex", template: "https://example.test/search?q=%s&fixed=1")
let query = " cats & dogs/#?%=+ café 🐈 "
let encoded = "cats%20%26%20dogs%2F%23%3F%25%3D%2B%20caf%C3%A9%20%F0%9F%90%88"
let queryURL = try search.url(for: query)
check(queryURL.absoluteString == "https://example.test/search?q=" + encoded + "&fixed=1", "Query delimiters and Unicode become one correctly escaped query value")
check(URLComponents(url: queryURL, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "cats & dogs/#?%=+ café 🐈", "The receiving site recovers the intended trimmed query")
let path = SiteSearch(name: "Path", keyword: "path", template: "https://example.test/find/%s?fixed=1#top")
check(try path.url(for: "a/b?x#y").absoluteString == "https://example.test/find/a%2Fb%3Fx%23y?fixed=1#top", "Path queries cannot add path segments, parameters or fragments")
let fragment = SiteSearch(name: "Fragment", keyword: "frag", template: "https://example.test/#q=%s")
check(try fragment.url(for: "a#b&c").absoluteString == "https://example.test/#q=a%23b%26c", "Fragment search keeps user delimiters inside its configured value")
let local = SiteSearch(name: "Local", keyword: "local", template: "http://127.0.0.1:8123/search?q=%s")
check(try local.url(for: "https://evil.test/@x").absoluteString == "http://127.0.0.1:8123/search?q=https%3A%2F%2Fevil.test%2F%40x", "A query cannot change an HTTP template's host or explicit port")
check(try search.url(for: "a%20b + -._~").absoluteString == "https://example.test/search?q=a%2520b%20%2B%20-._~&fixed=1", "Literal percent and plus are escaped once while unreserved bytes survive")
reject("Empty queries do not navigate") { _ = try search.url(for: " \n\t ") }
var disabled = search; disabled.enabled = false
reject("A disabled site cannot produce a navigation URL") { _ = try disabled.url(for: "query") }
let invalidTemplates = ["javascript:alert('%s')", "file:///tmp/%s", "data:text/html,%s", "https:///search?q=%s", "https://user:pass@example.test/?q=%s", "https://example.test/search", "https://example.test/?a=%s&b=%s", "https://%s.example.test/search", "https://example.test:%s/search", "%s://example.test/search", "https://example.test/a b?q=%s", "https://example.test/?q=%s&other=\nvalue", "https://example.test/\u{0001}?q=%s"]
for template in invalidTemplates {
    reject("Invalid or authority-changing template is rejected: " + template.debugDescription) { _ = try SiteSearch(name: "Invalid", keyword: "bad", template: template).validated() }
}
let malformedEscapes = ["https://example.test/?q=%%s", "https://example.test/?q=%2%s", "https://example.test/?q=%G1%s", "https://example.test/?q=%s%", "https://example.test/?q=%s%0", "https://example.test/?q=%s%GG"]
for template in malformedEscapes {
    let malformed = SiteSearch(name: "Bad escape", keyword: "escape", template: template)
    reject("Malformed literal percent escape is rejected: " + template) { _ = try malformed.validated() }
    check(SiteSearchCatalog([malformed]).entries.isEmpty, "Saved catalog repair drops a malformed percent escape: " + template)
}
for dot in [".", ".."] {
    reject("A path query cannot become a normalized dot segment: " + dot) { _ = try path.url(for: dot) }
    check(try search.url(for: dot).absoluteString == "https://example.test/search?q=" + dot + "&fixed=1", "Dot-only queries remain usable in a query parameter: " + dot)
}
for template in ["https://example.test/find/.%s", "https://example.test/find/%2e%s", "https://example.test/find/%s.", "https://example.test/find/%s%2E"] {
    reject("Literal and query dots cannot combine into a path traversal segment: " + template) { _ = try SiteSearch(name: "Dot", keyword: "dot", template: template).url(for: ".") }
}
let literalEscapes = SiteSearch(name: "Escapes", keyword: "esc", template: "https://example.test/find/%41%s?fixed=%25#%2e")
check(try literalEscapes.url(for: "café").absoluteString == "https://example.test/find/%41caf%C3%A9?fixed=%25#%2e", "Complete literal escapes and Unicode query bytes remain intact")
check(try SiteSearch(name: "Suffix", keyword: "suffix", template: "https://example.test/find/%s.html").url(for: "..").absoluteString == "https://example.test/find/...html", "A fixed path suffix can represent an otherwise dot-only query")
let clean = try SiteSearch(name: "  Café  ", keyword: "  Cafe\u{301}.COM  ", template: "  https://example.test/?q=%s  ").validated()
check(clean.name == "Café" && clean.keyword == "café.com" && clean.template == "https://example.test/?q=%s", "Configuration canonicalizes Unicode, case and surrounding whitespace")
for keyword in ["", "two words", "javascript:", "a/b", "a?b", "a#b", "a@b", "a%b", "a\u{0001}b", String(repeating: "a", count: 33)] {
    reject("Invalid shortcut cannot become an input action: " + keyword.debugDescription) { _ = try SiteSearch(name: "Test", keyword: keyword, template: search.template).validated() }
}
check(try SiteSearch(name: String(repeating: "界", count: 80), keyword: String(repeating: "界", count: 32), template: search.template).validated().keyword.count == 32, "Unicode configuration accepts the supported character bounds")
reject("An overlong display name cannot crowd native controls") { _ = try SiteSearch(name: String(repeating: "a", count: 81), keyword: "long", template: search.template).validated() }
reject("A blank display name is not accepted") { _ = try SiteSearch(name: " \n ", keyword: "blank", template: search.template).validated() }
let prefix = "https://example.test/?q=%s&pad="
let limitTemplate = prefix + String(repeating: "x", count: 8192 - prefix.utf8.count)
check(try SiteSearch(name: "Long", keyword: "long", template: limitTemplate).validated().template.utf8.count == 8192, "A valid template at the byte limit remains usable")
reject("An oversized template is rejected before matching or navigation") { _ = try SiteSearch(name: "Long", keyword: "long", template: limitTemplate + "x").validated() }
let alternate = SiteSearch(id: secondID, name: "Extra", keyword: "extra", template: "https://extra.test/?q=%s")
let catalog = SiteSearchCatalog([search, alternate])
check(catalog.matches("EX").map(\.id) == [firstID, secondID], "Case-insensitive prefix matching exposes available sites in saved order")
check(catalog.preferredMatch("ex")?.id == firstID, "An exact shortcut wins over a longer matching prefix")
check(catalog.preferredMatch("e") == nil, "Ambiguous prefixes do not hijack native Tab navigation")
check(catalog.preferredMatch("extr")?.id == secondID, "A unique prefix activates its one configured site")
check(catalog.matches("hello world").isEmpty && catalog.preferredMatch("") == nil, "Ordinary queries and empty input are not shortcut actions")
check(SiteSearchCatalog([disabled]).matches("ex").isEmpty, "Disabled sites stay out of input matching")
let bad = SiteSearch(name: "Bad", keyword: "bad", template: "https://example.test/no-placeholder")
var duplicateID = alternate; duplicateID.id = firstID
var duplicateKeyword = alternate; duplicateKeyword.keyword = " EX "
var off = alternate; off.id = thirdID; off.keyword = "off"; off.enabled = false
let repaired = SiteSearchCatalog([search, duplicateID, duplicateKeyword, bad, off])
check(repaired.entries.map(\.id) == [firstID, thirdID], "Persisted duplicate ids, duplicate canonical shortcuts and invalid templates cannot shadow valid entries")
check(repaired.entries.last?.enabled == false, "Repair preserves disabled configuration for later editing")
reject("An editor cannot add a duplicate canonical keyword") { _ = try catalog.upserting(duplicateKeyword) }
var edited = search; edited.name = "Updated"
let changed = try catalog.upserting(edited)
check(changed.count == 2 && changed.first?.name == "Updated" && changed.last?.id == secondID, "Editing replaces only the same record and preserves other shortcuts")
check(catalog.removing(firstID).map(\.id) == [secondID], "Deleting a shortcut preserves the remaining configuration")
var many: [SiteSearch] = []
for index in 0..<129 { many.append(SiteSearch(name: "Engine \(index)", keyword: "e\(index)", template: search.template)) }
let full = SiteSearchCatalog(many)
check(full.entries.count == 128 && full.preferredMatch("e128") == nil, "Persisted catalog size is bounded before input matching")
reject("Adding past capacity preserves existing entries") { _ = try full.upserting(SiteSearch(name: "Another", keyword: "another", template: search.template)) }
var lastEdit = full.entries.last!; lastEdit.name = "Edited at capacity"
check(try full.upserting(lastEdit).last?.name == "Edited at capacity", "Editing an existing record still works at capacity")
check(try SiteSearchCatalog(nil).preferredMatch("yt")?.url(for: "browser").absoluteString == "https://www.youtube.com/results?search_query=browser", "Missing legacy configuration provides a working built-in shortcut")
check(SiteSearchCatalog([]).entries.isEmpty, "Explicit removal of every shortcut does not recreate defaults")
var oldObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(BrowserDocument())) as! [String: Any]
oldObject.removeValue(forKey: "formatVersion"); oldObject["preferences"] = ["suspendTabs": false, "archiveAfterDays": 0]
var legacy = try JSONDecoder().decode(BrowserDocument.self, from: JSONSerialization.data(withJSONObject: oldObject))
try legacy.repairProfiles()
check(legacy.formatVersion == 3 && legacy.preferences.siteSearches == nil && SiteSearchCatalog(legacy.preferences.siteSearches).preferredMatch("wiki") != nil, "Legacy documents retain format3 and receive defaults without losing their session")
let root = FileManager.default.temporaryDirectory.appendingPathComponent("Alcove.SiteSearchCore.\(UUID())")
defer { try? FileManager.default.removeItem(at: root) }
let vault = MetadataStore(url: root.appendingPathComponent("metadata.sealed"), key: SymmetricKey(size: .bits256))
legacy.preferences.siteSearches = changed
try vault.save(legacy)
let restored = try vault.load(BrowserDocument.self)
check(restored?.preferences.siteSearches == changed && restored?.formatVersion == 3, "Encrypted metadata restores custom shortcuts and enabled state")
check(!String(decoding: try Data(contentsOf: vault.url), as: UTF8.self).contains("example.test"), "Saved search templates are not plaintext metadata")
legacy.preferences.siteSearches = []; try vault.save(legacy)
check(try vault.load(BrowserDocument.self)?.preferences.siteSearches == [], "An intentionally empty catalog survives encrypted relaunch")
if failures > 0 { exit(1) }
