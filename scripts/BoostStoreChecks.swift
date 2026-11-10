import AppKit
import WebKit
import JavaScriptCore
import CryptoKit
import BrowserCore

enum BoostStoreCheckError: Error { case failed }
@main struct BoostStoreChecks {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited); setbuf(stdout, nil)
        var failures = 0, fixtures: [SiteSearchStoreFixture] = []
        var windows: [NSWindow] = []
        defer { windows.forEach { $0.contentView = nil }; fixtures.forEach { $0.close() } }
        func fixture(_ privateMode: Bool = false) throws -> SiteSearchStoreFixture {
            let value = try SiteSearchStoreFixture(isPrivate: privateMode); fixtures.append(value); return value
        }
        func check(_ value: Bool, _ name: String) { print("\(value ? "PASS" : "FAIL"): \(name)"); if !value { failures += 1 } }
        func rejects(_ name: String, _ body: () throws -> Void) { do { try body(); check(false, name) } catch { check(true, name) } }
        func attach(_ f: SiteSearchStoreFixture) -> NSWindow {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = f.web; windows.append(window); return window
        }
        let f = try fixture(), store = f.store
        var boost = SiteBoost(content: BoostContent(name: "Owned look", host: "127.0.0.1", appearance: BoostAppearance(background: "#123456"), javascript: "window.fixtureRan = true;"))
        boost.approvedJavaScriptHash = boost.scriptHash
        try store.saveBoost(boost, profileID: f.profile)
        var current = store.boostCatalog(profileID: f.profile).entries[0]
        check(!current.isJavaScriptApproved, "Creating a record cannot manufacture code approval")
        let saved = try MetadataStore(url: store.sessionURL, key: f.key).load(BrowserDocument.self)!
        check(saved.library(for: f.profile).siteBoosts?.first?.content.name == "Owned look" && saved.library(for: BrowserProfile.defaultID).siteBoosts == nil, "A saved look is encrypted under only its selected profile")
        check(!String(decoding: try Data(contentsOf: store.sessionURL), as: UTF8.self).contains("fixtureRan"), "Custom JavaScript is not plaintext on disk")
        let reopened = BrowserStore(dataRoot: f.root, keyProvider: { _ in f.key })
        check(reopened.boostCatalog(profileID: f.profile).entries.first == current, "Relaunch restores the same local definition")
        reopened.shutdown()
        let window = attach(f)
        let source = try BoostEditSource(store: store, web: f.web)
        let approval = BoostJavaScriptRequest(source: source, boost: current)
        try store.approveBoostJavaScript(approval)
        current = store.boostCatalog(profileID: f.profile).entries[0]
        check(current.isJavaScriptApproved && f.web.requests.isEmpty, "Explicit approval saves consent without running code or reloading the live form")
        rejects("An approval snapshot is consumed once") { try store.approveBoostJavaScript(approval) }
        let approvedDisk = try MetadataStore(url: store.sessionURL, key: f.key).load(BrowserDocument.self)!
        check(approvedDisk.library(for: f.profile).siteBoosts?.first?.isJavaScriptApproved == true, "Exact local consent survives encrypted persistence")
        let editBase = current
        try store.setBoostEnabled(current.id, profileID: f.profile, enabled: false)
        let zapBase = store.boostCatalog(profileID: f.profile).entries[0]
        try store.addBoostZap(current.id, profileID: f.profile, selector: "#ad", expected: zapBase)
        var edit = editBase; edit.content.name = "Renamed look"; edit.enabled = true; edit.hiddenSelectors = []
        try store.saveBoost(edit, profileID: f.profile, expected: editBase)
        current = store.boostCatalog(profileID: f.profile).entries[0]
        check(current.content.name == "Renamed look" && !current.enabled && current.hiddenSelectors == ["#ad"] && current.isJavaScriptApproved, "Saving an editor draft preserves newer toggles, hidden elements and exact code consent")
        rejects("A stale editor cannot replace a newer content revision") { try store.saveBoost(editBase, profileID: f.profile, expected: editBase) }
        rejects("A stale picker snapshot cannot add another selector") { try store.addBoostZap(current.id, profileID: f.profile, selector: "#other", expected: zapBase) }
        try store.undoBoostZap(current.id, profileID: f.profile)
        check(store.boostCatalog(profileID: f.profile).entries[0].hiddenSelectors.isEmpty, "Undo removes the last saved hidden element")
        current = store.boostCatalog(profileID: f.profile).entries[0]
        let beforeCodeEdit = current
        current.content.javascript += "\nwindow.changed = true;"
        try store.saveBoost(current, profileID: f.profile, expected: beforeCodeEdit)
        check(!store.boostCatalog(profileID: f.profile).entries[0].isJavaScriptApproved, "Editing code clears the old approval before future page loads")
        rejects("A new-record save cannot silently overwrite an existing record") { try store.saveBoost(current, profileID: f.profile) }
        var invalidCode = current; invalidCode.content.javascript = "});window.escaped=true;(()=>{"
        rejects("Invalid custom JavaScript is rejected before persistence") { try store.saveBoost(invalidCode, profileID: f.profile, expected: store.boostCatalog(profileID: f.profile).entries[0]) }
        check(store.boostCatalog(profileID: f.profile).entries[0].content.javascript == current.content.javascript, "Rejected syntax leaves the previous custom code intact")
        try store.setBoostsEnabled(false)
        let globallyOff = try MetadataStore(url: store.sessionURL, key: f.key).load(BrowserDocument.self)!
        check(globallyOff.preferences.boostsEnabled == false && store.preferences.boostsEnabled == false, "Global off persists before it is published")
        let imported = try SiteBoost.importing(current.portableData())
        try store.saveBoost(imported, profileID: BrowserProfile.defaultID)
        check(store.boostCatalog(profileID: BrowserProfile.defaultID).entries.first?.enabled == false && store.boostCatalog(profileID: f.profile).entries.count == 1, "Import can target another profile without enabling a script or altering the source profile")

        let changedSource = try fixture(), cs = changedSource.store
        _ = attach(changedSource)
        try cs.saveBoost(boost, profileID: changedSource.profile)
        let sourceBefore = try BoostEditSource(store: cs, web: changedSource.web)
        let oldRequest = BoostJavaScriptRequest(source: sourceBefore, boost: cs.boostCatalog(profileID: changedSource.profile).entries[0])
        cs.invalidateDocumentIdentity(for: changedSource.web)
        rejects("Same-URL document replacement invalidates pending approval") { try cs.approveBoostJavaScript(oldRequest) }
        let freshSource = try BoostEditSource(store: cs, web: changedSource.web)
        let editedRequest = BoostJavaScriptRequest(source: freshSource, boost: cs.boostCatalog(profileID: changedSource.profile).entries[0])
        let oldCode = cs.boostCatalog(profileID: changedSource.profile).entries[0]
        var newCode = oldCode; newCode.content.javascript += "\nwindow.newer = true;"
        try cs.saveBoost(newCode, profileID: changedSource.profile, expected: oldCode)
        rejects("Changing code cannot reuse a prompt for the old script") { try cs.approveBoostJavaScript(editedRequest) }
        let closedRequest = BoostJavaScriptRequest(source: try BoostEditSource(store: cs, web: changedSource.web), boost: cs.boostCatalog(profileID: changedSource.profile).entries[0])
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: changedSource.web.window!)
        rejects("Closing the source window invalidates a late approval") { try cs.approveBoostJavaScript(closedRequest) }
        check(!cs.boostCatalog(profileID: changedSource.profile).entries[0].isJavaScriptApproved, "Expired approval never becomes live consent")
        check(source.window === window && source.profileID == f.profile, "Editor source preserves the actual native window and profile")

        let locked = try fixture(), ls = locked.store
        let originalBytes = try Data(contentsOf: ls.sessionURL)
        ls.savingEnabled = false
        rejects("Locked metadata rejects Boost creation") { try ls.saveBoost(boost, profileID: locked.profile) }
        ls.savingEnabled = true; ls.clearingData = true
        rejects("A pending profile operation blocks Boost edits") { try ls.saveBoost(boost, profileID: locked.profile) }
        ls.clearingData = false
        rejects("A nonexistent profile cannot receive a customization") { try ls.saveBoost(boost, profileID: UUID()) }
        let badDestination = locked.root.appendingPathComponent("directory-instead-of-file")
        try FileManager.default.createDirectory(at: badDestination, withIntermediateDirectories: false)
        ls.vault = MetadataStore(url: badDestination, key: locked.key)
        rejects("Failed encryption/file writes are reported before publication") { try ls.saveBoost(boost, profileID: locked.profile) }
        check(try ls.boostCatalog(profileID: locked.profile).entries.isEmpty && Data(contentsOf: ls.sessionURL) == originalBytes && !ls.savingEnabled, "Failed writes preserve the old catalog and original ciphertext")
        let p = try fixture(true), ps = p.store
        check(ps.boostCatalog(profileID: BrowserProfile.defaultID).entries.isEmpty, "Private browsing begins with no normal Boosts or approvals")
        try ps.saveBoost(boost, profileID: BrowserProfile.defaultID); try ps.setBoostsEnabled(false)
        check(ps.boostCatalog(profileID: BrowserProfile.defaultID).entries.count == 1 && ps.preferences.boostsEnabled == false && p.reads.count == 0 && !FileManager.default.fileExists(atPath: ps.sessionURL.path), "Private edits and global off remain temporary without requesting keys or writing files")
        rejects("Private settings cannot address a normal profile identity") { try ps.saveBoost(boost, profileID: f.profile) }
        try ps.removeBoost(boost.id, profileID: BrowserProfile.defaultID)
        check(ps.boostCatalog(profileID: BrowserProfile.defaultID).entries.isEmpty && store.boostCatalog(profileID: f.profile).entries.count == 1, "Deleting a private definition leaves the normal profile intact")
        ps.shutdown()
        rejects("A shut-down owner rejects late writes") { try ps.saveBoost(boost, profileID: BrowserProfile.defaultID) }
        let removed = store.boostCatalog(profileID: f.profile).entries[0]
        try store.removeBoost(removed.id, profileID: f.profile)
        rejects("Saving an old draft cannot resurrect a deleted Boost") { try store.saveBoost(removed, profileID: f.profile, expected: removed) }

        // Compile-only validation must neither execute code nor let its declarations escape the inner scope.
        _ = try BoostScript.validatedBody("throw new Error('compile only');")
        check(true, "Syntax validation compiles without executing user code")
        for code in ["});globalThis.escaped=true;(()=>{", "}\nwindow.escaped=true;\n{", "/* unterminated", "const x = ;"] {
            rejects("Body escape or malformed syntax is rejected before native execution") { _ = try BoostScript.validatedBody(code) }
        }
        let context = JSContext()!
        context.evaluateScript("var location={protocol:'https:',hostname:'example.test'}; var window=globalThis; Object.defineProperty(globalThis,'__alcoveBoostPageNonce_v1',{value:'document-one',writable:false,configurable:false});")
        let constructor = context.evaluateScript("Object.getPrototypeOf(async function(){}).constructor")!
        func run(_ code: String, host: String = "example.test", nonce: String = "document-one") throws {
            let body = try BoostScript.validatedBody(code)
            let fn = constructor.construct(withArguments: ["__alcoveHost", "__alcoveNonce", body])!
            _ = fn.call(withArguments: [host, nonce])
        }
        try run("window.good=7;")
        check(context.objectForKeyedSubscript("good")?.toInt32() == 7, "A parsed script executes inside its approved host and document")
        try run("window.wrong=1;", host: "wrong.test")
        try run("window.oldDocument=1;", nonce: "old-document")
        try run("function location(){}; function __alcoveHost(){}; window.shadowed=1;", host: "wrong.test")
        check(context.objectForKeyedSubscript("wrong")!.isUndefined && context.objectForKeyedSubscript("oldDocument")!.isUndefined && context.objectForKeyedSubscript("shadowed")!.isUndefined, "Wrong hosts, stale document nonces and inner hoisted declarations cannot bypass the outer guard")
        _ = try BoostScript.validatedBody("await Promise.resolve(); window.afterAwait=true;")
        check(true, "Top-level await remains supported by the compiled async script body")
        if failures != 0 { throw BoostStoreCheckError.failed }
    }
}
