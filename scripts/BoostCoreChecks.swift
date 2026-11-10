import Foundation
import CryptoKit
import BrowserCore

var failures = 0
func check(_ value: Bool, _ name: String) { print("\(value ? "PASS" : "FAIL"): \(name)"); if !value { failures += 1 } }
func reject(_ name: String, _ body: () throws -> Void) {
    do { try body(); check(false, name) } catch { check(true, name) }
}
// A missing port range check accepts addresses the engine cannot load.
for port in [65536, 99999] {
    reject("Equals cannot save an unusable explicit port \(port)") { _ = try LinkRule(kind: .equals, pattern: "https://example.test:\(port)/").validated() }
    reject("Scheme-less Equals cannot save an unusable port \(port)") { _ = try LinkRule(kind: .equals, pattern: "example.test:\(port)").validated() }
}
check(try LinkRule(kind: .equals, pattern: "https://example.test:65535/").validated().pattern == "https://example.test:65535/", "Equals keeps the highest usable port")
let id = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
let otherID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
let appearance = BoostAppearance(background: "#123aBc", text: "#abcdef", link: "#ff0022", font: .serif, textScale: 1.25)
let content = BoostContent(name: "  Quiet Café  ", host: " EXAMPLE.test. ", appearance: appearance, css: "\n/* exact */ p{line-height:1.6}\n", javascript: "\nawait Promise.resolve(); window.counter = 1;\n")
var boost = try SiteBoost(id: id, content: content, hiddenSelectors: ["#ad", "main > div:nth-of-type(2)"]).validated()
check(boost.content.name == "Quiet Café" && boost.content.host == "example.test", "Editing normalizes the name and canonical site")
check(boost.content.css == "\n/* exact */ p{line-height:1.6}\n" && boost.content.javascript == "\nawait Promise.resolve(); window.counter = 1;\n", "Saving preserves exact CSS and JavaScript whitespace")
check(boost.content.appearance.background == "#123ABC" && boost.content.appearance.text == "#ABCDEF", "Colors have one validated hexadecimal representation")
check(boost.content.appearance.css.contains("#123ABC") && boost.content.appearance.css.contains("serif") && !boost.content.appearance.css.contains("font-size") && boost.content.appearance.textScale == 1.25, "No-code colors/fonts remain static while relative scaling retains its factor for the real site baseline")
check(BoostAppearance().css.isEmpty, "An untouched appearance preserves the website's original design")
let catalog = BoostCatalog([boost])
for address in ["https://EXAMPLE.test/", "http://example.test:8123/path?q=x", "https://example.test./"] {
    check(catalog.matching(URL(string: address)!)?.id == id, "Boost applies to the exact site across supported schemes/ports: \(address)")
}
for address in ["https://sub.example.test/", "https://example.test.evil/", "https://example.test@evil.test/", "https://evil.test/?url=example.test", "https://example.test:99999/", "file:///example.test", "data:text/html,example.test"] {
    check(catalog.matching(URL(string: address)!) == nil, "Nonmatching or unusable URL cannot receive the Boost: \(address)")
}
for (host, address) in [("bücher.test", "https://xn--bcher-kva.test/"), ("0x7f.1", "http://127.0.0.1:1000/"), ("[0:0:0:0:0:0:0:1]", "http://[::1]/")] {
    check(BoostCatalog([SiteBoost(content: BoostContent(name: "Alias", host: host))]).matching(URL(string: address)!) != nil, "Site aliases agree with browser host identity: \(host)")
}
check(WebOrigin(URL(string: "https://example.test/")!)?.port == 443 && WebOrigin(URL(string: "http://example.test:0/")!)?.port == 0, "Origins distinguish defaults and an explicit zero port")
for host in ["", "*.example.test", "example.test/path", "user@example.test", "example.test:80", "bad..test", "127.0.0.999"] {
    reject("Invalid site scope is rejected: \(host.debugDescription)") { _ = try BoostContent(name: "Invalid", host: host).validated() }
}
for color in ["red", "#fff", "#12345678", "#12gg34", "#123456; color:red"] {
    reject("Arbitrary CSS cannot enter the no-code color field") { _ = try BoostAppearance(background: color).validated() }
}
for scale in [0.74, 1.76, .nan, .infinity] {
    reject("Invalid text scale is rejected: \(scale)") { _ = try BoostAppearance(textScale: scale).validated() }
}
for scale in [0.75, 1.75] { check(try BoostAppearance(textScale: scale).validated().textScale == scale, "Supported text-scale endpoint works: \(scale)") }
for name in ["", " \n ", "a\u{0001}b", String(repeating: "x", count: 81)] {
    reject("Invalid name cannot crowd the editor") { _ = try BoostContent(name: name, host: "example.test").validated() }
}
for (css, js) in [(String(repeating: "x", count: 65537), ""), ("", String(repeating: "x", count: 32769))] {
    reject("Oversized custom code is rejected before persistence") { _ = try BoostContent(name: "Large", host: "example.test", css: css, javascript: js).validated() }
}
check(try BoostContent(name: "Boundary", host: "example.test", css: String(repeating: "x", count: 65536), javascript: String(repeating: "x", count: 32768)).validated().css.utf8.count == 65536, "Code at both byte limits is retained")
for selectors in [[""], ["p\nq"], [String(repeating: "x", count: 1025)], Array(repeating: "p", count: 65)] {
    reject("Invalid hidden-element list is rejected") { _ = try SiteBoost(content: content, hiddenSelectors: selectors).validated() }
}
var duplicateSelectors = boost; duplicateSelectors.hiddenSelectors = ["#ad", "#ad"]
check(try duplicateSelectors.validated().hiddenSelectors == ["#ad"], "Repeated hidden selectors do not consume Undo history")
check(!boost.isJavaScriptApproved, "Custom code starts unapproved")
boost.approvedJavaScriptHash = boost.scriptHash
check(boost.isJavaScriptApproved, "An exact saved code approval is recognized")
var changed = boost; changed.content.javascript += " "
check(try !changed.isJavaScriptApproved && changed.validated().approvedJavaScriptHash == nil, "Even whitespace edits invalidate exact code approval")
changed = boost; changed.content.host = "other.test"
check(!changed.isJavaScriptApproved, "A site change invalidates JavaScript approval")
changed = boost; changed.id = otherID
check(!changed.isJavaScriptApproved, "A copied identity cannot reuse the old approval")
var variant = boost; variant.id = otherID; variant.content.name = "Other look"; variant.approvedJavaScriptHash = nil
let variants = try BoostCatalog([boost]).upserting(variant)
check(variants.count == 2 && variants[0].enabled == false && variants[1].enabled, "Enabling a saved variant disables the other same-site variant atomically")
check(BoostCatalog(variants).matching(URL(string: "https://example.test/")!)?.id == otherID, "The newly enabled look is selected")
var off = variant; off.enabled = false
check(BoostCatalog(try BoostCatalog(variants).upserting(off)).matching(URL(string: "https://example.test/")!) == nil, "Turning off the selected look restores original site behavior")
var visual = boost; visual.content.css += "p{color:red}"; visual.content.name = "Renamed"
check(try BoostCatalog([boost]).upserting(visual).first?.isJavaScriptApproved == true, "Visual-only edits preserve the exact existing JavaScript approval")
check(try BoostCatalog([boost]).upserting(changed).last?.isJavaScriptApproved == false, "A new identity never inherits approval")
let repaired = BoostCatalog([boost, boost, variant, SiteBoost(content: BoostContent(name: "Bad", host: "*.bad.test"))]).entries
check(repaired.count == 2 && repaired.first?.enabled == true && repaired.last?.enabled == false, "Repair skips identical/invalid entries and deterministically keeps one enabled look")
var collision = boost; collision.content.name = "Different recovered content"
let colliding = BoostCatalog([boost, collision]).entries
check(colliding.count == 2 && colliding[0].id == id && colliding[1].id != id && colliding[1].approvedJavaScriptHash == nil, "Different colliding records survive under a fresh unapproved identity")
let portable = try boost.portableData()
let portableObject = try JSONSerialization.jsonObject(with: portable) as! [String: Any]
check(portableObject["javascript"] == nil && portableObject["approvedJavaScriptHash"] == nil && portableObject["id"] == nil && portableObject["enabled"] == nil && portableObject["version"] as? Int == 1, "Appearance sharing omits executable code, approval and identity")
let imported = try SiteBoost.importing(portable)
check(imported.id != boost.id && !imported.enabled && imported.content.javascript.isEmpty && !imported.isJavaScriptApproved && imported.hiddenSelectors == boost.hiddenSelectors && imported.content.css == boost.content.css, "Appearance import creates a disabled fresh record with the intended styles and no script")
for data in [Data("{}".utf8), Data("{\"version\":99}".utf8), Data(repeating: 32, count: 1048577)] {
    reject("Invalid or unsupported portable data is rejected") { _ = try SiteBoost.importing(data) }
}
var many: [SiteBoost] = (0..<65).map { SiteBoost(content: BoostContent(name: "Look \($0)", host: "s\($0).test")) }
check(BoostCatalog(many).entries.count == 64, "Recovered catalogs stop at 64 definitions")
reject("New records cannot exceed the catalog capacity") { _ = try BoostCatalog(Array(many.prefix(64))).upserting(many[64]) }
many = (0..<20).map { SiteBoost(content: BoostContent(name: "Large \($0)", host: "s\($0).test", css: String(repeating: "x", count: 65536))) }
check(BoostCatalog(many).entries.count < 20, "Aggregate catalog payload is bounded before page matching")
var loaded = BoostCatalog(many).entries
reject("An edit/add cannot exceed the aggregate byte budget") { _ = try BoostCatalog(loaded).upserting(many.last!) }
loaded.removeLast()
check(try BoostCatalog(loaded).upserting(many.last!).count == loaded.count + 1, "Freeing catalog bytes permits the same definition")

var legacy = BrowserDocument(); let legacyData = try JSONEncoder().encode(legacy)
let old = try JSONDecoder().decode(BrowserDocument.self, from: legacyData)
check(old.library.siteBoosts == nil && old.preferences.boostsEnabled == nil, "Existing format3 documents decode with empty optional Boost settings")
var library = BrowserLibrary(); library.siteBoosts = [boost]
var incoming = BrowserLibrary(); incoming.siteBoosts = [collision]
library.mergePreservingRecords(incoming)
check(library.siteBoosts?.count == 2 && library.siteBoosts?.last?.id != id && library.siteBoosts?.last?.isJavaScriptApproved == false, "Duplicate library merge preserves different customizations without reusing approval")
let profile = BrowserProfile(name: "Work")
legacy.profiles = [.defaultProfile, profile]
legacy.profileLibraries = [ProfileLibrary(profileID: BrowserProfile.defaultID, library: library), ProfileLibrary(profileID: profile.id)]
legacy.preferences.boostsEnabled = false
try legacy.repairProfiles()
let root = FileManager.default.temporaryDirectory.appendingPathComponent("Alcove.BoostCore.\(UUID())")
defer { try? FileManager.default.removeItem(at: root) }
let sealedURL = root.appendingPathComponent("metadata.sealed")
let vault = MetadataStore(url: sealedURL, key: SymmetricKey(size: .bits256))
try vault.save(legacy)
let recovered = try vault.load(BrowserDocument.self)!
check(recovered.formatVersion == 3 && recovered.library(for: BrowserProfile.defaultID).siteBoosts?.first?.isJavaScriptApproved == true && recovered.library(for: profile.id).siteBoosts == nil && recovered.preferences.boostsEnabled == false, "Encrypted metadata roundtrip preserves profile ownership and exact local approval")
let ciphertext = try Data(contentsOf: sealedURL)
check(ciphertext.range(of: Data("window.counter".utf8)) == nil && ciphertext.range(of: Data("Quiet Café".utf8)) == nil, "Profile customization names and code do not appear in plaintext on disk")
var repairedOwner = BrowserDocument(profiles: [BrowserProfile(id: BrowserProfile.zeroID, name: "Recovered")], profileLibraries: [ProfileLibrary(profileID: BrowserProfile.zeroID, library: library)])
try repairedOwner.repairProfiles()
let reassigned = repairedOwner.profileLibraries!.first { $0.profileID != BrowserProfile.defaultID }!
check(reassigned.profileID != BrowserProfile.zeroID && reassigned.library.siteBoosts?.count == 2 && reassigned.library.siteBoosts?.allSatisfy { !$0.isJavaScriptApproved } == true, "Repairing an invalid profile identity keeps its styles but requires fresh code approval")
exit(failures == 0 ? 0 : 1)
