import AppKit
import CryptoKit
import WebKit
import BrowserCore

@main struct SpaceManagementChecks {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited); setbuf(stdout,nil)
        var failures = 0
        func check(_ value:Bool,_ name:String) { print("\(value ? "PASS" : "FAIL"): \(name)"); if !value { failures += 1 } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        var archived = Space(name:"Research")
        archived.tabs[0].url = "https://example.com/deleted-space"; archived.tabs[0].pinned = true
        let encodedSpace = try JSONSerialization.jsonObject(with:JSONEncoder().encode(archived))
        let schemaRecordID = "C9E23F6A-4559-44F0-8FF7-C7D39240782E"
        let record:[String:Any] = ["id":schemaRecordID,"space":encodedSpace,"originalIndex":1,"deletedAt":1000.0]
        var object = try JSONSerialization.jsonObject(with:JSONEncoder().encode(BrowserDocument())) as! [String:Any]
        object["formatVersion"] = 3; object["library"] = ["bookmarks":[],"history":[],"closedTabs":[],"archive":[],"deletedSpaces":[record]]
        var upgraded = try JSONDecoder().decode(BrowserDocument.self,from:JSONSerialization.data(withJSONObject:object))
        try upgraded.repairProfiles()
        func records(_ document:BrowserDocument) throws -> [[String:Any]] {
            let raw = try JSONSerialization.jsonObject(with:JSONEncoder().encode(document)) as! [String:Any]
            return (raw["library"] as? [String:Any])?["deletedSpaces"] as? [[String:Any]] ?? []
        }
        check(try records(upgraded).first?["id"] as? String == schemaRecordID, "Profile repair preserves saved Space recovery records")
        check(upgraded.formatVersion == 5, "Space recovery advances the document so older readers reject a lossy downgrade")
        let key = SymmetricKey(size:.bits256), url = root.appendingPathComponent("metadata.sealed")
        let vault = MetadataStore(url:url,key:key); try vault.save(upgraded)
        let restored = try vault.load(BrowserDocument.self)!
        let restoredName = try records(restored).first?["space"] as? [String:Any]
        check(restoredName?["name"] as? String == "Research", "Encrypted recovery retains the deleted Space identity and contents")
        check(try Data(contentsOf:url).range(of:Data("https://example.com/deleted-space".utf8)) == nil, "Deleted Space URLs are never stored as plaintext metadata")
        object["formatVersion"] = 6
        var future = try JSONDecoder().decode(BrowserDocument.self,from:JSONSerialization.data(withJSONObject:object))
        var rejected = false; do { try future.repairProfiles() } catch { rejected = true }
        check(rejected, "Unknown future documents remain protected")
        func rejects(_ name:String,_ action:() throws -> Void) {
            do { try action(); check(false,name) } catch { check(true,name) }
        }
        let live = BrowserStore(dataRoot:root.appendingPathComponent("live"),keyProvider:{_ in key}); live.finishOnboarding()
        let personal = live.space.id, originalTab = live.selectedID!
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame:NSRect(x:0,y:0,width:600,height:400),configuration:config)
        live.registerView(web,for:originalTab,profile:BrowserProfile.defaultID)
        let host = NSWindow(contentRect:NSRect(x:0,y:0,width:600,height:400),styleMask:[],backing:.buffered,defer:false)
        host.isReleasedWhenClosed = false; host.contentView = web
        web.loadHTMLString("<input id='owned' value='survive'>",baseURL:nil)
        var ready = false
        for _ in 0..<500 where !ready {
            ready = (try? await web.evaluateJavaScript("document.getElementById('owned') !== null")) as? Bool == true
            if !ready { try await Task.sleep(for:.milliseconds(10)) }
        }
        check(ready,"Owned live form is ready before Space lifecycle assertions")
        let research = try live.createSpace(name:"Research")
        live.selectSpace(personal)
        try live.renameSpace(research,name:"  Deep Research  "); try live.setSpaceIcon(research,icon:"leaf.fill")
        check(live.session.spaces.first(where:{$0.id == research})?.name == "Deep Research" && live.session.spaces.first(where:{$0.id == research})?.icon == "leaf.fill", "Rename and icon edits update the intended background Space")
        rejects("Empty Space names are rejected") { try live.renameSpace(research,name:"  \n  ") }
        rejects("Unknown icon identifiers cannot replace a Space icon") { try live.setSpaceIcon(research,icon:"not-a-real-space-icon") }
        try live.moveSpace(research,to:0)
        check(live.session.spaces.map(\.id) == [research,personal] && live.session.selectedSpace == personal, "Reordering preserves selection and stable Space identities")
        let keptForm = ready ? (try? await web.evaluateJavaScript("document.getElementById('owned').value")) as? String : nil
        check(live.views[originalTab] === web && keptForm == "survive", "Background Space edits preserve the actual live document and form")
        var pin = BrowserCore.Tab(title:"Pinned",url:"https://example.com/pinned"); pin.pinned = true; pin.homeURL = pin.url; pin.folder = "Work"
        let today = BrowserCore.Tab(title:"Today",url:"https://example.com/today")
        var favorite = BrowserCore.Tab(title:"Shared favorite",url:"https://example.com/favorite"); favorite.favorite = true; favorite.pinned = true
        let researchIndex = live.session.spaces.firstIndex(where:{$0.id == research})!
        live.session.spaces[researchIndex].tabs = [pin,today,favorite]; live.session.spaces[researchIndex].selected = pin.id
        live.session.spaces[researchIndex].theme = "forest"; live.session.spaces[researchIndex].collapsedFolders = ["Work"]
        var records = live.library; records.favoriteTabs = [favorite]; live.library = records; live.flush()
        let snapshotID = try live.deleteSpace(research,now:Date(timeIntervalSince1970:1234))
        let deleted = live.library.deletedSpaces!.first!
        check(deleted.id == snapshotID && deleted.originalIndex == 0 && deleted.space.tabs.map(\.id) == [pin.id,today.id] && deleted.space.theme == "forest" && deleted.space.collapsedFolders == ["Work"], "Deletion snapshots pins, folders, theme, order and tabs without duplicating global Favorites")
        check(live.session.spaces.map(\.id) == [personal] && live.library.favoriteTabs?.map(\.id) == [favorite.id] && live.views[originalTab] === web, "Deleting a background Space keeps Favorites and another live Space intact")
        check(live.undoSpaceDeletion(), "Undo restores the last deleted Space")
        check(live.session.spaces.map(\.id) == [research,personal] && live.session.selectedSpace == research && live.library.deletedSpaces?.isEmpty == true, "Undo restores the original order and activates the recovered Space atomically")
        _ = try live.deleteSpace(research)
        live.shutdown(); host.contentView = nil; host.close()
        let relaunched = BrowserStore(dataRoot:root.appendingPathComponent("live"),keyProvider:{_ in key})
        check(relaunched.library.deletedSpaces?.first?.space.name == "Deep Research", "Recently Deleted survives encrypted relaunch")
        let recordID = relaunched.library.deletedSpaces!.first!.id
        var collision = Space(name:"Existing collision"); collision.id = research; collision.tabs = [pin]
        relaunched.session.spaces.append(collision); relaunched.flush()
        let recovered = try relaunched.restoreDeletedSpace(recordID,profileID:BrowserProfile.defaultID)
        check(recovered != research && relaunched.session.spaces.first(where:{$0.id == research})?.name == "Existing collision", "Recovery repairs a colliding Space ID without replacing an existing Space")
        let restoredSpace = relaunched.session.spaces.first(where:{$0.id == recovered})!
        check(restoredSpace.tabs.first?.id != pin.id && relaunched.session.spaces.first(where:{$0.id == research})?.tabs.first?.id == pin.id && relaunched.library.favoriteTabs?.count == 1, "Recovery repairs tab collisions and leaves existing pages and profile Favorites unchanged")
        let again = try relaunched.deleteSpace(recovered)
        try relaunched.permanentlyDeleteSpace(again,profileID:BrowserProfile.defaultID)
        check(relaunched.library.deletedSpaces?.isEmpty == true, "Explicit permanent removal deletes only the chosen recovery record")
        rejects("A stale recovery action cannot revive a removed snapshot") { _ = try relaunched.restoreDeletedSpace(again,profileID:BrowserProfile.defaultID) }
        relaunched.shutdown()
        let last = BrowserStore(dataRoot:root.appendingPathComponent("last"),keyProvider:{_ in key})
        let lastID = last.space.id; _ = try last.deleteSpace(lastID)
        check(last.session.spaces.count == 1 && last.space.id != lastID && last.activeProfileID == BrowserProfile.defaultID && last.selectedTab?.url == "", "Deleting the last Space creates a blank Space in the same profile")
        last.shutdown()
        let privateRoot = root.appendingPathComponent("private")
        var privateKeys = 0
        let temporary = BrowserStore(isPrivate:true,dataRoot:privateRoot,keyProvider:{_ in privateKeys += 1; return key})
        let temporaryID = try temporary.createSpace(name:"Temporary")
        let removedPrivate = try temporary.deleteSpace(temporaryID)
        _ = try temporary.restoreDeletedSpace(removedPrivate,profileID:BrowserProfile.defaultID)
        check(privateKeys == 0 && temporary.vault == nil && !FileManager.default.fileExists(atPath:privateRoot.path), "Private Space lifecycle never requests a key or creates persistent files")
        temporary.shutdown()
        let failed = BrowserStore(dataRoot:root.appendingPathComponent("failed"),keyProvider:{_ in key})
        let failureID = failed.space.id, failureName = failed.space.name, initialBytes = try Data(contentsOf:failed.sessionURL)
        let obstruction = root.appendingPathComponent("not-a-directory"); try Data().write(to:obstruction)
        failed.vault = MetadataStore(url:obstruction.appendingPathComponent("metadata.sealed"),key:key)
        rejects("Failed rename does not publish an unsaved name") { try failed.renameSpace(failureID,name:"Must not appear") }
        let afterFailedSave = try Data(contentsOf:failed.sessionURL)
        check(failed.space.name == failureName && afterFailedSave == initialBytes, "Failed Space persistence preserves live state and the original ciphertext")
        failed.savingEnabled = true
        rejects("Failed deletion cannot close a Space or create a phantom recovery record") { _ = try failed.deleteSpace(failureID) }
        check(failed.space.id == failureID && failed.library.deletedSpaces?.isEmpty != false, "Deletion publishes neither removal nor recovery until its encrypted save succeeds")
        failed.shutdown()
        let retrying = BrowserStore(dataRoot:root.appendingPathComponent("retrying"),keyProvider:{_ in key})
        let recoverID = try retrying.deleteSpace(retrying.space.id)
        let recoverBytes = try Data(contentsOf:retrying.sessionURL)
        retrying.vault = MetadataStore(url:obstruction.appendingPathComponent("metadata.sealed"),key:key)
        rejects("Failed recovery cannot remove its saved snapshot") { _ = try retrying.restoreDeletedSpace(recoverID,profileID:BrowserProfile.defaultID) }
        retrying.savingEnabled = true
        rejects("Failed permanent removal preserves the recovery record") { try retrying.permanentlyDeleteSpace(recoverID,profileID:BrowserProfile.defaultID) }
        let afterRecoveryFailure = try Data(contentsOf:retrying.sessionURL)
        check(retrying.library.deletedSpaces?.first?.id == recoverID && afterRecoveryFailure == recoverBytes, "Recovery failures preserve both the record and original encrypted file")
        retrying.shutdown()
        let routing = BrowserStore(dataRoot:root.appendingPathComponent("routing"),keyProvider:{_ in key})
        let routeSpace = try routing.createSpace(name:"Route target")
        try routing.saveLinkRule(LinkRule(pattern:"/space-route",destination:.space(routeSpace)))
        let routeURL = URL(string:"https://example.com/space-route")!
        let routeRecord = try routing.deleteSpace(routeSpace)
        rejects("A deleted Space route cannot silently fall back to another account or Space") { _ = try routing.linkDecision(for:routeURL) }
        let routeRestored = try routing.restoreDeletedSpace(routeRecord,profileID:BrowserProfile.defaultID)
        let restoredRoute = try routing.linkDecision(for:routeURL)
        check(routeRestored == routeSpace && restoredRoute.destination == .space(spaceID:routeSpace,profileID:BrowserProfile.defaultID), "Restoring the exact Space reactivates its original route")
        routing.shutdown()
        let conflictRoot = root.appendingPathComponent("routing-collision")
        let conflict = BrowserStore(dataRoot:conflictRoot,keyProvider:{_ in key})
        let conflictProfile = try conflict.createProfile(name:"Work")
        conflict.namedDataStores[conflictProfile] = .nonPersistent()
        let lostSpace = conflict.session.spaces.first(where:{$0.effectiveProfileID == conflictProfile})!.id
        let lostRule = LinkRule(pattern:"/lost",destination:.space(lostSpace))
        let unrelated = LinkRule(pattern:"/unrelated",destination:.quickBrowse)
        try conflict.saveLinkRule(lostRule); try conflict.saveLinkRule(unrelated)
        try conflict.setDefaultLinkDestination(.space(lostSpace))
        let lostRecord = try conflict.deleteSpace(lostSpace)
        var conflictedDocument = conflict.makeDocument()
        var collidingPersonal = Space(name:"Personal collision"); collidingPersonal.id = lostSpace; collidingPersonal.profileID = BrowserProfile.defaultID
        conflictedDocument.session.spaces.append(collidingPersonal)
        conflict.shutdown()
        try MetadataStore(url:conflict.sessionURL,key:key).save(conflictedDocument)
        let guarded = BrowserStore(dataRoot:conflictRoot,keyProvider:{_ in key})
        let lostURL = URL(string:"https://example.com/lost")!, defaultURL = URL(string:"https://example.com/default")!
        rejects("A relaunched ambiguous named route cannot select the colliding account") { _ = try guarded.linkDecision(for:lostURL) }
        rejects("A relaunched ambiguous default cannot select the colliding account") { _ = try guarded.linkDecision(for:defaultURL) }
        let deliberatelyChosen = LinkRule(pattern:"/chosen",destination:.space(lostSpace))
        try guarded.saveLinkRule(deliberatelyChosen)
        let chosenURL = URL(string:"https://example.com/chosen")!
        check(try guarded.linkDecision(for:chosenURL).destination == .space(spaceID:lostSpace,profileID:BrowserProfile.defaultID), "Deliberate destination selection resolves a live/deleted collision")
        let retiredRoot = root.appendingPathComponent("retired-collision")
        try MetadataStore(url:retiredRoot.appendingPathComponent("session-v2.sealed"),key:key).save(guarded.makeDocument())
        let retired = BrowserStore(dataRoot:retiredRoot,keyProvider:{_ in key})
        let retiredPersonal = try retired.deleteSpace(lostSpace)
        try retired.permanentlyDeleteSpace(retiredPersonal,profileID:BrowserProfile.defaultID)
        let recoveredAfterRetirement = try retired.restoreDeletedSpace(lostRecord,profileID:conflictProfile)
        check(recoveredAfterRetirement != lostSpace, "Recovery never reuses an identity previously shared with a different Space")
        rejects("Removing the colliding Space first cannot revive its explicit route into the recovered account") { _ = try retired.linkDecision(for:chosenURL) }
        retired.shutdown()
        let restoredWork = try guarded.restoreDeletedSpace(lostRecord,profileID:conflictProfile)
        rejects("Collision recovery cannot reactivate an old named route into another account") { _ = try guarded.linkDecision(for:lostURL) }
        rejects("Collision recovery cannot reactivate an old default into another account") { _ = try guarded.linkDecision(for:defaultURL) }
        let preservedChoice = try guarded.linkDecision(for:chosenURL).destination
        check(restoredWork != lostSpace && guarded.linkRuleCatalog.entries.contains(unrelated) && preservedChoice == .space(spaceID:lostSpace,profileID:BrowserProfile.defaultID), "Recovery preserves unrelated rules and deliberate collision selections")
        try guarded.setDefaultLinkDestination(.space(restoredWork))
        check(try guarded.linkDecision(for:defaultURL).destination == .space(spaceID:restoredWork,profileID:conflictProfile), "The recovered account can be deliberately selected as the default")
        guarded.shutdown()
        let guardedAgain = BrowserStore(dataRoot:conflictRoot,keyProvider:{_ in key})
        rejects("Invalidated collision routes remain unavailable after another encrypted relaunch") { _ = try guardedAgain.linkDecision(for:lostURL) }
        guardedAgain.shutdown()
        let profiles = BrowserStore(dataRoot:root.appendingPathComponent("profiles"),keyProvider:{_ in key})
        let work = try profiles.createProfile(name:"Work")
        profiles.namedDataStores[work] = .nonPersistent()
        let workSpace = profiles.session.spaces.first(where:{$0.effectiveProfileID == work})!.id
        let workRecord = try profiles.deleteSpace(workSpace)
        let otherRecord = try profiles.deleteSpace(profiles.space.id)
        check(profiles.library(for:work).deletedSpaces?.count == 1 && profiles.library(for:BrowserProfile.defaultID).deletedSpaces?.count == 1, "Deleted Spaces remain in their owning profile libraries")
        let workIndex = profiles.profiles.firstIndex(where:{$0.id == work})!; profiles.profiles[workIndex].pendingDataClear = true
        rejects("A paused profile cannot recover into another account") { _ = try profiles.restoreDeletedSpace(workRecord,profileID:work) }
        profiles.profiles[workIndex].pendingDataClear = false
        try await profiles.clearProfileData(work,removeData:{_ in})
        check(profiles.library(for:work).deletedSpaces?.isEmpty == true && profiles.library(for:BrowserProfile.defaultID).deletedSpaces?.first?.id == otherRecord, "Clearing profile data removes its deleted snapshots and preserves another profile's recovery")
        try await profiles.deleteProfile(work,removeStore:{_ in})
        rejects("A deleted profile cannot be silently recreated by stale Space recovery") { _ = try profiles.restoreDeletedSpace(workRecord,profileID:work) }
        profiles.shutdown()
        let dropping = BrowserStore(isPrivate:true)
        let a = dropping.space.id, b = try dropping.createSpace(name:"B"), c = try dropping.createSpace(name:"C")
        check(dropping.acceptSpaceDrop("alcove-space:" + c.uuidString,target:a,after:false) && dropping.session.spaces.map(\.id) == [c,a,b], "Dropping before the first icon keeps the requested Space order")
        check(dropping.acceptSpaceDrop("alcove-space:" + c.uuidString,target:b,after:true) && dropping.session.spaces.map(\.id) == [a,b,c], "Dropping after the last icon reaches the final position")
        let unchangedIDs = dropping.session.spaces.map(\.id)
        check(!dropping.acceptSpaceDrop("https://example.com",target:a,after:false) && dropping.session.spaces.map(\.id) == unchangedIDs, "Unrelated dropped text cannot reorder or navigate Spaces")
        dropping.shutdown()

        var merged = BrowserLibrary()
        let firstVersion = DeletedSpace(space:archived,originalIndex:0)
        var secondVersion = firstVersion; secondVersion.space.name = "Another saved version"
        merged.deletedSpaces = [firstVersion]
        var incoming = BrowserLibrary(); incoming.deletedSpaces = [firstVersion,secondVersion]
        merged.mergePreservingRecords(incoming)
        check(merged.deletedSpaces?.count == 2 && Set((merged.deletedSpaces ?? []).map(\.id)).count == 2, "Recovery merges retain different snapshots without duplicating identical versions")
        var repaired = BrowserDocument(); repaired.library.deletedSpaces = [firstVersion,secondVersion]
        try repaired.repairProfiles()
        check(repaired.library.deletedSpaces?.count == 2 && Set((repaired.library.deletedSpaces ?? []).map(\.id)).count == 2 && repaired.library.deletedSpaces?.allSatisfy({$0.space.effectiveProfileID == BrowserProfile.defaultID}) == true, "Profile repair normalizes recovery IDs and preserves the owning account")
        incoming.deletedSpaces = [secondVersion,secondVersion]
        merged.mergePreservingRecords(incoming); merged.mergePreservingRecords(incoming)
        check(merged.deletedSpaces?.count == 2, "Repeated merges do not duplicate a previously remapped recovery snapshot")
        var duplicateRepair = BrowserDocument(); duplicateRepair.library.deletedSpaces = [firstVersion,secondVersion,secondVersion]
        try duplicateRepair.repairProfiles(); try duplicateRepair.repairProfiles()
        check(duplicateRepair.library.deletedSpaces?.count == 2, "Repair deduplicates identical snapshots even after a conflicting record ID changes")

        exit(failures == 0 ? 0 : 1)
    }
}
