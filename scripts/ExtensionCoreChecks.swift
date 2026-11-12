import Foundation
import CryptoKit
import BrowserCore

@main struct ExtensionCoreChecks {
    static func main() async throws {
        var failures = 0
        func check(_ value:Bool,_ title:String) { print("\(value ? "PASS" : "FAIL"): \(title)"); if !value { failures += 1 } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let profileID = BrowserProfile.defaultID.uuidString
        let controllerID = "16ACF452-E746-4B53-8F53-F312B2A8D7AA"
        let recordID = "8DDA876B-9A38-4DA3-BD21-C183519071AB"
        let digest = String(repeating:"a",count:64)
        let record:[String:Any] = ["id":recordID,"name":"Owned Fixture Extension","version":"1.0","manifestVersion":3,"packageDigest":digest,"source":"folder","requestedPermissions":["storage"],"optionalPermissions":[],"hostPermissions":["https://example.com/*"],"optionalHostPermissions":[],"enabled":false,"grants":["profileID":profileID,"recordID":recordID,"controllerID":controllerID,"packageDigest":digest,"permissions":["storage"],"hostPatterns":["https://example.com/*"],"allowPrivate":false]]
        let library:[String:Any] = ["bookmarks":[],"history":[],"closedTabs":[],"archive":[],"extensions":[record]]
        var object = try JSONSerialization.jsonObject(with:JSONEncoder().encode(BrowserDocument())) as! [String:Any]
        object["formatVersion"] = 4
        object["profiles"] = [["id":profileID,"name":"Default","icon":"person.crop.circle","extensionControllerID":controllerID]]
        object["library"] = library; object["profileLibraries"] = [["profileID":profileID,"library":library]]
        var document = try JSONDecoder().decode(BrowserDocument.self,from:JSONSerialization.data(withJSONObject:object))
        try document.repairProfiles()
        func encoded(_ document:BrowserDocument) throws -> [String:Any] { try JSONSerialization.jsonObject(with:JSONEncoder().encode(document)) as! [String:Any] }
        let repaired = try encoded(document)
        check(document.formatVersion == 5,"Extension metadata advances format4 to5 so older readers reject a lossy downgrade")
        let profiles = repaired["profiles"] as? [[String:Any]]
        check(profiles?.first?["extensionControllerID"] as? String == controllerID,"The profile's durable extension storage identity survives repair")
        let libraries = repaired["profileLibraries"] as? [[String:Any]]
        let records = (libraries?.first?["library"] as? [String:Any])?["extensions"] as? [[String:Any]]
        check(records?.count == 1 && records?.first?["id"] as? String == recordID,"Repair preserves a profile-owned extension without duplicating its mirrored default library")
        let key = SymmetricKey(data:Data(repeating:17,count:32))
        let storage = MetadataStore(url:root.appendingPathComponent("session.sealed"),key:key)
        try storage.save(document)
        let bytes = try Data(contentsOf:storage.url)
        let restored = try storage.load(BrowserDocument.self)!
        let restoredJSON = try encoded(restored)
        let restoredLibraries = restoredJSON["profileLibraries"] as? [[String:Any]]
        let restoredRecords = (restoredLibraries?.first?["library"] as? [String:Any])?["extensions"] as? [[String:Any]]
        let restoredGrants = restoredRecords?.first?["grants"] as? [String:Any]
        check(restoredGrants?["hostPatterns"] as? [String] == ["https://example.com/*"] && restoredGrants?["allowPrivate"] as? Bool == false,"Approved site access and private-off state survive encrypted relaunch")
        check(restoredGrants?["recordID"] as? String == recordID && restoredGrants?["controllerID"] as? String == controllerID,"Encrypted approvals retain their exact record and storage-controller binding")
        check(bytes.range(of:Data("Owned Fixture Extension".utf8)) == nil && bytes.range(of:Data("example.com".utf8)) == nil,"Extension names and approved sites are not plaintext metadata")
        func repairedObject(_ input:[String:Any]) throws -> [String:Any] {
            var value = try JSONDecoder().decode(BrowserDocument.self,from:JSONSerialization.data(withJSONObject:input))
            try value.repairProfiles(); return try encoded(value)
        }
        func ownedRecords(_ input:[String:Any],_ owner:String) -> [[String:Any]] {
            let entries = input["profileLibraries"] as? [[String:Any]]
            return ((entries?.first(where:{$0["profileID"] as? String == owner})?["library"] as? [String:Any])?["extensions"] as? [[String:Any]]) ?? []
        }
        let workID = "699A5AC8-C6ED-4C4B-86F5-47B37F8EF860", otherController = "0476444F-E2EA-45E4-BDB0-3CF2308F8998"
        var approved = record; approved["enabled"] = true
        var workRecord = approved, workGrants = approved["grants"] as! [String:Any]; workGrants["profileID"] = workID; workRecord["grants"] = workGrants
        var defaultLibrary = library; defaultLibrary["extensions"] = [approved]
        var workLibrary = library; workLibrary["extensions"] = [workRecord]
        var collision = object
        collision["profiles"] = [["id":profileID,"name":"Default","icon":"person.crop.circle","extensionControllerID":controllerID],["id":workID,"name":"Work","icon":"person.crop.circle","extensionControllerID":controllerID]]
        collision["library"] = defaultLibrary; collision["profileLibraries"] = [["profileID":profileID,"library":defaultLibrary],["profileID":workID,"library":workLibrary]]
        let repairedCollision = try repairedObject(collision)
        let collisionProfiles = repairedCollision["profiles"] as? [[String:Any]]
        check(collisionProfiles?.first(where:{$0["id"] as? String == workID})?["extensionControllerID"] as? String != controllerID,"Two accounts cannot retain the same persistent extension controller identity")
        let collisionRecord = ownedRecords(repairedCollision,workID).first
        check(collisionRecord?["grants"] == nil && collisionRecord?["enabled"] as? Bool == false,"Repairing a controller collision revokes its old account approvals")
        check(ownedRecords(repairedCollision,profileID).first?["enabled"] as? Bool == true,"Repair preserves the unaffected account's valid extension approval")
        var copied = collision
        copied["profiles"] = [["id":profileID,"name":"Default","icon":"person.crop.circle","extensionControllerID":controllerID],["id":workID,"name":"Work","icon":"person.crop.circle","extensionControllerID":otherController]]
        copied["profileLibraries"] = [["profileID":profileID,"library":defaultLibrary],["profileID":workID,"library":defaultLibrary]]
        let copiedRecord = ownedRecords(try repairedObject(copied),workID).first
        check(copiedRecord?["grants"] == nil && copiedRecord?["enabled"] as? Bool == false,"Copying a library cannot grant another profile access to the same extension code")
        var missingController = object; missingController["profiles"] = [["id":profileID,"name":"Default","icon":"person.crop.circle"]]
        missingController["profileLibraries"] = [["profileID":profileID,"library":defaultLibrary]]
        let unbound = ownedRecords(try repairedObject(missingController),profileID).first
        check(unbound?["grants"] == nil && unbound?["enabled"] as? Bool == false,"An approval without a durable storage identity requires review again")
        var changedCode = approved; changedCode["packageDigest"] = String(repeating:"b",count:64)
        var changedLibrary = library; changedLibrary["extensions"] = [changedCode]
        var changed = object; changed["profileLibraries"] = [["profileID":profileID,"library":changedLibrary]]
        let changedRecord = ownedRecords(try repairedObject(changed),profileID).first
        check(changedRecord?["grants"] == nil && changedRecord?["enabled"] as? Bool == false,"A code digest change cannot reuse an earlier approval")
        var overbroad = approved, overbroadGrants = approved["grants"] as! [String:Any]
        overbroadGrants["permissions"] = ["cookies"]; overbroad["grants"] = overbroadGrants
        var overbroadLibrary = library; overbroadLibrary["extensions"] = [overbroad]
        var overbroadDocument = object; overbroadDocument["profileLibraries"] = [["profileID":profileID,"library":overbroadLibrary]]
        let overbroadRecord = ownedRecords(try repairedObject(overbroadDocument),profileID).first
        check(overbroadRecord?["grants"] == nil && overbroadRecord?["enabled"] as? Bool == false,"A saved grant cannot exceed its declared API permissions")
        // These cases catch domain-suffix, scheme and path widening during approval repair.
        for (requested,granted,want,title) in [
            ("https://*.example.com/*","https://deep.example.com/*",true,"A declared domain tree covers a deliberately approved subdomain"),
            ("https://*.example.com/*","https://badexample.com/*",false,"Domain-tree approval uses a dot boundary"),
            ("https://example.com/*","https://*.example.com/*",false,"An exact-host declaration cannot gain all subdomains"),
            ("https://example.com/*","*://example.com/*",false,"HTTPS-only declarations cannot acquire HTTP access"),
            ("*://example.com/*","https://example.com/*",true,"A wildcard scheme can be deliberately narrowed to HTTPS"),
            ("https://example.com/allowed/*","https://example.com/other/*",false,"A saved approval cannot silently widen a declared path"),
            ("<all_urls>","file:///*",false,"All-sites approval does not implicitly grant local files")
        ] {
            var candidate = approved, grant = approved["grants"] as! [String:Any]
            candidate["hostPermissions"] = [requested]; grant["hostPatterns"] = [granted]; candidate["grants"] = grant
            var candidateLibrary = library; candidateLibrary["extensions"] = [candidate]
            var candidateDocument = object; candidateDocument["profileLibraries"] = [["profileID":profileID,"library":candidateLibrary]]
            let result = ownedRecords(try repairedObject(candidateDocument),profileID).first
            check(result?["enabled"] as? Bool == want && (want || result?["grants"] == nil),title)
        }
        var optionalRecord = approved, optionalGrant = approved["grants"] as! [String:Any]
        optionalRecord["optionalPermissions"] = ["tabs"]; optionalGrant["permissions"] = ["storage","tabs"]; optionalRecord["grants"] = optionalGrant
        var optionalLibrary = library; optionalLibrary["extensions"] = [optionalRecord]
        var optionalDocument = object; optionalDocument["profileLibraries"] = [["profileID":profileID,"library":optionalLibrary]]
        check(ownedRecords(try repairedObject(optionalDocument),profileID).first?["enabled"] as? Bool == true,"Explicit approval may include a declared optional API")
        var zeroOwner = object, zeroRecord = approved, zeroGrants = approved["grants"] as! [String:Any]
        let zeroID = BrowserProfile.zeroID.uuidString; zeroGrants["profileID"] = zeroID; zeroRecord["grants"] = zeroGrants
        var zeroLibrary = library; zeroLibrary["extensions"] = [zeroRecord]
        zeroOwner["profiles"] = [["id":profileID,"name":"Default","icon":"person.crop.circle","extensionControllerID":otherController],["id":zeroID,"name":"Recovered","icon":"person.crop.circle","extensionControllerID":controllerID]]
        zeroOwner["profileLibraries"] = [["profileID":zeroID,"library":zeroLibrary]]
        let zeroRepaired = try repairedObject(zeroOwner)
        let zeroProfile = (zeroRepaired["profiles"] as? [[String:Any]])?.first(where:{$0["name"] as? String == "Recovered"})
        let zeroRecords = ownedRecords(zeroRepaired,zeroProfile?["id"] as? String ?? "")
        check(zeroProfile?["extensionControllerID"] as? String != controllerID && zeroRecords.first?["grants"] == nil && zeroRecords.first?["enabled"] as? Bool == false,"Repairing an invalid account rotates extension storage and revokes approval")
        var prohibitedPrivate = approved, prohibitedGrant = approved["grants"] as! [String:Any]
        prohibitedPrivate["incognito"] = "not_allowed"; prohibitedGrant["allowPrivate"] = true; prohibitedPrivate["grants"] = prohibitedGrant
        var prohibitedLibrary = library; prohibitedLibrary["extensions"] = [prohibitedPrivate]
        var prohibitedDocument = object; prohibitedDocument["profileLibraries"] = [["profileID":profileID,"library":prohibitedLibrary]]
        let prohibitedResult = ownedRecords(try repairedObject(prohibitedDocument),profileID).first
        check(prohibitedResult?["enabled"] as? Bool == false && prohibitedResult?["grants"] == nil,"A manifest's private-access prohibition cannot retain a stored private approval")
        var unsupportedRecord = approved, unsupportedGrant = approved["grants"] as! [String:Any]
        unsupportedRecord["requestedPermissions"] = ["nativeMessaging"]; unsupportedGrant["permissions"] = ["nativeMessaging"]; unsupportedRecord["grants"] = unsupportedGrant
        var unsupportedLibrary = library; unsupportedLibrary["extensions"] = [unsupportedRecord]
        var unsupportedDocument = object; unsupportedDocument["profileLibraries"] = [["profileID":profileID,"library":unsupportedLibrary]]
        let unsupportedResult = ownedRecords(try repairedObject(unsupportedDocument),profileID).first
        check(unsupportedResult?["enabled"] as? Bool == false && unsupportedResult?["grants"] == nil,"Unavailable privileged APIs remain visible declarations without a saved grant")
        var deniedRecord = approved, deniedGrant = approved["grants"] as! [String:Any]
        deniedGrant["deniedPermissions"] = ["storage"]; deniedRecord["grants"] = deniedGrant
        var deniedLibrary = library; deniedLibrary["extensions"] = [deniedRecord]
        var deniedDocument = object; deniedDocument["profileLibraries"] = [["profileID":profileID,"library":deniedLibrary]]
        let deniedResult = ownedRecords(try repairedObject(deniedDocument),profileID).first?["grants"] as? [String:Any]
        check(deniedResult?["permissions"] as? [String] == [],"Explicit API denials override conflicting stored approvals")
        var secondVersion = approved, secondGrants = approved["grants"] as! [String:Any]
        secondVersion["packageDigest"] = String(repeating:"b",count:64); secondGrants["packageDigest"] = String(repeating:"b",count:64); secondVersion["grants"] = secondGrants
        var versionsLibrary = library; versionsLibrary["extensions"] = [approved,secondVersion,secondVersion]
        var versionsDocument = object; versionsDocument["profileLibraries"] = [["profileID":profileID,"library":versionsLibrary]]
        let versions = ownedRecords(try repairedObject(versionsDocument),profileID)
        check(versions.count == 2 && Set(versions.compactMap{$0["id"] as? String}).count == 2,"Conflicting record versions are retained once under different identities")
        let remapped = versions.first(where:{$0["packageDigest"] as? String == String(repeating:"b",count:64)})
        check(remapped?["enabled"] as? Bool == false && remapped?["grants"] == nil,"A remapped extension record never inherits an approval")
        check(remapped?["packageID"] as? String == recordID,"Record collision repair preserves the controlled original package reference")
        var narrow = approved
        let narrowGrants = approved["grants"] as! [String:Any]
        narrow["hostPermissions"] = ["<all_urls>"]; narrow["grants"] = narrowGrants
        var narrowLibrary = library; narrowLibrary["extensions"] = [narrow]
        var narrowDocument = object; narrowDocument["profileLibraries"] = [["profileID":profileID,"library":narrowLibrary]]
        check(ownedRecords(try repairedObject(narrowDocument),profileID).first?["enabled"] as? Bool == true,"A deliberate site-specific grant remains valid under a declared all-sites request")
        var broadRecord = approved, broadGrants = approved["grants"] as! [String:Any]
        broadRecord["requestedPermissions"] = ["storage","tabs"]; broadGrants["permissions"] = ["storage","tabs"]; broadGrants["allowPrivate"] = true; broadRecord["grants"] = broadGrants
        var restrictedRecord = broadRecord, restrictedGrants = broadGrants; restrictedGrants["permissions"] = ["storage"]; restrictedGrants["allowPrivate"] = false; restrictedRecord["grants"] = restrictedGrants
        var mergeFirst = library, mergeOther = library; mergeFirst["extensions"] = [broadRecord]; mergeOther["extensions"] = [restrictedRecord]
        var merged = try JSONDecoder().decode(BrowserLibrary.self,from:JSONSerialization.data(withJSONObject:mergeFirst))
        let incoming = try JSONDecoder().decode(BrowserLibrary.self,from:JSONSerialization.data(withJSONObject:mergeOther))
        merged.mergePreservingRecords(incoming); merged.mergePreservingRecords(incoming)
        let mergedJSON = try JSONSerialization.jsonObject(with:JSONEncoder().encode(merged)) as! [String:Any]
        let mergedRecords = mergedJSON["extensions"] as? [[String:Any]], mergedGrants = mergedRecords?.first?["grants"] as? [String:Any]
        check(mergedRecords?.count == 1 && mergedGrants?["permissions"] as? [String] == ["storage"] && mergedGrants?["allowPrivate"] as? Bool == false,"Repeated recovery merges intersect approvals instead of escalating them")
        var unapprovedCopy = restrictedRecord; unapprovedCopy.removeValue(forKey:"grants")
        var unapprovedLibrary = library; unapprovedLibrary["extensions"] = [unapprovedCopy]
        let unapprovedIncoming = try JSONDecoder().decode(BrowserLibrary.self,from:JSONSerialization.data(withJSONObject:unapprovedLibrary))
        merged.mergePreservingRecords(unapprovedIncoming)
        let noApprovalJSON = try JSONSerialization.jsonObject(with:JSONEncoder().encode(merged)) as! [String:Any]
        let noApprovalRecord = (noApprovalJSON["extensions"] as? [[String:Any]])?.first
        check(noApprovalRecord?["enabled"] as? Bool == false && noApprovalRecord?["grants"] == nil,"Merging a revoked copy cannot leave an enabled record without approval")
        let typed = try JSONDecoder().decode(BrowserExtensionRecord.self,from:JSONSerialization.data(withJSONObject:record))
        var invalidIdentity = typed; invalidIdentity.storeID = "../../not-an-extension-id"
        check(invalidIdentity.runtimeIdentifier == typed.runtimeIdentifier,"An invalid external identity cannot become a native extension origin")
        check(typed.runtimeIdentifier.count == 32 && typed.runtimeIdentifier.utf8.allSatisfy({97...112 ~= $0}),"Unsigned runtime identities use the stable extension-ID alphabet")
        object["formatVersion"] = 6
        var future = try JSONDecoder().decode(BrowserDocument.self,from:JSONSerialization.data(withJSONObject:object))
        var rejected = false
        do { try future.repairProfiles() } catch { rejected = true }
        check(rejected,"Unknown future extension metadata is rejected")
        check(try Data(contentsOf:storage.url) == bytes,"Rejecting a future format leaves the existing ciphertext untouched")
        try runExtensionManifestChecks(check)
        try runExtensionZIPChecks(check)
        try await runExtensionPackageChecks(check)
        try runExtensionCRXChecks(check)
        exit(failures == 0 ? 0 : 1)
    }
}
