import Foundation
import CryptoKit
import BrowserCore

var failures = 0
func check(_ value: Bool, _ name: String) { print("\(value ? "PASS" : "FAIL"): \(name)"); if !value { failures += 1 } }
func reject(_ name: String, _ body: () throws -> Void) {
    do { try body(); check(false, name) } catch is LinkRuleError { check(true, name) } catch { check(false, name + " (unexpected error)") }
}
let a = UUID(uuidString: "A0000000-0000-0000-0000-000000000001")!
let b = UUID(uuidString: "B0000000-0000-0000-0000-000000000002")!
let canonicalHosts = [
    ("Example.COM.", "example.com"), ("bücher.example", "xn--bcher-kva.example"),
    ("127.1", "127.0.0.1"), ("0177.0.0.1", "127.0.0.1"), ("0x7f.1", "127.0.0.1"),
    ("2130706433", "127.0.0.1"), ("127.0.0.1", "127.0.0.1"), ("0x", "0.0.0.0"),
    ("[0:0:0:0:0:0:0:1]", "[::1]"), ("::1", "[::1]"), ("[::]", "[::]"),
    ("[2001:0DB8:0:0:1:0:0:1]", "[2001:db8::1:0:0:1]"),
    ("[::ffff:127.0.0.1]", "[::ffff:7f00:1]"), ("localhost", "localhost")
]
for (raw, wanted) in canonicalHosts {
    check(RoutingHost.normalized(raw) == wanted, "Browser host aliases canonicalize without DNS: " + raw)
}
for raw in ["", "a..test", "-a.test", "a-.test", "https://example.test", "user@example.test", "a.test/path", "a.test?x", "a.test#x", "a.test:443", "a%2etest", "a\\b.test", "[:::]", "[::1%en0]", "[gg::1]", "1.2.3.256", "256.1", "1.2.3.4.5", "09", "example.123", "0xffffffffffffffffffff", String(repeating: "a", count: 64) + ".test", String(repeating: "a", count: 4097)] {
    check(RoutingHost.normalized(raw) == nil, "Malformed/ambiguous host is not a routing identity: " + String(raw.prefix(60)))
}
check(QuickBrowseRouting.normalizedHost("127.1") == "127.0.0.1", "Remembered profiles share the browser's numeric address identity")
check(QuickBrowseRouting.normalizedHost("[:::]") == nil, "An invalid IPv6 spelling cannot become a remembered profile identity")
check(QuickBrowseRouting.profile(for: URL(string: "http://0x7f.1/")!, choices: [QuickDomainChoice(host: "127.0.0.1", profileID: b)], available: [a,b], fallback: a) == b, "An alternate numeric spelling cannot bypass a remembered account")

let first = LinkRule(id: a, kind: .contains, pattern: "example.test", destination: .space(a))
let second = LinkRule(id: b, kind: .contains, pattern: "/team", destination: .space(b))
let catalog = LinkRuleCatalog([first,second])
check(catalog.matching(URL(string: "https://EXAMPLE.test/team")!)?.id == a, "The first enabled matching route selects its destination")
check(catalog.matching(URL(string: "https://other.test/team")!)?.id == b, "Contains matches the copied path as well as a hostname")
check(catalog.matching(URL(string: "https://other.test/?next=example.test")!)?.id == a, "An explicitly selected Contains rule includes query text")
let equal = LinkRule(kind: .equals, pattern: "example.test", destination: .mostRecentSpace)
let exact = LinkRuleCatalog([equal])
check(exact.matching(URL(string: "https://example.test/")!) != nil && exact.matching(URL(string: "http://example.test")!) != nil, "Scheme-less equality matches a site's root address")
for value in ["https://example.test/a", "https://example.test/?a=1", "https://example.test/#top", "https://evil.test/?next=example.test", "https://example.test@evil.test/", "https://evil.test/example.test"] {
    check(exact.matching(URL(string: value)!) == nil, "Whole-address equality cannot be confused by another address component: " + value)
}
let path = LinkRuleCatalog([LinkRule(kind: .equals, pattern: "example.test/Team", destination: .quickBrowse)])
check(path.matching(URL(string: "https://example.test/team")!) != nil, "URL equality has stable case-insensitive comparison")
check(path.matching(URL(string: "https://example.test/team/")!) == nil, "A non-root trailing slash stays significant")
let scheme = LinkRuleCatalog([LinkRule(kind: .equals, pattern: "http://example.test/a", destination: .space(a))])
check(scheme.matching(URL(string: "https://example.test/a")!) == nil && scheme.matching(URL(string: "http://example.test/a")!) != nil, "An explicit scheme remains part of full-address equality")
let finalPath = LinkRuleCatalog([LinkRule(kind:.equals,pattern:"example.test/final")])
check(finalPath.matching(URL(string:"https://example.test/a/../final")!) != nil, "URL path traversal is matched at the browser's normalized destination")
check(finalPath.matching(URL(string:"https://example.test/a/%2e%2e/final")!) != nil, "Encoded dot segments cannot bypass a destination rule")
let pathSlash = LinkRuleCatalog([LinkRule(kind:.equals,pattern:"example.test/a/")])
check(pathSlash.matching(URL(string:"https://example.test/a/.")!) != nil, "Removing a final dot segment retains its browser trailing slash")
let encodedSlash = LinkRuleCatalog([LinkRule(kind:.equals,pattern:"example.test/a%2Fb")])
check(encodedSlash.matching(URL(string:"https://example.test/a/b")!) == nil, "An escaped slash stays distinct from a path separator")
let defaults = LinkRuleCatalog([LinkRule(kind: .equals, pattern: "https://EXAMPLE.test:443/", destination: .space(a))])
check(defaults.matching(URL(string: "https://example.test")!) != nil, "Default ports and a root slash do not split equivalent addresses")
let portCases: [(String,String,Bool)] = [
    ("example.test:80","http://example.test/",true),
    ("example.test:80","http://example.test:80/",true),
    ("example.test:80","https://example.test:80/",true),
    ("example.test:80","https://example.test/",false),
    ("example.test:80","http://example.test:443/",false),
    ("example.test:80","https://example.test:443/",false),
    ("example.test:443","http://example.test/",false),
    ("example.test:443","http://example.test:80/",false),
    ("example.test:443","http://example.test:443/",true),
    ("example.test:443","https://example.test/",true),
    ("example.test:443","https://example.test:443/",true),
    ("example.test:443","https://example.test:80/",false),
    ("example.test:8443","http://example.test:8443/",true),
    ("example.test:8443","https://example.test:8443/",true),
    ("example.test:8443","http://example.test/",false),
    ("example.test:8443","https://example.test/",false),
    ("example.test:08443","http://example.test:8443/",true),
    ("example.test:8443","https://example.test:08443/",true),
    ("http://example.test:80","http://example.test/",true),
    ("http://example.test:80","https://example.test/",false),
    ("example.test","http://example.test:80/",true),
    ("example.test","https://example.test:443/",true),
    ("example.test","http://example.test:443/",false),
    ("example.test","https://example.test:80/",false)
]
for (pattern,address,wanted) in portCases {
    let routes = LinkRuleCatalog([LinkRule(kind:.equals,pattern:pattern,destination:.space(b))])
    check((routes.matching(URL(string:address)!) != nil) == wanted, "Equals preserves scheme-associated port identity: \(pattern) → \(address) = \(wanted)")
}
let noPortRule = LinkRule(kind:.equals,pattern:"example.test")
let explicit443Rule = LinkRule(kind:.equals,pattern:"example.test:443")
let differentPortConditions = LinkRuleCatalog([noPortRule,explicit443Rule])
check(differentPortConditions.entries.count == 2, "Saved conditions that differ under HTTP cannot collapse under an invented HTTPS scheme")
check((try? LinkRuleCatalog([noPortRule]).upserting(explicit443Rule))?.count == 2, "Port-specific and implicit-default conditions remain separately editable")
let explicit80Rule = LinkRule(kind:.equals,pattern:"example.test:80")
check((try? differentPortConditions.upserting(explicit80Rule))?.count == 3, "HTTP-default and HTTPS-default conditions remain distinct")
reject("Equivalent default-port aliases remain duplicate conditions across both schemes") {
    _ = try LinkRuleCatalog([explicit80Rule]).upserting(LinkRule(kind:.equals,pattern:"EXAMPLE.test:080/"))
}
reject("Equivalent HTTPS-port aliases remain duplicate conditions across both schemes") {
    _ = try LinkRuleCatalog([explicit443Rule]).upserting(LinkRule(kind:.equals,pattern:"EXAMPLE.test:0443/"))
}
let unicode = LinkRuleCatalog([LinkRule(kind: .equals, pattern: "https://bücher.example/café", destination: .space(a))])
check(unicode.matching(URL(string: "https://xn--bcher-kva.example/caf%C3%A9")!) != nil, "Unicode rules match the browser's IDNA and UTF8 address")
let literal = LinkRuleCatalog([LinkRule(pattern: "invoice.*", destination: .space(a))])
check(literal.matching(URL(string: "https://example.test/invoice123")!) == nil && literal.matching(URL(string: "https://example.test/invoice.*")!) != nil, "Contains treats regex punctuation literally")
let fullContains = LinkRuleCatalog([LinkRule(pattern:"https://example.test",destination:.space(a))])
check(fullContains.matching(URL(string:"https://example.test:8443/a")!) != nil, "A literal full-URL prefix does not invent a trailing slash boundary")
let alias = LinkRuleCatalog([LinkRule(pattern: "127.1", destination: .space(b))])
check(alias.matching(URL(string: "http://2130706433:8123/a")!)?.destination == .space(b), "Literal host patterns and incoming numeric URL aliases share one identity")
for value in ["file:///tmp/example.test", "javascript:example.test", "data:text/plain,example.test"] {
    check(catalog.matching(URL(string: value)!) == nil, "Non-web schemes cannot select a route: " + value)
}
var disabled = first; disabled.enabled = false
check(LinkRuleCatalog([disabled,second]).matching(URL(string: "https://example.test/team")!)?.id == b, "Disabled routes do not intercept matching links")
check(try catalog.moving(b,to:0).first?.id == b, "Reordering changes visible route precedence")
check(LinkRuleCatalog(try catalog.moving(b,to:0)).matching(URL(string: "https://example.test/team")!)?.id == b, "Resolution follows the new saved priority")
reject("An unknown route cannot be moved") { _ = try catalog.moving(UUID(),to:0) }
reject("An overflowing destination index cannot corrupt rule order") { _ = try catalog.moving(a,to:Int.max) }
check(catalog.removing(a).map(\.id) == [b] && LinkRuleCatalog(nil).entries.isEmpty, "Deletion and missing legacy settings do not recreate rules")
let duplicate = LinkRule(kind: .contains, pattern: "EXAMPLE.TEST", destination: .quickBrowse)
reject("A normalized duplicate condition cannot shadow another rule") { _ = try catalog.upserting(duplicate) }
var sameID = second; sameID.id = a
check(LinkRuleCatalog([first,sameID,duplicate]).entries.map(\.id) == [a], "Saved duplicate identities and conditions repair deterministically")
var changed = first; changed.destination = .space(b)
check(try catalog.upserting(changed).first?.destination == .space(b), "Editing a route updates only its own destination")
let orphan = UUID()
check(LinkRuleCatalog([LinkRule(pattern: "orphan.test",destination:.space(orphan))]).entries.first?.destination == .space(orphan), "An unavailable Space remains explicit instead of disappearing into fallback")
for pattern in ["", " \n ", "a\u{0001}b", String(repeating: "界", count: 683)] {
    reject("An invalid or oversized pattern cannot become a rule") { _ = try LinkRule(pattern: pattern).validated() }
}
check(try LinkRule(pattern: String(repeating: "x", count: 2048)).validated().pattern.utf8.count == 2048, "The supported pattern byte boundary remains editable")
reject("An equality rule needs a representable web address") { _ = try LinkRule(kind:.equals,pattern:"not a copied address").validated() }
check(try LinkRule(pattern: "  Café  ").validated().pattern == "Café", "Rules normalize surrounding whitespace and canonical composition")
var many: [LinkRule] = []
for index in 0..<129 { many.append(LinkRule(pattern: "site\(index).test")) }
let full = LinkRuleCatalog(many)
check(full.entries.count == 128 && full.matching(URL(string:"https://site128.test")!) == nil, "Oversized persisted rules cannot grow an unbounded matcher")
reject("Adding past capacity preserves the existing catalog") { _ = try full.upserting(LinkRule(pattern:"extra.test")) }
var atCapacity = full.entries[127]; atCapacity.destination = .space(b)
check(try full.upserting(atCapacity).last?.destination == .space(b), "Editing remains possible at capacity")

var session = Session(), profile = BrowserProfile(name:"Owned second profile")
var other = Space(name:"Other"); other.profileID = profile.id
session.spaces.append(other)
check(session.activateSpace(other.id) && session.selectedSpace == other.id && session.lastUsedSpaces?[profile.id] == other.id, "Activating a Space records the latest Space for its actual profile")
check(!session.activateSpace(UUID()) && session.selectedSpace == other.id, "An unknown Space cannot change the recent destination")
let old = Date(timeIntervalSince1970: 10)
var archivedTab = BrowserCore.Tab(title:"Old",url:"https://example.test/old"); archivedTab.lastAccessed = old
session.spaces[0].tabs = [archivedTab]
let originalSpace = session.spaces[0].id
let archived = session.archiveInactive(before:Date(timeIntervalSince1970:20),excluding:[])
check(archived.first?.archivedSpaceID == originalSpace && !session.spaces[0].tabs.contains(where:{$0.id==archivedTab.id}), "Archiving retains the source Space as a restoration hint")
var doc = BrowserDocument(session:session,profiles:[.defaultProfile,profile])
doc.preferences.linkRules = [first,second]; doc.preferences.linkDefaultDestination = .space(b)
doc.library.archive = archived
doc.session.lastUsedSpaces = [profile.id:other.id, BrowserProfile.defaultID:other.id, orphan:originalSpace]
try doc.repairProfiles()
check(doc.session.lastUsedSpaces == [profile.id:other.id], "Repair removes recent hints whose Space belongs to another or unknown profile")
let root = FileManager.default.temporaryDirectory.appendingPathComponent("Alcove.LinkRoutingCore.\(UUID())")
defer { try? FileManager.default.removeItem(at:root) }
let vault = MetadataStore(url:root.appendingPathComponent("metadata.sealed"),key:SymmetricKey(size:.bits256))
try vault.save(doc)
let restored = try vault.load(BrowserDocument.self)!
check(restored.formatVersion == 5 && restored.preferences.linkRules == [first,second] && restored.preferences.linkDefaultDestination == .space(b), "Routing preferences survive encrypted format5 relaunch")
check(restored.session.lastUsedSpaces?[profile.id] == other.id && restored.library.archive.first?.archivedSpaceID == originalSpace, "Recent and archive hints survive encrypted relaunch")
check(!String(decoding:try Data(contentsOf:vault.url),as:UTF8.self).contains("example.test"), "Routing expressions are not plaintext metadata")
var legacy = try JSONSerialization.jsonObject(with:JSONEncoder().encode(BrowserDocument())) as! [String:Any]
legacy["formatVersion"] = 3
legacy["preferences"] = ["suspendTabs":false,"archiveAfterDays":0]
let decoded = try JSONDecoder().decode(BrowserDocument.self,from:JSONSerialization.data(withJSONObject:legacy))
check(decoded.formatVersion == 3 && decoded.preferences.linkRules == nil && decoded.preferences.linkDefaultDestination == nil && decoded.session.lastUsedSpaces == nil, "Legacy format3 data remains readable without routing or recent fields")
if failures > 0 { exit(1) }
