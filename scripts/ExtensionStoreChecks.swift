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
        let approval = try store.extensionInstallApproval(for:package,profileID:profile,permissions:["storage"],hostPatterns:["https://example.com/*"],enable:true)
        let id = try await store.installExtension(package,approval:approval)
        let current = store.extensionRecords(profileID:profile).first!
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
        exit(failures == 0 ? 0 : 1)
    }
}
