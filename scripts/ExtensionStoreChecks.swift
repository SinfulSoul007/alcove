import AppKit
import WebKit
import CryptoKit
import Combine
import BrowserCore

@main struct ExtensionStoreChecks {
    @MainActor static func main() async throws {
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--ownership-probe" {
            do {let lease = try MetadataOwnership.acquire(for:URL(fileURLWithPath:CommandLine.arguments[2])); lease.release(); exit(0)}
            catch MetadataOwnershipError.inUse {exit(23)}
            catch {exit(24)}
        }
        NSApplication.shared.setActivationPolicy(.prohibited);setbuf(stdout,nil)
        var failures = 0
        func check(_ value:Bool,_ name:String) { print("\(value ? "PASS" : "FAIL"): \(name)"); if !value { failures += 1 } }
        func rejects(_ name:String,_ body:()async throws -> Void) async { do { try await body(); check(false,name) } catch { check(true,name) } }
        let manager = FileManager.default, root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString), key = SymmetricKey(data:Data(repeating:37,count:32))
        defer { try? manager.removeItem(at:root) }
        let source = root.appendingPathComponent("source"), stage = root.appendingPathComponent("staging")
        try manager.createDirectory(at:source,withIntermediateDirectories:true)
        let manifest = Data(#"{"manifest_version":3,"name":"Owned Store Extension","version":"1","permissions":["storage"],"host_permissions":["https://example.com/*"]}"#.utf8)
        try manifest.write(to:source.appendingPathComponent("manifest.json"))
        func prepare() throws -> PreparedExtensionPackage { try ExtensionPackage.prepare(at:source,stagingRoot:stage) }
        let store = BrowserStore(dataRoot:root.appendingPathComponent("normal"),keyProvider:{_ in key})
        defer { store.shutdown() }
        let profile = try store.createProfile(name:"Owned Extension Account")
        let package = try prepare()
        func installationTime(_ record:BrowserExtensionRecord) throws -> Double? {
            (try JSONSerialization.jsonObject(with:JSONEncoder().encode(record)) as? [String:Any])?["installedAt"] as? Double
        }
        let installedAfter = Date().timeIntervalSinceReferenceDate
        let approval = try store.extensionInstallApproval(for:package,profileID:profile,permissions:["storage"],hostPatterns:["https://example.com/*"],enable:true)
        let id = try await store.installExtension(package,approval:approval)
        let current = store.extensionRecords(profileID:profile).first!
        let originalInstallation = try installationTime(current)
        check(originalInstallation.map{$0 >= installedAfter && $0 <= Date().timeIntervalSinceReferenceDate} == true,"A first install records its actual date before native loading")
        check(current.id == id && current.enabled && current.grants?.permissions == ["storage"] && current.grants?.allowPrivate == false,"Explicit installation persists the selected rights with private access off")
        check(current.grants?.recordID == id && current.grants?.controllerID == store.profiles.first(where:{$0.id == profile})?.extensionControllerID,"Installed approval is bound to its account, record and durable runtime controller")
        let disk = try MetadataStore(url:store.sessionURL,key:key).load(BrowserDocument.self)!
        check(disk.library(for:profile).extensions?.first == current && disk.library(for:BrowserProfile.defaultID).extensions?.isEmpty != false,"Extension state is encrypted under only its selected account")
        let bytes = try Data(contentsOf:store.sessionURL)
        check(bytes.range(of:Data("Owned Store Extension".utf8)) == nil && bytes.range(of:Data("example.com".utf8)) == nil,"Installer metadata does not expose names or approved sites in plaintext")
        await rejects("An install approval is single use") {_ = try await store.installExtension(package,approval:approval)}
        let reopened = BrowserStore(dataRoot:store.sessionURL.deletingLastPathComponent(),keyProvider:{_ in key})
        check(reopened.extensionRecords(profileID:profile).first == current,"Relaunch restores the installed revision and exact approval")
        reopened.shutdown()
        try store.setExtensionEnabled(id,profileID:profile,enabled:false)
        check(!store.extensionRecords(profileID:profile)[0].enabled,"Disable saves without deleting its code or selected rights")
        try store.setExtensionEnabled(id,profileID:profile,enabled:true)
        check(try installationTime(store.extensionRecords(profileID:profile)[0]) == originalInstallation && originalInstallation != nil,"Disable and re-enable preserve installation priority")
        try store.setExtensionGrants(id,profileID:profile,grants:nil)
        await rejects("Enable cannot recreate revoked rights") {try store.setExtensionEnabled(id,profileID:profile,enabled:true)}
        let grant = ExtensionGrantSet(profileID:profile,recordID:id,controllerID:current.grants!.controllerID!,packageDigest:current.packageDigest,permissions:["storage"],hostPatterns:["https://example.com/*"])
        try store.setExtensionGrants(id,profileID:profile,grants:grant)
        check(!store.extensionRecords(profileID:profile)[0].enabled,"Permission review does not implicitly re-enable a disabled extension")
        try store.setExtensionEnabled(id,profileID:profile,enabled:true)
        var overbroad = grant; overbroad.permissions = ["cookies"]
        await rejects("Undeclared API rights cannot be saved") {try store.setExtensionGrants(id,profileID:profile,grants:overbroad)}
        var wrongOwner = grant; wrongOwner.profileID = BrowserProfile.defaultID
        await rejects("Another account's approval cannot be reused") {try store.setExtensionGrants(id,profileID:profile,grants:wrongOwner)}
        try Data("new owned asset".utf8).write(to:source.appendingPathComponent("new.txt"))
        let update = try prepare(), stale = try store.extensionInstallApproval(for:update,profileID:profile,replacing:id,permissions:["storage"],enable:true)
        try store.setExtensionEnabled(id,profileID:profile,enabled:false)
        await rejects("A changed record invalidates a pending update approval") {_ = try await store.installExtension(update,replacing:id,approval:stale)}
        try update.discard()
        let disabledUpdate = try prepare(), review = try store.extensionInstallApproval(for:disabledUpdate,profileID:profile,replacing:id)
        _ = try await store.installExtension(disabledUpdate,replacing:id,approval:review)
        let changed = store.extensionRecords(profileID:profile)[0]
        check(try installationTime(changed) == originalInstallation && originalInstallation != nil,"Updating reviewed code preserves the original installation date")
        check(changed.id == id && changed.packageDigest != current.packageDigest && !changed.enabled && changed.grants == nil,"Changed code preserves its record identity and requires fresh rights")
        let unchanged = try prepare(), beforeFailure = store.extensionRecords(profileID:profile)[0]
        let failedApproval = try store.extensionInstallApproval(for:unchanged,profileID:profile,replacing:id,permissions:["storage"],enable:true)
        let validVault = store.vault, oldBytes = try Data(contentsOf:store.sessionURL)
        let blocked = root.appendingPathComponent("not-a-metadata-file"); try manager.createDirectory(at:blocked,withIntermediateDirectories:true)
        store.vault = MetadataStore(url:blocked,key:key)
        await rejects("A failed metadata save cannot publish new privileges") {_ = try await store.installExtension(unchanged,replacing:id,approval:failedApproval)}
        let afterFailure = try Data(contentsOf:store.sessionURL)
        check(store.extensionRecords(profileID:profile)[0] == beforeFailure && oldBytes == afterFailure,"Failed writes preserve the old catalog and ciphertext")
        let installedURL = store.extensionPackagesRoot.appendingPathComponent(profile.uuidString).appendingPathComponent((changed.packageID ?? changed.id).uuidString).appendingPathComponent(changed.packageDigest)
        check(manager.fileExists(atPath:installedURL.appendingPathComponent("manifest.json").path),"Failed reuse never removes an earlier immutable revision")
        try unchanged.discard(); store.vault = validVault; store.savingEnabled = true
        try manager.removeItem(at:source.appendingPathComponent("new.txt"))
        try Data("a different new revision".utf8).write(to:source.appendingPathComponent("different.txt"))
        let newRevision = try prepare(), newApproval = try store.extensionInstallApproval(for:newRevision,profileID:profile,replacing:id)
        let newPath = store.extensionPackagesRoot.appendingPathComponent(profile.uuidString).appendingPathComponent((changed.packageID ?? changed.id).uuidString).appendingPathComponent(newRevision.digest)
        store.vault = MetadataStore(url:blocked,key:key)
        await rejects("A failed new-revision save rolls back installer-owned files") {_ = try await store.installExtension(newRevision,replacing:id,approval:newApproval)}
        check(!manager.fileExists(atPath:newPath.path) && manager.fileExists(atPath:installedURL.path),"Rollback removes only this invocation's new revision")
        store.vault = validVault; store.savingEnabled = true
        try manager.removeItem(at:source.appendingPathComponent("different.txt"))
        try Data("new owned asset".utf8).write(to:source.appendingPathComponent("new.txt"))
        let browsePackage = try prepare(), browseApproval = try store.extensionInstallApproval(for:browsePackage,profileID:profile,replacing:id)
        let browsingEdit = BrowserCore.Tab(title:"Owned browsing edit",url:"https://example.invalid/during-install")
        var editedWhilePublishing = false
        let browseObserver = store.$extensionInstallationInProgress.dropFirst().sink { active in
            if active && !editedWhilePublishing {
                editedWhilePublishing = true
                store.session.spaces[store.spaceIndex].tabs.append(browsingEdit)
                store.session.spaces[store.spaceIndex].selected = browsingEdit.id
            }
        }
        _ = try await store.installExtension(browsePackage,replacing:id,approval:browseApproval)
        browseObserver.cancel(); try browsePackage.discard()
        let browsingDisk = try MetadataStore(url:store.sessionURL,key:key).load(BrowserDocument.self)!
        check(editedWhilePublishing && store.selectedID == browsingEdit.id && browsingDisk.session.spaces.contains(where:{$0.tabs.contains(where:{$0.id == browsingEdit.id})}),"Browsing edits made during publication survive the final encrypted commit")
        try manager.removeItem(at:source.appendingPathComponent("new.txt")); try Data("a different new revision".utf8).write(to:source.appendingPathComponent("different.txt"))
        let driftPackage = try prepare(), driftApproval = try store.extensionInstallApproval(for:driftPackage,profileID:profile,replacing:id)
        let profileIndex = store.profiles.firstIndex(where:{$0.id == profile})!, originalController = store.profiles.first(where:{$0.id == profile})!.extensionControllerID
        var drifted = false
        let driftObserver = store.$extensionInstallationInProgress.dropFirst().sink { active in
            if active && !drifted {drifted = true; store.profiles[profileIndex].extensionControllerID = UUID()}
        }
        await rejects("Controller changes during publication invalidate the review before metadata save") {_ = try await store.installExtension(driftPackage,replacing:id,approval:driftApproval)}
        driftObserver.cancel(); store.profiles[profileIndex].extensionControllerID = originalController
        check(drifted && store.extensionRecords(profileID:profile)[0] == changed,"A late controller mismatch preserves the previous account revision")
        try driftPackage.discard()
        let cancelledPackage = try prepare(), cancelledApproval = try store.extensionInstallApproval(for:cancelledPackage,profileID:profile,replacing:id)
        let cancelledInstall = Task {@MainActor in try await store.installExtension(cancelledPackage,replacing:id,approval:cancelledApproval)}
        cancelledInstall.cancel()
        var cancellationObserved = false
        do {_ = try await cancelledInstall.value} catch is CancellationError {cancellationObserved = true} catch {}
        check(cancellationObserved && store.extensionRecords(profileID:profile)[0] == changed,"Cancelled installation never publishes rights or replaces the current record")
        try cancelledPackage.discard()
        let resetStore = BrowserStore(dataRoot:root.appendingPathComponent("reset"),keyProvider:{_ in key})
        let resetPackage = try prepare(), resetApproval = try resetStore.extensionInstallApproval(for:resetPackage,profileID:BrowserProfile.defaultID,permissions:["storage"],enable:true)
        var resetError:Error?
        let resetObserver = resetStore.$extensionInstallationInProgress.dropFirst().sink { active in
            guard active else {return}
            do {
                var paused = resetStore.makeDocument(); paused.profiles?[0].pendingDataClear = true; try resetStore.commitProfileDocument(paused)
                var finished = resetStore.makeDocument(); finished.profiles?[0].pendingDataClear = false; try resetStore.commitProfileDocument(finished)
            } catch {resetError = error}
        }
        await rejects("A completed profile clear invalidates an earlier new-install consent") {_ = try await resetStore.installExtension(resetPackage,approval:resetApproval)}
        resetObserver.cancel(); if let resetError {throw resetError}
        check(resetStore.extensionRecords(profileID:BrowserProfile.defaultID).isEmpty,"Profile clearing cannot be followed by a late consent restoring privileges")
        try resetPackage.discard(); resetStore.shutdown()
        let closing = BrowserStore(dataRoot:root.appendingPathComponent("closing"),keyProvider:{_ in key})
        let closePackage = try prepare(), closeApproval = try closing.extensionInstallApproval(for:closePackage,profileID:BrowserProfile.defaultID)
        var ownershipStatus:Int32 = -1, closedDuringPublication = false
        let closeObserver = closing.$extensionInstallationInProgress.dropFirst().sink { active in
            if active && !closedDuringPublication {
                closedDuringPublication = true; closing.shutdown()
                let worker = Process(); worker.executableURL = URL(fileURLWithPath:CommandLine.arguments[0]); worker.arguments = ["--ownership-probe",closing.sessionURL.path]
                worker.standardOutput = FileHandle.nullDevice; worker.standardError = FileHandle.nullDevice
                do {try worker.run(); worker.waitUntilExit(); ownershipStatus = worker.terminationStatus} catch {ownershipStatus = -2}
            }
        }
        await rejects("Closing an owner during publication rejects the late install result") {_ = try await closing.installExtension(closePackage,approval:closeApproval)}
        closeObserver.cancel()
        check(closedDuringPublication && ownershipStatus == 23,"An auxiliary lease blocks a second process after the source owner shuts down")
        check(closing.extensionRecords(profileID:BrowserProfile.defaultID).isEmpty,"A closed owner cannot acquire new extension privileges")
        try closePackage.discard()
        store.clearingData = true
        await rejects("A profile operation blocks installation approval") {_ = try store.extensionInstallApproval(for:prepare(),profileID:profile)}
        store.clearingData = false
        await rejects("Missing accounts cannot receive an extension") {_ = try store.extensionInstallApproval(for:prepare(),profileID:UUID())}
        let privateRoot = root.appendingPathComponent("private"), privateStore = BrowserStore(isPrivate:true,dataRoot:privateRoot,keyProvider:{_ in check(false,"Private setup must not request a key"); return key})
        await rejects("Standalone private browsing cannot install persistent code") {_ = try privateStore.extensionInstallApproval(for:prepare(),profileID:BrowserProfile.defaultID)}
        check(!manager.fileExists(atPath:privateRoot.path),"Rejected private installation creates no saved-data directory")
        privateStore.shutdown()
        let finalGrant = ExtensionGrantSet(profileID:profile,recordID:id,controllerID:originalController!,packageDigest:changed.packageDigest,permissions:["storage"],hostPatterns:["https://example.com/*"])
        try store.setExtensionGrants(id,profileID:profile,grants:finalGrant); try store.setExtensionEnabled(id,profileID:profile,enabled:true)
        let activeBeforeRemove = store.extensionRecords(profileID:profile)[0], bytesBeforeRemove = try Data(contentsOf:store.sessionURL)
        store.vault = MetadataStore(url:blocked,key:key)
        await rejects("Failed removal intent cannot revoke a working saved record") {try store.beginRemoveExtension(id,profileID:profile)}
        let bytesAfterRejectedRemove = try Data(contentsOf:store.sessionURL)
        check(store.extensionRecords(profileID:profile)[0] == activeBeforeRemove && bytesBeforeRemove == bytesAfterRejectedRemove && manager.fileExists(atPath:installedURL.path),"Rejected removal intent keeps prior rights, ciphertext and resources")
        store.vault = validVault; store.savingEnabled = true
        try store.beginRemoveExtension(id,profileID:profile)
        check(store.extensionRecords(profileID:profile)[0].pendingRemoval == true && !store.extensionRecords(profileID:profile)[0].enabled && store.extensionRecords(profileID:profile)[0].grants == nil,"Removal durably revokes rights before resource teardown")
        await rejects("Pending removal cannot be re-enabled") {try store.setExtensionEnabled(id,profileID:profile,enabled:true)}
        var finishOwnedErasure:(@MainActor ()async->Bool)?
        if #available(macOS 15.4,*) {
            let native = try OwnedExtensionControllers(),websites = try OwnedWebsiteStores()
            guard !manager.fileExists(atPath:native.manifest.path),await websites.cleanup() else {throw CocoaError(.fileReadCorruptFile)}
            try native.register(store.profiles.first(where:{$0.id == profile})!.extensionControllerID!)
            try websites.register(profile)
            finishOwnedErasure = {let nativeClean = await native.cleanup(),websiteClean = await websites.cleanup();return nativeClean && websiteClean}
            let heldRevision = root.appendingPathComponent("held-revision"), removalOutside = root.appendingPathComponent("removal-outside")
            try manager.createDirectory(at:removalOutside,withIntermediateDirectories:true)
            try Data("keep".utf8).write(to:removalOutside.appendingPathComponent("sentinel"))
            try manager.moveItem(at:installedURL,to:heldRevision)
            try manager.createSymbolicLink(at:installedURL,withDestinationURL:removalOutside)
            await rejects("Removal cannot follow a replaced revision directory") {try await store.finishRemoveExtension(id,profileID:profile)}
            let keptOutside = try Data(contentsOf:removalOutside.appendingPathComponent("sentinel"))
            check(keptOutside == Data("keep".utf8) && store.extensionRecords(profileID:profile)[0].pendingRemoval == true,"Failed resource removal retains its retry state and outside data")
            try manager.removeItem(at:installedURL); try manager.moveItem(at:heldRevision,to:installedURL)
            store.vault = MetadataStore(url:blocked,key:key)
            await rejects("Failed finalization preserves a durable removal tombstone") {try await store.finishRemoveExtension(id,profileID:profile)}
            check(store.extensionRecords(profileID:profile)[0].pendingRemoval == true && !store.extensionRecords(profileID:profile)[0].enabled,"Interrupted finalization cannot revive old permissions")
            store.vault = validVault; store.savingEnabled = true
            try await store.finishRemoveExtension(id,profileID:profile)
            check(store.extensionRecords(profileID:profile).isEmpty && !manager.fileExists(atPath:installedURL.path),"Final removal clears its catalog record and controlled resources")
            let removedOrphans = try await store.reconcileExtensionPackages()
            check(removedOrphans > 0 && !manager.fileExists(atPath:store.extensionPackagesRoot.appendingPathComponent(profile.uuidString).path),"Serialized maintenance removes unused earlier revisions after final removal")
        } else {
            print("UNAVAILABLE: Native removal finalization requires macOS15.4; the removal tombstone stays pending.")
        }
        let closedPreview = try prepare(), closedApproval = try store.extensionInstallApproval(for:closedPreview,profileID:profile)
        store.shutdown()
        await rejects("A closed owner rejects late installation replies") {_ = try await store.installExtension(closedPreview,approval:closedApproval)}
        try closedPreview.discard()
        if let finishOwnedErasure {check(await finishOwnedErasure(),"Catalog removal fixtures release their owned native and website stores")}
        func identityExercise() async throws {
            let identityStore = BrowserStore(dataRoot:root.appendingPathComponent("identity-update"),keyProvider:{_ in key});defer {identityStore.shutdown()}
            let identityProfile = try identityStore.createProfile(name:"Owned stable identity"),identitySource = root.appendingPathComponent("identity-source")
            try manager.createDirectory(at:identitySource,withIntermediateDirectories:true);try manifest.write(to:identitySource.appendingPathComponent("manifest.json"))
            let unsigned = try ExtensionPackage.prepare(at:identitySource,stagingRoot:stage),unsignedApproval = try identityStore.extensionInstallApproval(for:unsigned,profileID:identityProfile),unsignedID = try await identityStore.installExtension(unsigned,approval:unsignedApproval)
            let signed = try ownedDownloadPackageFixture(),signedFile = root.appendingPathComponent("owned-signed-identity.crx")
            try signed.bytes.write(to:signedFile)
            let signedPackage = try ExtensionPackage.prepare(at:signedFile,stagingRoot:stage),beforeIdentity = identityStore.extensionRecords(profileID:identityProfile),identityBytes = try Data(contentsOf:identityStore.sessionURL)
            await rejects("An update cannot switch an unsigned record into a different signed runtime identity") {_ = try identityStore.extensionInstallApproval(for:signedPackage,profileID:identityProfile,replacing:unsignedID)}
            let afterIdentityBytes = try Data(contentsOf:identityStore.sessionURL)
            check(identityStore.extensionRecords(profileID:identityProfile) == beforeIdentity && afterIdentityBytes == identityBytes,"A rejected identity change preserves the original record and encrypted metadata")
            let signedApproval = try identityStore.extensionInstallApproval(for:signedPackage,profileID:identityProfile),signedID = try await identityStore.installExtension(signedPackage,approval:signedApproval)
            let originalSigned = identityStore.extensionRecords(profileID:identityProfile).first(where:{$0.id == signedID})!
            let unsignedRecord = identityStore.extensionRecords(profileID:identityProfile).first(where:{$0.id == unsignedID})!
            let unsignedTime = try installationTime(unsignedRecord),signedTime = try installationTime(originalSigned)
            check(!originalSigned.enabled && unsignedTime != nil && signedTime.map{$0 > (unsignedTime ?? .infinity)} == true,"New disabled installations receive later priority without first being loaded")
            try signed.updatedBytes.write(to:signedFile)
            let revision = try ExtensionPackage.prepare(at:signedFile,stagingRoot:stage),revisionApproval = try identityStore.extensionInstallApproval(for:revision,profileID:identityProfile,replacing:signedID)
            try await identityStore.installExtension(revision,replacing:signedID,approval:revisionApproval)
            let updatedSigned = identityStore.extensionRecords(profileID:identityProfile).first(where:{$0.id == signedID})!
            check(try installationTime(updatedSigned) == signedTime && signedTime != nil,"Updating a never-enabled extension preserves its installation priority")
            check(updatedSigned.version == "2" && updatedSigned.runtimeIdentifier == signed.id && updatedSigned.packageDigest != originalSigned.packageDigest,"A genuine signed update changes its reviewed code while keeping the same runtime identity")
            let futureInstallation = Date(timeIntervalSinceNow:3600).timeIntervalSinceReferenceDate
            var futureJSON = try JSONSerialization.jsonObject(with:JSONEncoder().encode(updatedSigned)) as! [String:Any]
            futureJSON["installedAt"] = futureInstallation
            let futureRecord = try JSONDecoder().decode(BrowserExtensionRecord.self,from:JSONSerialization.data(withJSONObject:futureJSON))
            var futureDocument = identityStore.makeDocument(),futureLibrary = futureDocument.library(for:identityProfile)
            let futureIndex = futureLibrary.extensions!.firstIndex(where:{$0.id == signedID})!
            futureLibrary.extensions![futureIndex] = futureRecord;futureDocument.setLibrary(futureLibrary,for:identityProfile)
            try identityStore.commitProfileDocument(futureDocument)
            let laterPackage = try ExtensionPackage.prepare(at:identitySource,stagingRoot:stage)
            let laterApproval = try identityStore.extensionInstallApproval(for:laterPackage,profileID:identityProfile)
            let laterID = try await identityStore.installExtension(laterPackage,approval:laterApproval)
            let laterRecord = identityStore.extensionRecords(profileID:identityProfile).first(where:{$0.id == laterID})!
            check(try installationTime(laterRecord).map{$0 > futureInstallation} == true,"A later install keeps priority when the system clock has moved backward")
            let earlyReviewPackage = try ExtensionPackage.prepare(at:identitySource,stagingRoot:stage)
            let lateReviewPackage = try ExtensionPackage.prepare(at:identitySource,stagingRoot:stage)
            let earlyReview = try identityStore.extensionInstallApproval(for:earlyReviewPackage,profileID:identityProfile)
            let lateReview = try identityStore.extensionInstallApproval(for:lateReviewPackage,profileID:identityProfile)
            let firstCommit = try await identityStore.installExtension(lateReviewPackage,approval:lateReview)
            let secondCommit = try await identityStore.installExtension(earlyReviewPackage,approval:earlyReview)
            let committed = identityStore.extensionRecords(profileID:identityProfile)
            let firstTime = try installationTime(committed.first(where:{$0.id == firstCommit})!)
            let secondTime = try installationTime(committed.first(where:{$0.id == secondCommit})!)
            check(firstTime != nil && secondTime.map{$0 > (firstTime ?? .infinity)} == true,"Installation priority follows completed installs when reviews finish out of order")
            var boundaryJSON = try JSONSerialization.jsonObject(with:JSONEncoder().encode(updatedSigned)) as! [String:Any]
            boundaryJSON["installedAt"] = Date.distantFuture.addingTimeInterval(-0.0002).timeIntervalSinceReferenceDate
            let boundaryRecord = try JSONDecoder().decode(BrowserExtensionRecord.self,from:JSONSerialization.data(withJSONObject:boundaryJSON))
            var boundaryDocument = identityStore.makeDocument(),boundaryLibrary = boundaryDocument.library(for:identityProfile)
            let boundaryIndex = boundaryLibrary.extensions!.firstIndex(where:{$0.id == signedID})!
            boundaryLibrary.extensions![boundaryIndex] = boundaryRecord;boundaryDocument.setLibrary(boundaryLibrary,for:identityProfile)
            try identityStore.commitProfileDocument(boundaryDocument)
            let beforeBoundaryInstall = identityStore.extensionRecords(profileID:identityProfile)
            let boundaryPackage = try ExtensionPackage.prepare(at:identitySource,stagingRoot:stage)
            let boundaryApproval = try identityStore.extensionInstallApproval(for:boundaryPackage,profileID:identityProfile)
            let boundaryID = try await identityStore.installExtension(boundaryPackage,approval:boundaryApproval)
            let boundaryCatalog = identityStore.extensionRecords(profileID:identityProfile)
            let newest = boundaryCatalog.first(where:{$0.id == boundaryID})!,prior = boundaryCatalog.filter{$0.id != boundaryID}
            check(newest.validInstallationDate.map{date in prior.allSatisfy{$0.validInstallationDate.map{date > $0} == true}} == true,"An actual install after upper-bound recovery remains newest after encrypted commit")
            func withoutDates(_ records:[BrowserExtensionRecord]) -> [BrowserExtensionRecord] {
                records.map{var value = $0;value.installedAt = nil;return value}
            }
            check(withoutDates(boundaryCatalog.filter{$0.id != boundaryID}) == withoutDates(beforeBoundaryInstall),"Boundary recovery changes no existing identity, code revision or approval")
        }
        try await identityExercise()
        exit(failures == 0 ? 0 : 1)
    }
}
