import AppKit
import WebKit
import CryptoKit
import Combine
import BrowserCore

enum SiteSearchStoreCheckError: Error { case failed, fixtureMissing }
@main struct SiteSearchStoreChecks {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited); setbuf(stdout, nil)
        var failures = 0, fixtures: [SiteSearchStoreFixture] = []
        defer { fixtures.forEach { $0.close() } }
        func fixture(_ isPrivate: Bool = false) throws -> SiteSearchStoreFixture { let f = try SiteSearchStoreFixture(isPrivate: isPrivate); fixtures.append(f); return f }
        func check(_ value: Bool, _ name: String) { print("\(value ? "PASS" : "FAIL"): \(name)"); if !value { failures += 1 } }
        func rejects(_ name: String, _ action: () throws -> Void) { do { try action(); check(false, name) } catch { check(true, name) } }
        guard let origin = ProcessInfo.processInfo.environment["ALCOVE_SITE_SEARCH_FIXTURE_URL"], let fixtureURL = URL(string: origin), fixtureURL.host == "127.0.0.1", fixtureURL.port != nil else { throw SiteSearchStoreCheckError.fixtureMissing }
        let site = SiteSearch(name: "Fixture Search", keyword: "find", template: origin + "search?q=%s")
        let f = try fixture(), store = f.store
        try store.saveSiteSearch(site)
        let saved = try MetadataStore(url: store.sessionURL, key: f.key).load(BrowserDocument.self)!
        check(saved.preferences.siteSearches?.contains(site) == true && store.siteSearchCatalog.preferredMatch("find") == site, "A normal catalog edit is encrypted before it becomes available")
        check(!String(decoding: try Data(contentsOf: store.sessionURL), as: UTF8.self).contains("Fixture Search"), "Custom search configuration is not plaintext on disk")
        let reopened = BrowserStore(dataRoot: f.root, keyProvider: { _ in f.key })
        check(reopened.siteSearchCatalog.preferredMatch("find") == site, "A normal relaunch restores its custom shortcut")
        reopened.shutdown()
        var duplicate = site; duplicate.id = UUID(); duplicate.keyword = " FIND "
        rejects("Duplicate shortcut edits do not replace the existing provider") { try store.saveSiteSearch(duplicate) }
        check(store.siteSearchCatalog.preferredMatch("find") == site, "Failed validation keeps the live provider unchanged")
        store.showCommand(new: false)
        let count = store.space.tabs.count
        check(store.activateCommandSiteSearch(site) && store.commandSiteSearch == site && store.command.isEmpty, "Selecting a site enters query mode without navigating")
        check(store.space.tabs.count == count && f.web.requests.isEmpty, "Activation creates no tab and sends no request")
        store.navigate("")
        check(store.commandVisible && store.commandSiteSearch == site && store.space.tabs.count == count && f.web.requests.isEmpty, "An empty site query keeps editing without creating an empty tab")
        store.command = "cats & café"; store.navigate(store.command)
        check(f.web.requests.last?.url?.absoluteString == origin + "search?q=cats%20%26%20caf%C3%A9", "A submitted primary query reaches its configured site with exact escaping")
        check(!store.commandVisible && store.commandSiteSearch == nil && store.commandContext == nil, "Completed navigation clears the command's selected provider and context")
        store.showCommand(); _ = store.activateCommandSiteSearch(site); store.leaveCommandSiteSearch(restoreKeyword: true)
        check(store.commandSiteSearch == nil && store.command == "find", "Empty-query Backspace returns to the shortcut text")
        _ = store.activateCommandSiteSearch(site); store.command = "keep this query"; store.leaveCommandSiteSearch(restoreKeyword: false)
        check(store.command == "keep this query" && store.commandSiteSearch == nil, "Clearing a site preserves the typed query")
        store.dismissCommand()
        check(!store.commandVisible && store.command.isEmpty && !store.commandOpensNewTab, "Cancellation drops the draft without creating a tab")
        let previousID = store.focusedID
        store.showCommand(new: true); _ = store.activateCommandSiteSearch(site); store.command = "new tab"; store.navigate(store.command)
        check(store.focusedID != previousID && store.space.tabs.count == count + 1 && store.selectedTab?.url == origin + "search?q=new%20tab", "Command-T creates a new tab only for valid explicit search submission")
        var redundantPublications = 0
        let publicationToken = store.objectWillChange.sink { redundantPublications += 1 }
        store.dismissCommand()
        check(redundantPublications == 0, "Dismissing an already clear command does not publish redundant browser redraws")
        publicationToken.cancel()

        let split = try fixture(), splitStore = split.store
        try splitStore.saveSiteSearch(site)
        let leftID = splitStore.selectedID!, rightID = splitStore.newTab()
        let right = split.anotherWeb(rightID)
        splitStore.session.spaces[splitStore.spaceIndex].selected = leftID; splitStore.splitID = rightID; splitStore.activePaneID = rightID
        right.fixtureURL = URL(string: "http://127.0.0.1:9/right")!
        splitStore.showCommand()
        check(splitStore.command == "http://127.0.0.1:9/right", "Command-L displays the actual focused split pane's URL")
        _ = splitStore.activateCommandSiteSearch(site); splitStore.command = "right query"; splitStore.navigate(splitStore.command)
        check(right.requests.last?.url?.absoluteString == origin + "search?q=right%20query" && split.web.requests.isEmpty, "Site search navigates only the focused split pane")
        let peek = split.anotherWeb(UUID())
        splitStore.peekPages[.primary] = PeekState(web: peek, profileID: split.profile, spaceID: splitStore.space.id)
        peek.fixtureURL = URL(string: "http://127.0.0.1:9/peek")!
        splitStore.showCommand()
        check(splitStore.command == "http://127.0.0.1:9/peek", "Command-L displays its visible Peek's URL")
        _ = splitStore.activateCommandSiteSearch(site); splitStore.command = "peek query"; splitStore.navigate(splitStore.command)
        check(peek.requests.last?.url?.absoluteString == origin + "search?q=peek%20query" && right.requests.count == 1, "Existing-page command search targets its Peek instead of a covered parent")
        splitStore.showCommand(); _ = splitStore.activateCommandSiteSearch(site); splitStore.command = "stale peek"
        let peekContext = splitStore.commandContext!
        splitStore.closePrimaryPeek(); let requests = right.requests.count
        splitStore.navigate(splitStore.command)
        check(!splitStore.matchesSearchInputContext(peekContext) && right.requests.count == requests && splitStore.commandError != nil, "Closing a Peek during input cannot redirect its draft into the parent")
        splitStore.dismissCommand()
        splitStore.showCommand(); _ = splitStore.activateCommandSiteSearch(site); splitStore.command = "old Space draft"
        let oldContext = splitStore.commandContext!, oldSpace = splitStore.space.id
        let nextProfile = try splitStore.createProfile(name: "Another search account")
        splitStore.namedDataStores[nextProfile] = .nonPersistent()
        check(!splitStore.matchesSearchInputContext(oldContext) && !splitStore.commandVisible && splitStore.command.isEmpty && splitStore.commandSiteSearch == nil, "Switching Space/profile clears the old account's search draft")
        splitStore.selectSpace(oldSpace)
        check(!splitStore.commandVisible && splitStore.command.isEmpty, "Returning to a Space does not resurrect its cancelled query")

        let changed = try fixture(), changedStore = changed.store
        try changedStore.saveSiteSearch(site); changedStore.showCommand(); _ = changedStore.activateCommandSiteSearch(site); changedStore.command = "kept query"
        var edited = site; edited.template = origin + "other?q=%s"; try changedStore.saveSiteSearch(edited)
        changedStore.navigate(changedStore.command)
        check(changed.web.requests.isEmpty && changedStore.command == "kept query" && changedStore.commandError != nil, "Editing a selected endpoint cannot silently redirect an open query")
        rejects("A removed provider is not replaced by a default web search") { try changedStore.removeSiteSearch(site.id); _ = try changedStore.resolveSearchInput("private query", selection: edited) }
        check(changedStore.siteSearchCatalog.preferredMatch("find") == nil && changedStore.views[changedStore.focusedID!] === changed.web, "Catalog changes invalidate matching without replacing the mounted page")
        changedStore.preferences.siteSearches = [site]
        check(changedStore.siteSearchCatalog.preferredMatch("find") == site, "Replacing preferences refreshes the local catalog")
        changedStore.preferences.siteSearches = []
        check(changedStore.siteSearchCatalog.entries.isEmpty, "An explicit empty preference does not fall back to presets")
        var disabled = site; disabled.enabled = false; changedStore.preferences.siteSearches = [disabled]
        rejects("Disabling a selected shortcut blocks the old enabled snapshot") { _ = try changedStore.resolveSearchInput("not a fallback search", selection: site) }
        check(changedStore.siteSearchCatalog.preferredMatch("find") == nil, "Disabled configuration is immediately absent from matching")

        let blocked = try fixture(), blockedStore = blocked.store
        let oldBytes = try Data(contentsOf: blockedStore.sessionURL), oldEntries = blockedStore.siteSearchCatalog.entries
        blockedStore.savingEnabled = false
        rejects("Locked metadata rejects provider edits") { try blockedStore.saveSiteSearch(site) }
        let lockedBytes = try Data(contentsOf: blockedStore.sessionURL)
        check(blockedStore.siteSearchCatalog.entries == oldEntries && lockedBytes == oldBytes, "A locked edit preserves live configuration and previous ciphertext")
        blockedStore.savingEnabled = true; blockedStore.clearingData = true
        rejects("A pending profile data operation cannot be overwritten by a settings edit") { try blockedStore.saveSiteSearch(site) }
        blockedStore.clearingData = false
        let badDestination = blocked.root.appendingPathComponent("blocked-destination")
        try FileManager.default.createDirectory(at: badDestination, withIntermediateDirectories: false)
        blockedStore.vault = MetadataStore(url: badDestination, key: blocked.key)
        rejects("A failed encrypted save is reported before publication") { try blockedStore.saveSiteSearch(site) }
        let failedBytes = try Data(contentsOf: blockedStore.sessionURL)
        check(blockedStore.siteSearchCatalog.entries == oldEntries && failedBytes == oldBytes && !blockedStore.savingEnabled, "A failed save preserves the old provider and bytes for retry")
        let privateFixture = try fixture(true), privateStore = privateFixture.store
        try privateStore.saveSiteSearch(site)
        check(privateStore.siteSearchCatalog.preferredMatch("find") == site && privateFixture.reads.count == 0 && !FileManager.default.fileExists(atPath: privateStore.sessionURL.path), "Private provider edits never read keys or create normal metadata")
        for entry in privateStore.siteSearchCatalog.entries { try privateStore.removeSiteSearch(entry.id) }
        check(privateStore.siteSearchCatalog.entries.isEmpty && privateFixture.reads.count == 0, "Removing private defaults stays empty and temporary")
        privateStore.shutdown()
        rejects("A closed owner cannot accept a late settings edit") { try privateStore.saveSiteSearch(site) }
        let privateChange = try fixture(true), ps = privateChange.store
        ps.showCommand(); _ = ps.activateCommandSiteSearch(ps.siteSearchCatalog.entries[0]); ps.command = "private Space draft"
        var privateCandidate = ps.makeDocument(); let privateSpace = Space(name: "Another private Space")
        privateCandidate.session.spaces.append(privateSpace); privateCandidate.session.selectedSpace = privateSpace.id
        try ps.commitQuickDocument(privateCandidate)
        check(!ps.commandVisible && ps.command.isEmpty && ps.commandContext == nil && privateChange.reads.count == 0, "A private Space-changing transaction clears its navigation draft without persistence")

        let quick = try fixture(), qs = quick.store
        try qs.saveSiteSearch(site); let spaceA = qs.space.id
        let b = try qs.createProfile(name: "Compact search account"); qs.namedDataStores[b] = .nonPersistent()
        let quickID = try qs.openQuickPage(profileID: b)
        let quickWeb = quick.anotherWeb(quickID, profile: b)
        qs.selectSpace(spaceA)
        let qContext = qs.searchInputContext(quickID: quickID)!, primaryContext = qs.searchInputContext()!
        let state = QuickBrowseWindowState(); state.requestLocation(currentURL: quickWeb.fixtureURL.absoluteString, context: qContext)
        check(state.activateSiteSearch(site, context: qContext) && state.addressText.isEmpty && state.isEditingAddress, "A compact field can enter site mode with its own captured context")
        state.addressText = "compact query"
        try qs.navigateForegroundQuickPage(quickID, input: state.addressText, selection: state.siteSearch, context: state.locationContext)
        check(quickWeb.requests.last?.url?.absoluteString == origin + "search?q=compact%20query" && qs.activeProfileID != b && quick.web.requests.isEmpty, "Compact search uses its own profile despite another active primary account")
        rejects("A primary context cannot authorize compact search in another account") { try qs.navigateForegroundQuickPage(quickID, input: "wrong context", selection: site, context: primaryContext) }
        let quickPeek = quick.anotherWeb(UUID(), profile: b)
        qs.peekPages[.quick(quickID)] = PeekState(web: quickPeek, profileID: b, spaceID: nil)
        rejects("A new compact Peek invalidates the previous page input context") { try qs.navigateForegroundQuickPage(quickID, input: "old input", selection: site, context: qContext) }
        let peekScope = qs.searchInputContext(quickID: quickID)!
        try qs.navigateForegroundQuickPage(quickID, input: "own preview", selection: site, context: peekScope)
        check(quickPeek.requests.last?.url?.absoluteString == origin + "search?q=own%20preview" && quickWeb.requests.count == 1, "Compact Peek search leaves its parent page untouched")
        state.cancelLocation(currentURL: "http://127.0.0.1:9/now")
        check(state.siteSearch == nil && state.locationContext == nil && !state.isEditingAddress, "Cancelling compact input clears its site and captured account")
        state.requestLocation(currentURL: "", context: peekScope); _ = state.activateSiteSearch(site, context: peekScope); state.showFind()
        check(state.siteSearch == nil && state.locationContext == nil, "Switching to compact Find cannot retain a navigation draft")
        let foreignTab = qs.session.spaces.first { $0.effectiveProfileID == b }!.tabs[0].id
        qs.splitID = foreignTab; qs.activePaneID = foreignTab
        check(qs.searchInputContext() == nil, "A stale split id from another profile cannot authorize primary search input")
        if failures > 0 { throw SiteSearchStoreCheckError.failed }
    }
}
