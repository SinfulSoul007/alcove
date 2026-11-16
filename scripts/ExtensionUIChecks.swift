import AppKit
import WebKit
import BrowserCore
import CryptoKit
import Combine

actor OwnedExtensionUITransport {
    var started = false
    private var reply:CheckedContinuation<Data,Never>?
    func fetch() async -> Data {
        started = true
        return await withCheckedContinuation {reply=$0}
    }
    func release() {reply?.resume(returning:Data("{}".utf8));reply=nil}
}

@main struct ExtensionUIChecks {
    @MainActor static func main() async throws {
        if CommandLine.arguments.count==3,CommandLine.arguments[1]=="--ownership-probe" {
            do {let lease=try MetadataOwnership.acquire(for:URL(fileURLWithPath:CommandLine.arguments[2]));lease.release();exit(0)}
            catch MetadataOwnershipError.inUse {exit(23)} catch {exit(24)}
        }
        NSApplication.shared.setActivationPolicy(.prohibited);setbuf(stdout,nil)
        guard #available(macOS 15.4,*) else {print("UNAVAILABLE: Native extension review requires macOS15.4; the browser remains usable.");return}
        let websites=try OwnedWebsiteStores(),controllers=try OwnedExtensionControllers()
        guard await controllers.cleanup(),await websites.cleanup() else {exit(1)}
        let fm=FileManager.default,root=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? fm.removeItem(at:root)}
        let key=SymmetricKey(data:Data(repeating:0x36,count:32))
        var failures=0
        func check(_ value:Bool,_ title:String) {print("\(value ? "PASS":"FAIL"): \(title)");if !value {failures+=1}}
        func rejects(_ title:String,_ body:()async throws->Void) async {
            do {try await body();check(false,title)} catch {check(true,title)}
        }
        for build in ["20621.3.11.11.3","21622.2.11","20623.1.14", "21624.1.15"] {
            check(!BrowserExtensionCompatibility.supportsPrivateRequestBlocking(webKitBuild:build),"An affected system engine \(build) cannot advertise private request blocking")
        }
        for build in ["20624.1.16","21624.5.1.11.3","20625.2.8"] {
            check(BrowserExtensionCompatibility.supportsPrivateRequestBlocking(webKitBuild:build),"A fixed system engine \(build) permits private request blocking")
        }
        for build:String? in [nil,"","21624.bad.16","21624..16","999999999999999999999999.1.16"] {
            check(!BrowserExtensionCompatibility.supportsPrivateRequestBlocking(webKitBuild:build),"An unrecognized engine build cannot claim private request blocking")
        }
        check(BrowserExtensionCompatibility.privateAccessIssue(permissions:["tabs","storage"],webKitBuild:"20621.3.11.11.3")==nil,"Basic extension private access remains available on the older native engine")
        check(BrowserExtensionCompatibility.privateAccessIssue(permissions:["declarativeNetRequestWithHostAccess"],webKitBuild:"20621.3.11.11.3") != nil,"The host-access request-blocking API has the same private compatibility boundary")
        func window(_ store:BrowserStore) -> NSWindow {
            let w=NSWindow(contentRect:NSRect(x:0,y:0,width:800,height:600),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            w.isReleasedWhenClosed=false;store.registerExtensionWindow(w,kind:.primary);return w
        }
        func ownershipStatus(_ url:URL) throws -> Int32 {
            let p=Process();p.executableURL=URL(fileURLWithPath:CommandLine.arguments[0]);p.arguments=["--ownership-probe",url.path]
            p.standardOutput=FileHandle.nullDevice;p.standardError=FileHandle.nullDevice
            try p.run();p.waitUntilExit();return p.terminationStatus
        }
        func exercise() async throws {
            let store=BrowserStore(dataRoot:root.appendingPathComponent("normal"),keyProvider:{_ in key})
            defer {store.shutdown()}
            let profile=try store.createProfile(name:"Owned UI Account A")
            try websites.register(profile);try controllers.register(store.profiles.first(where:{$0.id==profile})!.extensionControllerID!)
            let w=window(store);defer {w.close()}
            let source=root.appendingPathComponent("source")
            try fm.createDirectory(at:source,withIntermediateDirectories:true)
            func writeSource(version:String="1") throws {
                let manifest:[String:Any]=["manifest_version":3,"name":"Owned Review Fixture","description":"A disposable review fixture.","version":version,"permissions":["storage","offscreen"],"optional_permissions":["tabs"],"host_permissions":["https://example.com/*"],"content_scripts":[["matches":["https://example.com/*"],"js":["owned.js"]]]]
                try JSONSerialization.data(withJSONObject:manifest).write(to:source.appendingPathComponent("manifest.json"))
                try Data("document.documentElement.dataset.ownedReviewExecuted='yes';".utf8).write(to:source.appendingPathComponent("owned.js"))
            }
            try writeSource()
            let manager=try ExtensionManagerSession(store:store,sourceWindow:w,profileID:profile)
            defer {manager.close()}
            let before=try Data(contentsOf:store.sessionURL)
            let review=try await manager.reviewFile(source)
            check(review.manifest.name=="Owned Review Fixture" && review.manifest.version=="1","Review presents the actual immutable package identity")
            check(review.unsupportedPermissions.contains("offscreen") && !review.supportedPermissions.contains("offscreen"),"Review distinguishes declared capabilities that the native engine does not support")
            let afterReview=try Data(contentsOf:store.sessionURL)
            check(store.extensionRecords(profileID:profile).isEmpty && before == afterReview,"Preparing a review never commits a catalog entry or permissions")
            let host=store.extensionHosting as? NativeBrowserExtensionHost
            check(host?.profiles.values.allSatisfy({$0.contexts.isEmpty}) != false,"Native inspection never loads an extension context before approval")
            await rejects("An unsupported API cannot be granted through the review") {_ = try await manager.approve(review,permissions:["offscreen"],hostPatterns:[],allowPrivate:false)}
            check(store.extensionRecords(profileID:profile).isEmpty,"Rejected review rights leave the catalog untouched")
            // Browser navigation and manager selection are deliberately separate.
            let other=try store.createProfile(name:"Owned UI Account B")
            try websites.register(other);try controllers.register(store.profiles.first(where:{$0.id==other})!.extensionControllerID!)
            let id=try await manager.approve(review,permissions:["storage"],hostPatterns:["https://example.com/*"],allowPrivate:false)
            let installed=store.extensionRecords(profileID:profile).first!
            check(installed.id==id && installed.enabled && installed.grants?.allowPrivate==false && store.extensionRecords(profileID:other).isEmpty,"Approval stays in the reviewed account when the browser switches Spaces")
            await rejects("A review cannot be approved twice") {_ = try await manager.approve(review,permissions:["storage"],hostPatterns:[],allowPrivate:false)}

            let rights=try await manager.reviewInstalled(id)
            check(rights.record==installed,"Installed permission review retains the exact saved identity and source")
            await rejects("Installed permission review rejects native-unsupported choices") {try await manager.savePermissions(rights,permissions:["offscreen"],hostPatterns:[],allowPrivate:false)}
            try await manager.savePermissions(rights,permissions:["storage"],hostPatterns:["https://example.com/*"],allowPrivate:false)
            check(store.extensionRecords(profileID:profile).first==installed,"Saving unchanged permission choices preserves the original installed record")
            let oldRights=try await manager.reviewInstalled(id)
            try store.setExtensionEnabled(id,profileID:profile,enabled:false)
            await rejects("Permission review cannot overwrite an extension changed since inspection") {try await manager.savePermissions(oldRights,permissions:["storage"],hostPatterns:[],allowPrivate:false)}
            manager.cancelReview()
            try store.setExtensionEnabled(id,profileID:profile,enabled:true)
            let disabledRights=try await manager.reviewInstalled(id)
            try await manager.savePermissions(disabledRights,permissions:["storage"],hostPatterns:[],allowPrivate:false)
            check(store.extensionRecords(profileID:profile).first?.grants?.hostPatterns==[],"Permission review can revoke previously granted website access")
            let restoreRights=try await manager.reviewInstalled(id)
            try await manager.savePermissions(restoreRights,permissions:["storage"],hostPatterns:["https://example.com/*"],allowPrivate:false)

            let stale=try await manager.reviewFile(source)
            try manager.selectProfile(other)
            await rejects("Choosing another manager profile invalidates an earlier review") {_ = try await manager.approve(stale,permissions:["storage"],hostPatterns:[],allowPrivate:false)}
            check(store.extensionRecords(profileID:other).isEmpty,"A stale review never becomes an install in another account")
            try manager.selectProfile(profile)
            let tampered=try await manager.reviewFile(source)
            try Data("unreviewed bytes".utf8).write(to:tampered.package.stagingURL.appendingPathComponent("owned.js"))
            await rejects("A staged resource changed after review cannot acquire an approval") {_ = try await manager.approve(tampered,permissions:["storage"],hostPatterns:[],allowPrivate:false)}
            check(store.extensionRecords(profileID:profile).map(\.id)==[id],"Rejecting changed staging bytes never leaves an extra approved installation")
            manager.cancelReview()

            try writeSource(version:"2")
            let update=try await manager.reviewFile(source,replacing:id)
            let goodVault=store.vault,oldCiphertext=try Data(contentsOf:store.sessionURL)
            let blocked=root.appendingPathComponent("blocked-save")
            try fm.createDirectory(at:blocked,withIntermediateDirectories:true)
            store.vault=MetadataStore(url:blocked,key:key)
            await rejects("A failed review commit preserves the previous installed revision") {_ = try await manager.approve(update,permissions:["storage"],hostPatterns:[],allowPrivate:false)}
            let afterFailedUpdate=try Data(contentsOf:store.sessionURL)
            check(store.extensionRecords(profileID:profile).first==installed && oldCiphertext == afterFailedUpdate,"Failed update approval leaves both old metadata and ciphertext unchanged")
            store.vault=goodVault;store.savingEnabled=true;manager.cancelReview()

            let cancelReview=try await manager.reviewFile(source,replacing:id)
            var cancelled=false
            let cancellation=store.$extensionInstallationInProgress.dropFirst().sink {active in
                if active && !cancelled {cancelled=true;manager.cancelReview()}
            }
            await rejects("Cancellation during publication cannot publish a late approval") {_ = try await manager.approve(cancelReview,permissions:["storage"],hostPatterns:[],allowPrivate:false)}
            cancellation.cancel()
            check(cancelled && store.extensionRecords(profileID:profile).first==installed,"Cancelling an in-flight review keeps the prior working code and rights")

            let closedReview=try await manager.reviewFile(source,replacing:id)
            w.close()
            await rejects("Closing the source window invalidates the review even while its object is retained") {_ = try await manager.approve(closedReview,permissions:["storage"],hostPatterns:[],allowPrivate:false)}
            check(store.extensionRecords(profileID:profile).first==installed,"A source-window close cannot change the old extension")

            let privateRoot=root.appendingPathComponent("private")
            var privateKeyReads=0
            let privateStore=BrowserStore(isPrivate:true,dataRoot:privateRoot,keyProvider:{_ in privateKeyReads+=1;return key})
            let privateWindow=window(privateStore)
            let privateManager=try ExtensionManagerSession(store:privateStore,sourceWindow:privateWindow,profileID:privateStore.activeProfileID)
            check(!privateManager.canManage,"A private manager is read-only")
            await rejects("Private review cannot start a persistent installation") {_ = try await privateManager.reviewFile(source)}
            check(privateKeyReads==0 && !fm.fileExists(atPath:privateRoot.path),"Opening private extension controls requests no normal key and creates no data directory")
            let detachedModel=ExtensionManagerModel(session:privateManager,privateOwnerProvider:{nil})
            check(detachedModel.privateProfiles.isEmpty && privateStore.extensionHosting==nil,"A private manager without an open normal owner cannot create or silently associate one")
            detachedModel.close()
            let privateSelection=try ExtensionManagerSession(store:privateStore,sourceWindow:privateWindow,profileID:privateStore.activeProfileID)
            let normalOwner=BrowserWindowOwner(store:store)
            var privateGrant=installed.grants!;privateGrant.allowPrivate=true
            try store.setExtensionGrants(id,profileID:profile,grants:privateGrant)
            let privateModel=ExtensionManagerModel(session:privateSelection,privateOwnerProvider:{normalOwner})
            check(privateModel.privateProfiles.map(\.id)==[profile] && privateModel.privateProfileID==profile,"Private profile selection lists only the existing unlocked account with explicitly approved private extensions")
            try store.setExtensionGrants(id,profileID:profile,grants:installed.grants)
            check(privateModel.privateProfiles.isEmpty && privateStore.extensionHosting==nil && privateKeyReads==0 && !fm.fileExists(atPath:privateRoot.path),"Revoking private approval removes the candidate without attaching a controller or writing private metadata")
            privateModel.close()
            privateManager.close();privateWindow.close();privateStore.shutdown()

            let replacementWindow = window(store)
            defer { replacementWindow.close() }
            let replacementManager = try ExtensionManagerSession(store:store,sourceWindow:replacementWindow,profileID:profile)
            defer { replacementManager.close() }
            try store.setExtensionEnabled(id, profileID: profile, enabled: false)
            let disabled = store.extensionRecords(profileID: profile).first!
            var exclusions = disabled.grants!
            exclusions.deniedPermissions = ["tabs"]
            exclusions.deniedHostPatterns = ["https://example.com/private/*"]
            try store.setExtensionGrants(id, profileID: profile, grants: exclusions)
            let replacement = try await replacementManager.reviewFile(source, replacing: id)
            let replacementModel = ExtensionManagerModel(session: replacementManager)
            replacementModel.prepareChoices(manifest: replacement.manifest, supported: replacement.supportedPermissions,
                                            previous: replacement.previous)
            check(!replacementModel.permissions.contains("tabs"), "An update does not preselect a previously denied optional API")
            var unapproved = disabled
            unapproved.revokeApproval()
            replacementModel.prepareChoices(manifest: replacement.manifest, supported: replacement.supportedPermissions,
                                            previous: unapproved)
            check(replacementModel.permissions.isEmpty && replacementModel.sites.isEmpty,
                  "An unapproved extension starts a replacement review without selected access")
            var narrowed = disabled
            narrowed.grants?.hostPatterns = ["https://example.com/help/*", "https://example.com/private/*", "https://old.example/*"]
            narrowed.grants?.deniedHostPatterns = ["https://example.com/private/*"]
            narrowed.grants?.permissions.append("tabs")
            narrowed.grants?.deniedPermissions = ["tabs"]
            replacementModel.prepareChoices(manifest: replacement.manifest, supported: replacement.supportedPermissions,
                                            previous: narrowed)
            check(replacementModel.sites == ["https://example.com/help/*"] &&
                  replacementModel.websiteChoices.contains("https://example.com/help/*") &&
                  !replacementModel.websiteChoices.contains("https://old.example/*") && !replacementModel.permissions.contains("tabs"),
                  "Replacement review exposes surviving site access without preselecting denied or removed access")
            let approvedReplacement = try await replacementManager.approve(replacement, permissions: ["storage"],
                                                                           hostPatterns: ["https://example.com/*"], allowPrivate: false)
            let updated = store.extensionRecords(profileID: profile).first!
            check(approvedReplacement == id && updated.version == "2" && !updated.enabled && disabled.enabled == false,
                  "Approving a reviewed update keeps the previously disabled extension disabled")
            check(updated.grants?.deniedPermissions == ["tabs"] && updated.grants?.deniedHostPatterns == ["https://example.com/private/*"],
                  "A reviewed replacement retains exclusions inside a previously approved site")
            let updateRights = try await replacementManager.reviewInstalled(id)
            try await replacementManager.savePermissions(updateRights, permissions: ["storage"], hostPatterns: ["https://example.com/*"], allowPrivate: false)
            check(store.extensionRecords(profileID: profile).first == updated,
                  "Saving unchanged permissions after an update preserves the exclusions and disabled state")
            replacementModel.close()

            let gate=OwnedExtensionUITransport()
            let waiting=BrowserStore(dataRoot:root.appendingPathComponent("waiting"),keyProvider:{_ in key})
            let waitingProfile=try waiting.createProfile(name:"Owned Closing Review")
            try websites.register(waitingProfile);try controllers.register(waiting.profiles.first(where:{$0.id==waitingProfile})!.extensionControllerID!)
            let waitingWindow=window(waiting)
            let transport:ExtensionStoreDownload.Transport={_,_,_ in await gate.fetch()}
            let pendingManager=try ExtensionManagerSession(store:waiting,sourceWindow:waitingWindow,profileID:waitingProfile,transport:transport)
            let pending=Task {@MainActor in try await pendingManager.reviewWebStore(String(repeating:"a",count:32))}
            for _ in 0..<200 {if await gate.started {break};try await Task.sleep(for:.milliseconds(10))}
            check(await gate.started,"The owned external-transfer boundary starts the pending store review")
            waitingWindow.close();waiting.shutdown()
            check(try ownershipStatus(waiting.sessionURL)==23,"A cancelled review retains writer ownership until its actual transfer drains")
            await gate.release()
            do {_ = try await pending.value;check(false,"A late network result cannot reopen a closed review")} catch {check(true,"A late network result cannot reopen a closed review")}
            pendingManager.close()
            var released=false
            for _ in 0..<200 {if try ownershipStatus(waiting.sessionURL)==0 {released=true;break};try await Task.sleep(for:.milliseconds(10))}
            check(released && waiting.extensionRecords(profileID:waitingProfile).isEmpty,"Draining a cancelled review releases ownership without saving privileges")
        }
        do {try await exercise()}
        catch {print("FAIL: UI fixture threw: \(error)");failures+=1}
        let controllerClean=await controllers.cleanup(),websiteClean=await websites.cleanup()
        check(controllerClean && websiteClean,"Disposable UI fixture namespaces are cleaned through their owned journals")
        exit(failures==0 ? 0:1)
    }
}
