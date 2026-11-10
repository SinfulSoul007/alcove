import AppKit
import WebKit
import CryptoKit
import BrowserCore

enum LinkRoutingCheckError: Error { case failed }
@MainActor final class RoutingUncommittedWeb: WKWebView {
    override var url: URL? { nil }
    override func load(_ request: URLRequest) -> WKNavigation? { nil }
}
@main struct LinkRoutingStoreChecks {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited); setbuf(stdout, nil)
        var failures = 0, fixtures: [SiteSearchStoreFixture] = []
        defer { fixtures.forEach { $0.close() } }
        func fixture(_ privateMode: Bool = false) throws -> SiteSearchStoreFixture { let f = try SiteSearchStoreFixture(isPrivate: privateMode); fixtures.append(f); return f }
        func check(_ value: Bool, _ name: String) { print("\(value ? "PASS" : "FAIL"): \(name)"); if !value { failures += 1 } }
        func rejects(_ name: String, _ action: () throws -> Void) { do { try action(); check(false,name) } catch { check(true,name) } }
        func same(_ a: BrowserDocument, _ b: BrowserDocument) throws -> Bool {
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            return try encoder.encode(a) == encoder.encode(b)
        }
        func addSpace(_ f: SiteSearchStoreFixture, _ name: String, profile: UUID? = nil) throws -> UUID {
            var doc = f.store.makeDocument(); var space = Space(name: name, tabs: []); space.profileID = profile ?? f.profile
            doc.session.spaces.append(space); try f.store.commitQuickDocument(doc); return space.id
        }
        func peek(_ f: SiteSearchStoreFixture, context: PeekContext = .primary, profile: UUID? = nil, path: String = "peek") -> SiteSearchProbeWeb {
            let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
            let web = SiteSearchProbeWeb(frame: f.web.frame, configuration: configuration); web.fixtureURL = URL(string: "http://127.0.0.1:9/" + path)!
            f.store.peekPages[context] = PeekState(web: web, profileID: profile ?? f.profile, spaceID: context == .primary ? f.store.space.id : nil)
            return web
        }
        func archived(_ f: SiteSearchStoreFixture, origin: UUID?, quick: Bool = false) throws -> UUID {
            var doc = f.store.makeDocument(), records = doc.library(for: f.profile)
            var tab = BrowserCore.Tab(title: "Owned archive", url: "http://127.0.0.1:9/archive"); tab.archivedSpaceID = origin; tab.archiveSource = quick ? "quickBrowse" : nil
            records.archive.insert(tab,at:0); doc.setLibrary(records,for:f.profile); try f.store.commitQuickDocument(doc); return tab.id
        }
        let url = URL(string:"http://127.0.0.1:9/route")!, f = try fixture(), s = f.store
        check(s.effectiveDefaultLinkDestination == .quickBrowse && s.linkRuleCatalog.entries.isEmpty && s.canEditLinkRules, "Legacy default retains compact links without creating routes")
        s.preferences.quickBrowseExternalLinks = false
        check(s.effectiveDefaultLinkDestination == .mostRecentSpace, "Legacy opt-out maps to recent Space")
        let target = try addSpace(f,"Destination"), first = LinkRule(pattern:"/route",destination:.space(target))
        try s.saveLinkRule(first)
        var later = LinkRule(pattern:"127.0.0.1",destination:.quickBrowse)
        try s.saveLinkRule(later); try s.moveLinkRule(later.id,by:-1)
        check(s.linkRuleCatalog.entries.map(\.id) == [later.id,first.id] && s.linkRuleCatalog.matching(url)?.id == later.id, "Visible route order determines the first match")
        later.enabled = false; try s.saveLinkRule(later)
        check(try s.linkDecision(for:url).destination == .space(spaceID:target,profileID:f.profile), "Disabled routes yield to the next enabled route")
        try s.removeLinkRule(later.id); try s.setDefaultLinkDestination(.space(target))
        let saved = try MetadataStore(url:s.sessionURL,key:f.key).load(BrowserDocument.self)!
        check(saved.preferences.linkRules == [first] && saved.preferences.linkDefaultDestination == .space(target) && saved.preferences.quickBrowseExternalLinks == false, "Rules and mirrored default are committed encrypted before publication")
        check(!String(decoding:try Data(contentsOf:s.sessionURL),as:UTF8.self).contains("/route"), "Route expressions are not plaintext metadata")
        let reopened = BrowserStore(dataRoot:f.root,keyProvider:{_ in f.key})
        check(reopened.linkRuleCatalog.entries == [first] && reopened.effectiveDefaultLinkDestination == .space(target), "Relaunch restores rule order and selected default"); reopened.shutdown()
        try s.removeLinkRule(first.id); try s.setDefaultLinkDestination(.quickBrowse)
        check(s.linkRuleCatalog.entries.isEmpty && s.preferences.quickBrowseExternalLinks == true, "Removing the final route stays empty and compact default mirrors legacy controls")
        s.preferences.linkRules = [first]
        check(s.linkRuleCatalog.matching(url) == first, "Replacing preferences invalidates the cached catalog")
        s.preferences.linkRules = []
        let a = s.space.id, b = try addSpace(f,"Most recent")
        s.selectSpace(b); s.selectSpace(a); try s.setDefaultLinkDestination(.mostRecentSpace)
        check(s.session.lastUsedSpaces?[f.profile] == a, "Explicit Space selection records its owning profile's recent hint")
        var recentDoc = s.makeDocument(); recentDoc.session.lastUsedSpaces = [f.profile:b]; try s.commitQuickDocument(recentDoc)
        check(try s.linkDecision(for:url).destination == .space(spaceID:b,profileID:f.profile), "Recent destination uses the selected profile's durable hint")
        let other = try s.createProfile(name:"Other owned account"); s.namedDataStores[other] = .nonPersistent()
        s.preferences.quickDomainChoices = [QuickDomainChoice(host:"127.0.0.1",profileID:other)]
        try s.saveLinkRule(first)
        check(try s.linkDecision(for:url).destination == .space(spaceID:target,profileID:f.profile), "A named Space overrides remembered account routing")
        try s.removeLinkRule(first.id); try s.setDefaultLinkDestination(.quickBrowse)
        check(try s.linkDecision(for:url).destination == .quick(profileID:other), "External compact links use remembered profile")
        check(try s.linkDecision(for:url,ownerProfileID:f.profile,useExternalDefault:false).destination == .space(spaceID:b,profileID:f.profile), "Known source owners ignore another account's remembered domain")
        let otherIndex = s.profiles.firstIndex(where:{$0.id==other})!; s.profiles[otherIndex].pendingDataClear = true
        rejects("A remembered paused account blocks without account fallback") { _ = try s.linkDecision(for:url) }
        try s.saveLinkRule(first)
        check(try s.linkDecision(for:url).destination == .space(spaceID:target,profileID:f.profile), "Explicit named Space still overrides a paused remembered account")
        s.profiles[otherIndex].pendingDataClear = false
        let orphan = LinkRule(pattern:"/route",destination:.space(UUID()))
        try s.saveLinkRule(LinkRule(id:first.id,pattern:orphan.pattern,destination:orphan.destination))
        rejects("Matching deleted destinations do not fall through to compact default") { _ = try s.openExternalPage(url) }
        check(s.linkRuleCatalog.entries[0].destination == orphan.destination, "Unavailable targets stay editable in the catalog")
        try s.saveLinkRule(first)
        let original = s.makeDocument(); let ciphertext = try Data(contentsOf:s.sessionURL)
        s.clearingData = true
        rejects("Busy profile operations block rule edits") { try s.removeLinkRule(first.id) }
        rejects("Busy profile operations block external openings") { _ = try s.openExternalPage(url) }
        s.clearingData = false; s.savingEnabled = false
        rejects("Locked metadata blocks rule edits") { try s.setDefaultLinkDestination(.quickBrowse) }
        rejects("Locked metadata blocks external openings") { _ = try s.openExternalPage(url) }
        check(try same(original,s.makeDocument()) && Data(contentsOf:s.sessionURL) == ciphertext, "Rejected operations preserve exact document and previous ciphertext")
        s.savingEnabled = true
        let bad = f.root.appendingPathComponent("directory-vault"); try FileManager.default.createDirectory(at:bad,withIntermediateDirectories:false)
        s.vault = MetadataStore(url:bad,key:f.key)
        rejects("Filesystem failure is reported before default publication") { try s.setDefaultLinkDestination(.quickBrowse) }
        check(try same(original,s.makeDocument()) && Data(contentsOf:s.sessionURL) == ciphertext, "Failed default save preserves old routes and encrypted bytes")
        let privateF = try fixture(true), ps = privateF.store
        ps.preferences.linkRules = [first]; ps.preferences.linkDefaultDestination = .space(target)
        check(!ps.canEditLinkRules && ps.linkRuleCatalog.entries.isEmpty, "Private owners expose no normal routing catalog")
        rejects("Private owners cannot edit normal routing") { try ps.saveLinkRule(first) }
        rejects("Private owners reject external normal dispatch") { _ = try ps.openExternalPage(url) }
        check(try ps.linkDecision(for:url,ownerProfileID:other,useExternalDefault:false).destination == .space(spaceID:ps.space.id,profileID:BrowserProfile.defaultID), "Private actions stay in their temporary profile despite injected normal configuration")
        check(privateF.reads.count == 0 && !FileManager.default.fileExists(atPath:ps.sessionURL.path), "Private routing consults no key and writes no normal file")

        let ar = try fixture(), ars = ar.store, origin = ars.space.id
        let elsewhere = try addSpace(ar,"Elsewhere"); let archiveID = try archived(ar,origin:origin); ars.selectSpace(elsewhere)
        let restoredID = try ars.restoreArchivedRouted(archiveID,profileID:ar.profile)
        check(ars.space.id == origin && ars.tab(restoredID)?.archivedSpaceID == nil && ars.library(for:ar.profile).archive.isEmpty, "Unmatched archive restoration returns to its original Space and clears the origin hint")
        let archive2 = try archived(ar,origin:origin), livePeek = peek(ar,path:"preserved-archive")
        try ars.saveLinkRule(LinkRule(pattern:"/archive",destination:.space(elsewhere)))
        _ = try ars.restoreArchivedRouted(archive2,profileID:ar.profile)
        check(ars.space.id == elsewhere && ars.views.values.contains(where:{$0 === livePeek}) && ars.primaryPeekView == nil, "Routed archive Space opening preserves an unrelated live primary Peek")
        let compactArchive = try archived(ar,origin:origin,quick:true)
        let compactID = try ars.restoreQuickArchive(compactArchive,profileID:ar.profile)
        check(ars.quickProfileID(compactID) == ar.profile && ars.space.id == elsewhere, "Explicit compact archive restore overrides automatic Space routes")
        let archivedQuick = try archived(ar,origin:origin,quick:true)
        try ars.saveLinkRule(LinkRule(id:ars.linkRuleCatalog.entries[0].id,pattern:"/archive",destination:.quickBrowse))
        let quickResult = try ars.restoreQuickArchiveInSpace(archivedQuick,profileID:ar.profile)
        check(ars.quickProfileID(quickResult) == ar.profile && ars.library(for:ar.profile).archive.allSatisfy({$0.id != archivedQuick}), "Open-in-Space archive action participates in a matching compact route atomically")
        let foreignArchive = try archived(ar,origin:origin), foreign = try ars.createProfile(name:"Archive target"); ars.namedDataStores[foreign] = .nonPersistent()
        let foreignSpace = ars.space.id
        try ars.saveLinkRule(LinkRule(id:ars.linkRuleCatalog.entries[0].id,pattern:"/archive",destination:.space(foreignSpace)))
        let foreignResult = try ars.restoreArchivedRouted(foreignArchive,profileID:ar.profile)
        check(ars.profileID(for:foreignResult) == foreign && ars.library(for:ar.profile).archive.allSatisfy({$0.id != foreignArchive}) && ars.views[foreignResult] == nil, "Closed archive changes account with a fresh view and consumes only its source record")
        let rollback = try fixture(), rbs = rollback.store, archivedID = try archived(rollback,origin:rollback.store.space.id), kept = peek(rollback)
        let beforeRestore = rbs.makeDocument(), beforeBytes = try Data(contentsOf:rbs.sessionURL)
        rbs.savingEnabled = false
        rejects("Failed archive restoration cannot consume the original") { _ = try rbs.restoreArchivedRouted(archivedID,profileID:rollback.profile) }
        check(try same(beforeRestore,rbs.makeDocument()) && Data(contentsOf:rbs.sessionURL) == beforeBytes && rbs.primaryPeekView === kept, "Archive rollback keeps selection, records, bytes and original preview ownership")

        let p = try fixture(), st = p.store, originalSpace = p.store.space.id
        let preview = peek(p), destination = try addSpace(p,"Peek destination")
        let promoted = try st.promotePeek(in:.primary,to:destination)
        check(st.views[promoted] === preview && st.space.id == destination && st.primaryPeekView == nil, "Same-profile Peek handoff retains the actual view and changes Space atomically")
        let quickParent = try st.openQuickPage(profileID:p.profile)
        let unrelated = peek(p,path:"unrelated-primary"), compactPeek = peek(p,context:.quick(quickParent),path:"compact-peek")
        let compactPromotion = try st.promotePeek(in:.quick(quickParent),to:originalSpace)
        check(st.views[compactPromotion] === compactPeek && st.views.values.contains(where:{$0 === unrelated}) && st.primaryPeekView == nil, "Opening a compact Peek preserves the other primary Peek without swapping their views")
        try st.saveLinkRule(LinkRule(pattern:"/compact-result",destination:.quickBrowse))
        let compactSource = peek(p,path:"compact-result"), previousSpace = st.space.id
        let compactRouteID = try st.promotePeek(in:.primary)
        check(st.quickProfileID(compactRouteID) == p.profile && st.views[compactRouteID] === compactSource && st.space.id == previousSpace, "A compact Peek route retains its source view without switching primary Space")
        let pendingConfig = WKWebViewConfiguration(); pendingConfig.websiteDataStore = .nonPersistent()
        let pending = RoutingUncommittedWeb(frame:p.web.frame,configuration:pendingConfig)
        st.peekPages[.primary] = PeekState(web:pending,profileID:p.profile,spaceID:st.space.id,requestedURL:url)
        _ = try st.openExternalPage(URL(string:"http://127.0.0.1:9/external")!)
        // Explicit Space default exercises preservation before a first committed URL exists.
        try st.setDefaultLinkDestination(.space(destination)); _ = try st.openExternalPage(url)
        check(st.views.values.contains(where:{$0 === pending}) && st.session.spaces.flatMap(\.tabs).contains(where:{$0.url == url.absoluteString}), "An unrelated loading Peek keeps its initial URL and live view during external routing")
        let cross = try fixture(), cs = cross.store, sourceSpace = cross.store.space.id
        let targetProfile = try cs.createProfile(name:"Reload account"); cs.namedDataStores[targetProfile] = .nonPersistent(); let targetSpace = cs.space.id
        cs.selectSpace(sourceSpace); let crossingWeb = peek(cross)
        let request = try cs.preparePeekPromotion(in:.primary,to:targetSpace), beforeConsent = cs.makeDocument()
        rejects("Cross-profile Peek requires consent before publication") { _ = try cs.performPeekPromotion(request) }
        check(try same(beforeConsent,cs.makeDocument()) && cs.primaryPeekView === crossingWeb, "Unconfirmed Peek leaves its original account and document intact")
        let acceptedID = try cs.performPeekPromotion(request,allowProfileChange:true)
        check(cs.profileID(for:acceptedID) == targetProfile && cs.views[acceptedID] == nil && cs.primaryPeekView == nil, "Confirmed cross-profile Peek creates a fresh target view without transferring cookies")
        rejects("Reusing a completed promotion snapshot creates no duplicate tab") { _ = try cs.performPeekPromotion(request,allowProfileChange:true) }
        cs.selectSpace(sourceSpace)
        let staleWeb = peek(cross), stale = try cs.preparePeekPromotion(in:.primary,to:targetSpace)
        staleWeb.fixtureURL = URL(string:"http://127.0.0.1:9/new-document")!
        rejects("URL changes invalidate reload consent") { _ = try cs.performPeekPromotion(stale,allowProfileChange:true) }
        staleWeb.fixtureURL = stale.url
        cs.invalidateDocumentIdentity(for:staleWeb)
        rejects("A different document at the same URL invalidates consent") { _ = try cs.performPeekPromotion(stale,allowProfileChange:true) }
        let retired = try cs.preparePeekPromotion(in:.primary,to:targetSpace)
        cs.peekPages[.primary] = PeekState(web:staleWeb,profileID:cross.profile,spaceID:sourceSpace)
        rejects("Reused native objects cannot reuse an old Peek lifetime's consent") { _ = try cs.performPeekPromotion(retired,allowProfileChange:true) }
        let reassigned = try cs.preparePeekPromotion(in:.primary,to:targetSpace)
        cs.session.spaces[cs.session.spaces.firstIndex(where:{$0.id==targetSpace})!].profileID = cross.profile
        rejects("Reassigned target profiles invalidate the old consent") { _ = try cs.performPeekPromotion(reassigned,allowProfileChange:true) }
        cs.session.spaces[cs.session.spaces.firstIndex(where:{$0.id==targetSpace})!].profileID = targetProfile
        let paused = try cs.preparePeekPromotion(in:.primary,to:targetSpace)
        cs.profiles[cs.profiles.firstIndex(where:{$0.id==targetProfile})!].pendingDataClear = true
        rejects("Paused targets cannot accept consented handoff") { _ = try cs.performPeekPromotion(paused,allowProfileChange:true) }
        cs.profiles[cs.profiles.firstIndex(where:{$0.id==targetProfile})!].pendingDataClear = false
        let rule = LinkRule(pattern:"/new-document",destination:.space(targetSpace))
        staleWeb.fixtureURL = URL(string:"http://127.0.0.1:9/new-document")!
        try cs.saveLinkRule(rule); let changedRule = try cs.preparePeekPromotion(in:.primary)
        var edited = rule; edited.destination = .quickBrowse; try cs.saveLinkRule(edited)
        rejects("Editing a matched route invalidates pending consent") { _ = try cs.performPeekPromotion(changedRule,allowProfileChange:true) }
        let failedPeek = try cs.preparePeekPromotion(in:.primary,to:targetSpace), beforePeek = cs.makeDocument()
        cs.savingEnabled = false
        rejects("Failed durable Peek save cannot transfer its live view") { _ = try cs.performPeekPromotion(failedPeek,allowProfileChange:true) }
        check(try same(beforePeek,cs.makeDocument()) && cs.primaryPeekView === staleWeb, "Failed Peek handoff preserves exact metadata and source view")
        let external = try fixture(), exs = external.store, externalPeek = peek(external), extTarget = try addSpace(external,"External target")
        try exs.setDefaultLinkDestination(.space(extTarget)); var requested = 0; exs.quickPageRequested = {_ in requested += 1}
        check(try exs.openExternalPage(url) == .space(extTarget) && exs.views.values.contains(where:{$0 === externalPeek}), "External named-Space routing retains an unrelated live Peek")
        check(requested == 0, "Space routing does not request compact or extra windows")
        exs.shutdown()
        rejects("Closed owners reject late rule edits") { try exs.saveLinkRule(first) }
        rejects("Closed owners reject late dispatch") { _ = try exs.openExternalPage(url) }
        let noSpace = try fixture(), nss = noSpace.store
        var noSpaceDoc = nss.makeDocument(); noSpaceDoc.session.spaces.removeAll { $0.effectiveProfileID == noSpace.profile }
        noSpaceDoc.session.activateSpace(noSpaceDoc.session.spaces[0].id); try nss.commitQuickDocument(noSpaceDoc)
        nss.preferences.quickDomainChoices = [QuickDomainChoice(host:"127.0.0.1",profileID:noSpace.profile)]
        try nss.setDefaultLinkDestination(.mostRecentSpace)
        check(try nss.linkDecision(for:url).destination == .newSpace(profileID:noSpace.profile), "A profile without Spaces resolves to a new Space in that profile")
        guard case .space(let createdSpace) = try nss.openExternalPage(url) else { throw LinkRoutingCheckError.failed }
        check(nss.space.id == createdSpace && nss.activeProfileID == noSpace.profile && nss.session.lastUsedSpaces?[noSpace.profile] == createdSpace, "Opening creates and records a missing profile Space in one durable document")
        let missingOriginArchive = try archived(noSpace,origin:UUID())
        _ = try nss.restoreArchivedRouted(missingOriginArchive,profileID:noSpace.profile)
        check(nss.space.id == createdSpace, "A deleted archive origin falls back within its source profile")
        let fs = try fixture(), fss = fs.store, fsPeek = peek(fs), fsTarget = try addSpace(fs,"Failing destination")
        try fss.setDefaultLinkDestination(.space(fsTarget))
        let fsArchive = try archived(fs,origin:fss.space.id), fsDoc = fss.makeDocument(), fsBytes = try Data(contentsOf:fss.sessionURL)
        let directory = fs.root.appendingPathComponent("failed-opening-vault"); try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false)
        fss.vault = MetadataStore(url:directory,key:fs.key)
        rejects("Filesystem failure blocks an external Space opening") { _ = try fss.openExternalPage(url) }
        check(try same(fsDoc,fss.makeDocument()) && Data(contentsOf:fss.sessionURL) == fsBytes && fss.primaryPeekView === fsPeek && !fss.views.values.contains(where:{$0 === fsPeek}), "A failed external write leaves the untransferred preview, document and ciphertext intact")
        fss.savingEnabled = true
        rejects("Filesystem failure cannot consume an archive") { _ = try fss.restoreArchivedRouted(fsArchive,profileID:fs.profile) }
        check(try same(fsDoc,fss.makeDocument()) && fss.primaryPeekView === fsPeek, "A failed archive write retains archive and original preview")
        fss.savingEnabled = true
        let fsRequest = try fss.preparePeekPromotion(in:.primary,to:fsTarget)
        rejects("Filesystem failure cannot publish a same-profile live view handoff") { _ = try fss.performPeekPromotion(fsRequest) }
        check(try same(fsDoc,fss.makeDocument()) && fss.primaryPeekView === fsPeek && !fss.views.values.contains(where:{$0 === fsPeek}), "A failed handoff write preserves the source's native ownership")
        let mutation = try fixture(), ms = mutation.store, msTarget = try addSpace(mutation,"Removed target")
        _ = peek(mutation)
        let missing = try ms.preparePeekPromotion(in:.primary,to:msTarget)
        ms.session.spaces.removeAll { $0.id == msTarget }
        rejects("Removing a target invalidates pending promotion") { _ = try ms.performPeekPromotion(missing) }
        let lockedRuleDoc = ms.makeDocument()
        rejects("A duplicate condition cannot overwrite another route") {
            try ms.saveLinkRule(LinkRule(pattern:"/duplicate")); try ms.saveLinkRule(LinkRule(pattern:"/DUPLICATE"))
        }
        check(ms.linkRuleCatalog.entries.count == 1, "Duplicate rejection preserves the first distinct route")
        rejects("Invalid reordering cannot remove or duplicate a rule") { try ms.moveLinkRule(ms.linkRuleCatalog.entries[0].id,by:Int.max) }
        check(ms.linkRuleCatalog.entries.count == 1 && lockedRuleDoc.session.selectedSpace == ms.session.selectedSpace, "Failed reordering preserves routes and current Space")
        let ports = try fixture(), portStore = ports.store, safeSpace = ports.store.space.id
        let portTargetProfile = try portStore.createProfile(name:"Port-only destination"); portStore.namedDataStores[portTargetProfile] = .nonPersistent()
        let portTargetSpace = portStore.space.id; portStore.selectSpace(safeSpace)
        try portStore.setDefaultLinkDestination(.mostRecentSpace)
        try portStore.saveLinkRule(LinkRule(kind:.equals,pattern:"127.0.0.1:443",destination:.space(portTargetSpace)))
        let plainHTTP = try portStore.linkDecision(for:URL(string:"http://127.0.0.1/")!)
        check(plainHTTP.rule == nil && plainHTTP.destination == .space(spaceID:safeSpace,profileID:ports.profile), "A port443 condition cannot select another profile for implicit HTTP port80")
        let explicitHTTP80 = try portStore.linkDecision(for:URL(string:"http://127.0.0.1:80/")!)
        check(explicitHTTP80.rule == nil && explicitHTTP80.destination == .space(spaceID:safeSpace,profileID:ports.profile), "An explicit HTTP default port cannot cross into the port443 profile")
        check(try portStore.linkDecision(for:URL(string:"http://127.0.0.1:443/")!).destination == .space(spaceID:portTargetSpace,profileID:portTargetProfile), "The port443 condition still routes its actual HTTP endpoint to the selected profile")
        check(try portStore.linkDecision(for:URL(string:"https://127.0.0.1/")!).destination == .space(spaceID:portTargetSpace,profileID:portTargetProfile), "The port443 condition routes the canonical HTTPS default to the selected profile")
        _ = try portStore.openExternalPage(URL(string:"http://127.0.0.1:80/")!)
        check(portStore.activeProfileID == ports.profile && portStore.space.id == safeSpace, "Actual external dispatch preserves the default profile when the rule's port does not match")
        guard failures == 0 else { throw LinkRoutingCheckError.failed }
    }
}
