import AppKit
import WebKit
import CryptoKit
import BrowserCore

enum OwnedExtensionErasureError:Error {case missingFixture,timedOut}
@main struct ExtensionErasureChecks {
    @MainActor static func wait(_ operation:()async throws->Bool) async throws {for _ in 0..<700 {if try await operation() {return};try await Task.sleep(for:.milliseconds(10))};throw OwnedExtensionErasureError.timedOut}
    @MainActor static func js(_ web:WKWebView,_ script:String) async throws -> Any? {try await web.callAsyncJavaScript(script,arguments:[:],in:nil,contentWorld:.page)}
    @available(macOS 15.4,*) @MainActor static func page(_ context:WKWebExtensionContext) async throws -> WKWebView {
        try await context.loadBackgroundContent()
        guard let configuration = context.webViewConfiguration else {throw OwnedExtensionErasureError.missingFixture}
        let web = WKWebView(frame:.zero,configuration:configuration);web.load(URLRequest(url:context.baseURL.appendingPathComponent("probe.html")))
        try await wait{(try? await web.evaluateJavaScript("window.ownedErasureReady === true")) as? Bool == true}
        try await wait{(try await js(web,"return (await browser.storage.session.get('ownedErasureReadiness')).ownedErasureReadiness === 'ready';")) as? Bool == true}
        return web
    }
    @MainActor static func main() async throws {
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--ownership-probe" {
            do {let lease = try MetadataOwnership.acquire(for:URL(fileURLWithPath:CommandLine.arguments[2]));lease.release();exit(0)}
            catch MetadataOwnershipError.inUse {exit(23)}
            catch {exit(24)}
        }
        NSApplication.shared.setActivationPolicy(.prohibited);setbuf(stdout,nil)
        guard #available(macOS 15.4,*) else {print("UNAVAILABLE: Native erasure fixtures require macOS15.4.");return}
        let owned = try OwnedWebsiteStores(),controllers = try OwnedExtensionControllers()
        guard !FileManager.default.fileExists(atPath:controllers.manifest.path) else {print("FAIL: Finish the previous owned erasure fixture's recorded recovery before rerunning.");exit(1)}
        guard await owned.cleanup() else {exit(1)}
        guard let address = ProcessInfo.processInfo.environment["ALCOVE_EXTENSION_FIXTURE_URL"],let fixture = URL(string:address) else {throw OwnedExtensionErasureError.missingFixture}
        let manager = FileManager.default,root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString),key = SymmetricKey(data:Data(repeating:179,count:32))
        var failures = 0,nativeCleanupSafe = false
        func check(_ value:Bool,_ name:String) {print("\(value ? "PASS" : "FAIL"): \(name)");if !value {failures += 1}}
        func exercise() async throws {
            let normal = BrowserStore(dataRoot:root.appendingPathComponent("normal"),keyProvider:{_ in key})
            defer {normal.shutdown()}
            let profile = try normal.createProfile(name:"Owned uninstall account"),controllerID = normal.profiles.first(where:{$0.id == profile})!.extensionControllerID!
            try owned.register(profile);try controllers.register(controllerID)
            let source = root.appendingPathComponent("source")
            try manager.createDirectory(at:source,withIntermediateDirectories:true)
            try Data(#"{"manifest_version":3,"name":"Owned uninstall","description":"Generated erasure fixture","version":"1","permissions":["storage","scripting","declarativeNetRequest"],"host_permissions":["http://127.0.0.1/*"],"background":{"scripts":["bootstrap.js"],"persistent":false},"options_page":"probe.html"}"#.utf8).write(to:source.appendingPathComponent("manifest.json"))
            try Data("<!doctype html><script src='probe.js'></script>Owned erasure".utf8).write(to:source.appendingPathComponent("probe.html"))
            try Data("window.ownedErasureReady=true;".utf8).write(to:source.appendingPathComponent("probe.js"))
            try Data("document.documentElement.dataset.ownedUninstallScript='ran';".utf8).write(to:source.appendingPathComponent("registered.js"))
            try Data("/* Generated inert readiness resource */".utf8).write(to:source.appendingPathComponent("sentinel.js"))
            try Data("(async()=>{let id='owned-readiness-'+String(Math.random());await browser.scripting.registerContentScripts([{id,matches:['https://owned-readiness.invalid/*'],js:['sentinel.js'],persistAcrossSessions:true}]);await browser.scripting.unregisterContentScripts({ids:[id]});await browser.storage.session.set({ownedErasureReadiness:'ready'})})();".utf8).write(to:source.appendingPathComponent("bootstrap.js"))
            let package = try ExtensionPackage.prepare(at:source,stagingRoot:root.appendingPathComponent("staging")),approval = try normal.extensionInstallApproval(for:package,profileID:profile,permissions:["storage","scripting","declarativeNetRequest"],hostPatterns:["http://127.0.0.1/*"],enable:true)
            let id = try await normal.installExtension(package,approval:approval);try await normal.prepareExtensions(profileID:profile)
            let record = normal.extensionRecords(profileID:profile).first!,server = normal.extensionHosting as! NativeBrowserExtensionHost,context = server.profiles[profile]!.contexts[id]!,api = try await page(context)
            let dataStore = normal.websiteDataStore(forProfile:profile)
            try JSONSerialization.data(withJSONObject:["controller":controllerID.uuidString,"runtime":record.runtimeIdentifier,"website":profile.uuidString],options:.sortedKeys).write(to:root.appendingPathComponent("owned-identities.json"))
            let seedIDB = "await new Promise((resolve,reject)=>{let r=indexedDB.open('owned-uninstall',1);r.onupgradeneeded=()=>r.result.createObjectStore('items');r.onerror=()=>reject(r.error);r.onsuccess=()=>{let d=r.result,t=d.transaction('items','readwrite');t.objectStore('items').put('private fixture value','key');t.oncomplete=()=>{d.close();resolve(true)};t.onerror=()=>{d.close();reject(t.error)}}});"
            _ = try await js(api,"await browser.storage.local.set({owned:'local'});await browser.storage.sync.set({owned:'sync'});localStorage.setItem('owned-origin','retire');"+seedIDB+"await browser.scripting.registerContentScripts([{id:'owned-installed-script',matches:['http://127.0.0.1/*'],js:['registered.js'],persistAcrossSessions:true,runAt:'document_end'}]);await browser.declarativeNetRequest.updateDynamicRules({addRules:[{id:917,priority:1,action:{type:'block'},condition:{urlFilter:'/owned-uninstall-deny',resourceTypes:['xmlhttprequest']}}]});return true;")
            let websiteID = normal.newTab(url:fixture),website = normal.view(for:websiteID)
            try await wait{(try? await website.evaluateJavaScript("document.body?.dataset.ownedExtensionPage === 'ready' && document.documentElement.dataset.ownedUninstallScript === 'ran'")) as? Bool == true}
            _ = try await website.evaluateJavaScript("document.getElementById('owned-form').value='keep unrelated live form';document.cookie='owned_uninstall_website=keep; path=/';true")
            check((try await js(website,"try{await fetch('/owned-uninstall-deny');return false}catch{return (await fetch('/owned-uninstall-control')).ok}")) as? Bool == true,"The actual installed extension injects its registered script and blocks a real loopback request before removal")
            try normal.beginRemoveExtension(id,profileID:profile)
            check(normal.extensionRecords(profileID:profile).first?.pendingRemoval == true && context.isLoaded == false,"Removal first persists its tombstone and unloads the approved native context")
            // Reproduce a previously interrupted app-owned cleanup. Its saved
            // script names a resource absent from the current installed package.
            let priorSource = root.appendingPathComponent("interrupted-cleanup")
            try manager.createDirectory(at:priorSource,withIntermediateDirectories:true)
            for name in ["probe.html","probe.js","bootstrap.js","sentinel.js","registered.js"] {try Data(contentsOf:source.appendingPathComponent(name)).write(to:priorSource.appendingPathComponent(name))}
            var priorManifest = try JSONSerialization.jsonObject(with:Data(contentsOf:source.appendingPathComponent("manifest.json"))) as! [String:Any]
            priorManifest["version"] = "2"
            try JSONSerialization.data(withJSONObject:priorManifest,options:.sortedKeys).write(to:priorSource.appendingPathComponent("manifest.json"))
            try Data("/* Generated retired cleanup resource */".utf8).write(to:priorSource.appendingPathComponent("retired-owned.js"))
            let priorConfiguration = WKWebExtensionController.Configuration(identifier:controllerID);priorConfiguration.defaultWebsiteDataStore = dataStore
            let priorBackground = WKWebViewConfiguration();priorBackground.websiteDataStore = dataStore;priorConfiguration.webViewConfiguration = priorBackground
            let priorController = WKWebExtensionController(configuration:priorConfiguration),priorObject = try await WKWebExtension(resourceBaseURL:priorSource),prior = WKWebExtensionContext(for:priorObject)
            prior.uniqueIdentifier = record.runtimeIdentifier;prior.baseURL = context.baseURL
            prior.grantedPermissions = Dictionary(uniqueKeysWithValues:["storage","scripting","declarativeNetRequest"].map{(WKWebExtension.Permission(rawValue:$0),Date.distantFuture)})
            try priorController.load(prior);defer {if prior.isLoaded {try? priorController.unload(prior)}}
            let priorAPI = try await page(prior)
            _ = try await js(priorAPI,"await browser.scripting.registerContentScripts([{id:'owned-interrupted-registration',matches:['https://owned-retired.invalid/*'],js:['retired-owned.js'],persistAcrossSessions:true}]);return true;")
            try priorController.unload(prior)
            let receipt = try await normal.finishRemoveExtension(id,profileID:profile)
            // Match the actual last native version, so loading this readback cannot
            // erase a leftover registration merely by being a version update.
            var readbackManifest = priorManifest;readbackManifest["version"] = receipt.lastNativeVersion
            try JSONSerialization.data(withJSONObject:readbackManifest,options:.sortedKeys).write(to:source.appendingPathComponent("manifest.json"))
            try Data("/* Generated retired cleanup resource */".utf8).write(to:source.appendingPathComponent("retired-owned.js"))
            let configuration = WKWebExtensionController.Configuration(identifier:controllerID);configuration.defaultWebsiteDataStore = dataStore
            let background = WKWebViewConfiguration();background.websiteDataStore = dataStore;configuration.webViewConfiguration = background
            let restoredController = WKWebExtensionController(configuration:configuration),object = try await WKWebExtension(resourceBaseURL:source),restored = WKWebExtensionContext(for:object)
            restored.uniqueIdentifier = record.runtimeIdentifier;restored.baseURL = context.baseURL
            restored.grantedPermissions = Dictionary(uniqueKeysWithValues:["storage","scripting","declarativeNetRequest"].map{(WKWebExtension.Permission(rawValue:$0),Date.distantFuture)})
            restored.grantedPermissionMatchPatterns = [try WKWebExtension.MatchPattern(string:"http://127.0.0.1/*"):Date.distantFuture]
            try restoredController.load(restored);defer {if restored.isLoaded {try? restoredController.unload(restored)}}
            let restoredAPI = try await page(restored)
            check((try await js(restoredAPI,"return Object.keys(await browser.storage.local.get(null)).length === 0 && Object.keys(await browser.storage.sync.get(null)).length === 0;")) as? Bool == true,"Finished removal leaves no native local or synchronized settings when the original identity is reloaded")
            check((try await js(restoredAPI,"return (await browser.scripting.getRegisteredContentScripts()).length === 0;")) as? Bool == true,"Finished removal leaves no saved registered content scripts in the original namespace")
            check((try await js(restoredAPI,"return (await browser.declarativeNetRequest.getDynamicRules()).length === 0;")) as? Bool == true,"Finished removal leaves no dynamic request rules in the original namespace")
            check((try await js(restoredAPI,"return localStorage.getItem('owned-origin') === null && (await indexedDB.databases()).length === 0;")) as? Bool == true,"Finished removal leaves no extension-origin localStorage or IndexedDB data")
            check((try await js(website,"return document.getElementById('owned-form').value === 'keep unrelated live form' && document.cookie.includes('owned_uninstall_website=keep');")) as? Bool == true,"Removing an extension preserves the ordinary website's real form and cookie")
            // Recovery executes only this generated original fixture, so even RED runs
            // remove their real rules, registered scripts and origin data before exit.
            _ = try await js(restoredAPI,"await browser.scripting.unregisterContentScripts();let rules=await browser.declarativeNetRequest.getDynamicRules();await browser.declarativeNetRequest.updateDynamicRules({removeRuleIds:rules.map(r=>r.id)});localStorage.clear();for(let database of await indexedDB.databases()){await new Promise((resolve,reject)=>{let r=indexedDB.deleteDatabase(database.name);r.onsuccess=()=>resolve(true);r.onerror=()=>reject(r.error)})}return true;")
            try restoredController.unload(restored);nativeCleanupSafe = true
        }
        func lifetimeExercise(cancelWaiter:Bool,failFinalSave:Bool = false) async throws {
            nativeCleanupSafe = false
            let dataRoot = root.appendingPathComponent(failFinalSave ? "failed-final-save" : (cancelWaiter ? "cancelled-waiter" : "closed-owner")),normal = BrowserStore(dataRoot:dataRoot,keyProvider:{_ in key})
            defer {normal.shutdown()}
            let profile = try normal.createProfile(name:"Owned lifetime account"),controllerID = normal.profiles.first(where:{$0.id == profile})!.extensionControllerID!
            try owned.register(profile);try controllers.register(controllerID)
            let package = try ExtensionPackage.prepare(at:root.appendingPathComponent("source"),stagingRoot:root.appendingPathComponent("lifetime-staging")),approval = try normal.extensionInstallApproval(for:package,profileID:profile,permissions:["storage","scripting","declarativeNetRequest"],enable:true)
            let id = try await normal.installExtension(package,approval:approval);try await normal.prepareExtensions(profileID:profile)
            let context = (normal.extensionHosting as! NativeBrowserExtensionHost).profiles[profile]!.contexts[id]!,api = try await page(context)
            try normal.beginRemoveExtension(id,profileID:profile)
            _ = try await js(api,"return await new Promise((resolve,reject)=>{let request=indexedDB.open('owned-lifetime',1);request.onupgradeneeded=()=>request.result.createObjectStore('items');request.onerror=()=>reject(request.error);request.onsuccess=()=>{window.ownedHeldDatabase=request.result;window.ownedRemovalRequested=false;request.result.onversionchange=()=>{window.ownedRemovalRequested=true};resolve(true)}});")
            var outcome:Result<ExtensionErasureReceipt,Error>?
            let removal = Task { @MainActor in do {outcome = .success(try await normal.finishRemoveExtension(id,profileID:profile))} catch {outcome = .failure(error)} }
            do {
                try await wait{(try? await api.evaluateJavaScript("window.ownedRemovalRequested === true")) as? Bool == true}
                check(outcome == nil && ExtensionErasureJobs.holds(controllerID),"An actual held database keeps the erasure worker and its account namespace owned")
                if failFinalSave {
                    let blocked = root.appendingPathComponent("blocked-final-save",isDirectory:true)
                    try manager.createDirectory(at:blocked,withIntermediateDirectories:true)
                    normal.vault = MetadataStore(url:blocked,key:key)
                    _ = try await api.evaluateJavaScript("window.ownedHeldDatabase.close();window.ownedHeldDatabase=null;true")
                    await removal.value
                    let failed:Bool;if case .failure = outcome {failed = true} else {failed = false}
                    let saved = try MetadataStore(url:normal.sessionURL,key:key).load(BrowserDocument.self)!,pending = saved.library(for:profile).extensions!.first!
                    let installed = normal.extensionPackagesRoot.appendingPathComponent(profile.uuidString).appendingPathComponent((pending.packageID ?? pending.id).uuidString).appendingPathComponent(pending.packageDigest)
                    check(failed && !normal.savingEnabled && pending.pendingRemoval == true && pending.grants == nil && manager.fileExists(atPath:installed.path),"A failed final removal save retains its encrypted tombstone, revoked approval and installed resources for retry")
                    check(!ExtensionErasureJobs.holds(controllerID) && saved.profiles?.first(where:{$0.id == profile})?.extensionControllerID == controllerID,"Terminal erasure releases its worker after a final-save failure without rotating the saved account namespace")
                    normal.shutdown()
                    let replacement = BrowserStore(dataRoot:dataRoot,keyProvider:{_ in key});defer {replacement.shutdown()}
                    try await replacement.finishRemoveExtension(id,profileID:profile)
                    check(replacement.extensionRecords(profileID:profile).isEmpty && !manager.fileExists(atPath:installed.path),"A fresh metadata owner can finish the failed-save removal and clean its original controlled package")
                } else if cancelWaiter {
                    removal.cancel();await Task.yield()
                    check(outcome == nil && ExtensionErasureJobs.holds(controllerID) && normal.extensionRecords(profileID:profile).first?.pendingRemoval == true,"Cancelling the UI waiter cannot finalize removal or release its still-blocked native worker")
                    _ = try await api.evaluateJavaScript("window.ownedHeldDatabase.close();window.ownedHeldDatabase=null;true")
                    await removal.value
                    let cancelled:Bool
                    if case .failure(let error) = outcome {cancelled = error is CancellationError} else {cancelled = false}
                    check(cancelled && !ExtensionErasureJobs.holds(controllerID) && normal.extensionRecords(profileID:profile).first?.pendingRemoval == true,"Only terminal native completion releases the namespace; a cancelled waiter leaves its durable retry entry")
                    try await normal.finishRemoveExtension(id,profileID:profile)
                    check(normal.extensionRecords(profileID:profile).isEmpty,"A fresh explicit retry completes a cancelled removal without reviving its approval")
                } else {
                    normal.shutdown()
                    let probe = Process();probe.executableURL = URL(fileURLWithPath:CommandLine.arguments[0]);probe.arguments = ["--ownership-probe",normal.sessionURL.path]
                    probe.standardOutput = FileHandle.nullDevice;probe.standardError = FileHandle.nullDevice
                    try probe.run();probe.waitUntilExit()
                    check(probe.terminationStatus == 23 && ExtensionErasureJobs.holds(controllerID),"Closing the normal store keeps its file-writer lease held against another process until native deletion finishes")
                    let replacement = BrowserStore(dataRoot:dataRoot,keyProvider:{_ in key})
                    defer {replacement.shutdown()}
                    check(replacement.savingEnabled && !replacement.awaitingInitialMetadata && replacement.extensionRecords(profileID:profile).first?.pendingRemoval == true,"A replacement in-process owner can recover the saved removal entry while the scoped worker stays alive")
                    var clearRefused = false
                    do {try await replacement.clearProfileData(profile)} catch ExtensionErasureError.busy {clearRefused = true}
                    check(clearRefused && replacement.profiles.first(where:{$0.id == profile})?.isPendingClear == false,"A replacement owner cannot clear or rotate a profile namespace still used by an erasure worker")
                    try replacement.renameProfile(profile,name:"Replacement owner kept")
                    let replacementBytes = try Data(contentsOf:replacement.sessionURL)
                    _ = try await api.evaluateJavaScript("window.ownedHeldDatabase.close();window.ownedHeldDatabase=null;true")
                    await removal.value
                    let closed:Bool
                    if case .failure(let error) = outcome {closed = error is CancellationError} else {closed = false}
                    let after = try Data(contentsOf:replacement.sessionURL)
                    check(closed && !ExtensionErasureJobs.holds(controllerID) && after == replacementBytes && replacement.profiles.first(where:{$0.id == profile})?.name == "Replacement owner kept","A closed owner's late erasure result cannot overwrite its replacement owner's actual ciphertext")
                    try await replacement.finishRemoveExtension(id,profileID:profile)
                    check(replacement.extensionRecords(profileID:profile).isEmpty,"The replacement owner can explicitly finish removal after the old native worker reaches its terminal result")
                }
                nativeCleanupSafe = true
            } catch {
                _ = try? await api.evaluateJavaScript("window.ownedHeldDatabase?.close();window.ownedHeldDatabase=null;true")
                await removal.value
                throw error
            }
        }
        func damagedPackageExercise(missing:Bool) async throws {
            nativeCleanupSafe = false
            let normal = BrowserStore(dataRoot:root.appendingPathComponent(missing ? "missing-package" : "damaged-package"),keyProvider:{_ in key})
            defer {normal.shutdown()}
            let profile = try normal.createProfile(name:"Owned damaged account"),controllerID = normal.profiles.first(where:{$0.id == profile})!.extensionControllerID!
            try owned.register(profile);try controllers.register(controllerID)
            let source = root.appendingPathComponent("source"),package = try ExtensionPackage.prepare(at:source,stagingRoot:root.appendingPathComponent("damaged-staging")),approval = try normal.extensionInstallApproval(for:package,profileID:profile,permissions:["storage","scripting","declarativeNetRequest"],enable:true)
            let id = try await normal.installExtension(package,approval:approval);try await normal.prepareExtensions(profileID:profile)
            let record = normal.extensionRecords(profileID:profile).first!,context = (normal.extensionHosting as! NativeBrowserExtensionHost).profiles[profile]!.contexts[id]!,api = try await page(context)
            let installed = try ExtensionPackage.inspectInstalled(record:record,profileID:profile,packagesRoot:normal.extensionPackagesRoot),script = installed.url.appendingPathComponent("probe.js"),original = try Data(contentsOf:script)
            _ = try await js(api,"await browser.storage.local.set({owned:'remove despite damaged package'});localStorage.setItem('owned-damaged-origin','remove');return true;")
            try normal.beginRemoveExtension(id,profileID:profile)
            if missing {try ExtensionPackage.removeRevision(profileID:profile,extensionID:record.packageID ?? record.id,digest:record.packageDigest,packagesRoot:normal.extensionPackagesRoot)}
            else {try Data("window.ownedDamagedCodeRan=true;".utf8).write(to:script)}
            var removed = false
            do {try await normal.finishRemoveExtension(id,profileID:profile);removed = true} catch {
                if ExtensionErasureJobs.holds(controllerID) {throw error}
            }
            check(removed,missing ? "A missing installed package cannot prevent removal of its persistent extension data" : "A changed installed script can be removed without executing or trusting its new code")
            if !removed {
                if missing {
                    let replacement = try ExtensionPackage.prepare(at:source,stagingRoot:root.appendingPathComponent("damaged-recovery"))
                    _ = try ExtensionPackage.publish(replacement,profileID:profile,extensionID:record.packageID ?? record.id,packagesRoot:normal.extensionPackagesRoot)
                } else {try original.write(to:script)}
                try await normal.finishRemoveExtension(id,profileID:profile)
            }
            let configuration = WKWebExtensionController.Configuration(identifier:controllerID);configuration.defaultWebsiteDataStore = .nonPersistent()
            let background = WKWebViewConfiguration();background.websiteDataStore = configuration.defaultWebsiteDataStore;configuration.webViewConfiguration = background
            let inspector = WKWebExtensionController(configuration:configuration),types = WKWebExtensionController.allExtensionDataTypes.subtracting([.session]),remaining = await inspector.dataRecords(ofTypes:types).filter{$0.uniqueIdentifier == record.runtimeIdentifier}
            let noDOMData = (try await api.evaluateJavaScript("localStorage.getItem('owned-damaged-origin') === null && window.ownedDamagedCodeRan === undefined")) as? Bool
            check(remaining.allSatisfy{$0.errors.isEmpty && $0.totalSizeInBytes == 0} && noDOMData == true && normal.extensionRecords(profileID:profile).isEmpty,"Damaged-package removal erases the actual native/origin data, keeps changed code unexecuted and finalizes its saved record")
            nativeCleanupSafe = true
        }
        func profileClearExercise() async throws {
            nativeCleanupSafe = false
            let normal = BrowserStore(dataRoot:root.appendingPathComponent("profile-clear"),keyProvider:{_ in key}),owner = BrowserWindowOwner(store:normal),primary = try owner.acquirePrimary(),profile = try normal.createProfile(name:"Owned complete clear")
            defer {owner.release(primary);normal.shutdown()}
            let controllerID = normal.profiles.first(where:{$0.id == profile})!.extensionControllerID!
            try owned.register(profile);try controllers.register(controllerID)
            let source = root.appendingPathComponent("source"),package = try ExtensionPackage.prepare(at:source,stagingRoot:root.appendingPathComponent("clear-staging")),approval = try normal.extensionInstallApproval(for:package,profileID:profile,permissions:["storage","scripting","declarativeNetRequest"],allowPrivate:true,enable:true)
            let id = try await normal.installExtension(package,approval:approval);try await normal.prepareExtensions(profileID:profile)
            let record = normal.extensionRecords(profileID:profile).first!,context = (normal.extensionHosting as! NativeBrowserExtensionHost).profiles[profile]!.contexts[id]!,api = try await page(context),dataStore = normal.websiteDataStore(forProfile:profile)
            _ = try await js(api,"await browser.storage.local.set({owned:'clear this account'});await browser.storage.sync.set({owned:'clear sync'});localStorage.setItem('owned-profile-origin','clear');return true;")
            let orphanID = UUID().uuidString.lowercased()
            func seedOrphan() async throws {
                let object = try await WKWebExtension(resourceBaseURL:source),orphan = WKWebExtensionContext(for:object),native = context.webExtensionController!
                orphan.uniqueIdentifier = orphanID;orphan.baseURL = URL(string:"webkit-extension://"+orphanID+"/")!
                orphan.grantedPermissions = Dictionary(uniqueKeysWithValues:["storage","scripting","declarativeNetRequest"].map{(WKWebExtension.Permission(rawValue:$0),Date.distantFuture)})
                try native.load(orphan);defer {if orphan.isLoaded {try? native.unload(orphan)}}
                let orphanPage = try await page(orphan)
                _ = try await js(orphanPage,"await browser.storage.local.set({orphan:'remove interrupted install'});await browser.storage.sync.set({orphan:'remove synchronized orphan'});localStorage.setItem('owned-orphan-origin','remove');return true;")
            }
            try await seedOrphan()
            var privateKeyRequests = 0
            let client = BrowserStore(isPrivate:true,dataRoot:root.appendingPathComponent("clear-private"),keyProvider:{_ in privateKeyRequests += 1;throw CocoaError(.fileReadNoPermission)})
            defer {client.shutdown()}
            try client.associateExtensions(with:owner,profileID:profile)
            let privateID = client.selectedID!,privateURL = fixture.appendingPathComponent("private-form-during-profile-clear"),privateWeb = client.view(for:privateID)
            client.update(privateID){$0.url = privateURL.absoluteString};privateWeb.load(URLRequest(url:privateURL))
            try await wait{(try? await privateWeb.evaluateJavaScript("document.body?.dataset.ownedExtensionPage === 'ready'")) as? Bool == true}
            _ = try await privateWeb.evaluateJavaScript("document.getElementById('owned-form').value='retain private form';document.cookie='owned_clear_private=keep; path=/';true")
            let window = NSWindow(contentRect:NSRect(x:0,y:0,width:600,height:400),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            window.isReleasedWhenClosed = false;window.contentView = privateWeb;client.registerExtensionWindow(window,kind:.primary)
            defer {client.unregisterExtensionWindow(kind:.primary);window.contentView = nil;window.close()}
            try await normal.clearProfileData(profile)
            let nextControllerID = normal.profiles.first(where:{$0.id == profile})!.extensionControllerID!
            try controllers.register(nextControllerID)
            check(nextControllerID != controllerID && normal.profiles.first(where:{$0.id == profile})?.isPendingClear == false,"A completed profile clear rotates its native namespace only after successful data removal")
            let remaining = normal.extensionRecords(profileID:profile).first
            check(remaining?.id == id && remaining?.enabled == false && remaining?.grants == nil,"Profile clear retains installed definitions disabled with all previous extension approvals revoked")
            let kept = (try await privateWeb.evaluateJavaScript("document.getElementById('owned-form').value === 'retain private form' && document.cookie.includes('owned_clear_private=keep')")) as? Bool
            check(client.views[privateID] === privateWeb && kept == true && privateKeyRequests == 0 && privateWeb.configuration.webExtensionController?.configuration.identifier == controllerID,"Clearing a normal account preserves the private view, form, temporary cookie and captured old controller without a key request")
            let configuration = WKWebExtensionController.Configuration(identifier:controllerID);configuration.defaultWebsiteDataStore = dataStore
            let background = WKWebViewConfiguration();background.websiteDataStore = dataStore;configuration.webViewConfiguration = background
            let inspector = WKWebExtensionController(configuration:configuration),object = try await WKWebExtension(resourceBaseURL:source),readback = WKWebExtensionContext(for:object)
            readback.uniqueIdentifier = record.runtimeIdentifier;readback.baseURL = context.baseURL
            readback.grantedPermissions = Dictionary(uniqueKeysWithValues:["storage","scripting","declarativeNetRequest"].map{(WKWebExtension.Permission(rawValue:$0),Date.distantFuture)})
            try inspector.load(readback);defer {if readback.isLoaded {try? inspector.unload(readback)}}
            let readbackAPI = try await page(readback)
            check((try await js(readbackAPI,"return Object.keys(await browser.storage.local.get(null)).length === 0 && Object.keys(await browser.storage.sync.get(null)).length === 0;")) as? Bool == true,"Completed profile clearing erases the actual old namespace's native local and synchronized data")
            check((try await readbackAPI.evaluateJavaScript("localStorage.getItem('owned-profile-origin') === null")) as? Bool == true,"Completed profile clearing erases its old extension-origin website data")
            let orphanTypes = WKWebExtensionController.allExtensionDataTypes.subtracting([.session]),orphanRecords = await inspector.dataRecords(ofTypes:orphanTypes).filter{$0.uniqueIdentifier == orphanID}
            check(orphanRecords.allSatisfy{$0.errors.isEmpty && $0.totalSizeInBytes == 0},"Profile clearing also erases native settings for an interrupted install absent from its current catalog")
            await inspector.removeData(ofTypes:orphanTypes,from:orphanRecords)
            _ = try await js(readbackAPI,"await browser.storage.local.clear();await browser.storage.sync.clear();await browser.scripting.unregisterContentScripts();let rules=await browser.declarativeNetRequest.getDynamicRules();await browser.declarativeNetRequest.updateDynamicRules({removeRuleIds:rules.map(rule=>rule.id)});localStorage.clear();return true;")
            try inspector.unload(readback);nativeCleanupSafe = true
        }
        func profileDeleteExercise() async throws {
            nativeCleanupSafe = false
            let normal = BrowserStore(dataRoot:root.appendingPathComponent("profile-delete"),keyProvider:{_ in key})
            defer {normal.shutdown()}
            let profile = try normal.createProfile(name:"Owned complete deletion"),space = normal.space.id,controllerID = normal.profiles.first(where:{$0.id == profile})!.extensionControllerID!
            try owned.register(profile);try controllers.register(controllerID)
            let source = root.appendingPathComponent("source"),package = try ExtensionPackage.prepare(at:source,stagingRoot:root.appendingPathComponent("delete-staging")),approval = try normal.extensionInstallApproval(for:package,profileID:profile,permissions:["storage","scripting","declarativeNetRequest"],enable:true)
            let id = try await normal.installExtension(package,approval:approval)
            let identifier = normal.extensionRecords(profileID:profile).first!.runtimeIdentifier
            func seed() async throws {
                try await normal.prepareExtensions(profileID:profile)
                let context = (normal.extensionHosting as! NativeBrowserExtensionHost).profiles[profile]!.contexts[id]!,api = try await page(context)
                _ = try await js(api,"await browser.storage.local.set({owned:'delete this account'});await browser.storage.sync.set({owned:'delete synchronized data'});localStorage.setItem('owned-deleted-origin','delete');return true;")
            }
            try await seed();try normal.assignProfile(BrowserProfile.defaultID,to:space);await Task.yield()
            try await normal.deleteProfile(profile)
            check(!normal.profiles.contains{$0.id == profile} && !normal.profileLibraries.contains{$0.profileID == profile},"Successful profile deletion removes its saved account and library after data removal")
            check(!(await WKWebsiteDataStore.allDataStoreIdentifiers).contains(profile),"Successful profile deletion removes its real named website store")
            let configuration = WKWebExtensionController.Configuration(identifier:controllerID);configuration.defaultWebsiteDataStore = .nonPersistent()
            let background = WKWebViewConfiguration();background.websiteDataStore = configuration.defaultWebsiteDataStore;configuration.webViewConfiguration = background
            let inspector = WKWebExtensionController(configuration:configuration),types = WKWebExtensionController.allExtensionDataTypes.subtracting([.session]),remaining = await inspector.dataRecords(ofTypes:types).filter{$0.uniqueIdentifier == identifier}
            check(remaining.allSatisfy{$0.errors.isEmpty && $0.totalSizeInBytes == 0},"Successful profile deletion erases native extension data in its former controller namespace")
            check(!manager.fileExists(atPath:normal.extensionPackagesRoot.appendingPathComponent(profile.uuidString).path),"Successful profile deletion removes its controlled installed extension packages")
            nativeCleanupSafe = true
        }
        func openPagesExercise() async throws {
            nativeCleanupSafe = false
            let normal = BrowserStore(dataRoot:root.appendingPathComponent("open-extension-pages"),keyProvider:{_ in key})
            defer {normal.shutdown()}
            let profile = try normal.createProfile(name:"Owned open extension pages"),controllerID = normal.profiles.first(where:{$0.id == profile})!.extensionControllerID!
            try owned.register(profile);try controllers.register(controllerID)
            let window = NSWindow(contentRect:NSRect(x:0,y:0,width:600,height:400),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            window.isReleasedWhenClosed = false;normal.registerExtensionWindow(window,kind:.primary)
            defer {normal.unregisterExtensionWindow(kind:.primary);window.contentView = nil;window.close()}
            func install() async throws -> UUID {
                let package = try ExtensionPackage.prepare(at:root.appendingPathComponent("source"),stagingRoot:root.appendingPathComponent("open-pages-staging")),approval = try normal.extensionInstallApproval(for:package,profileID:profile,permissions:["storage","scripting","declarativeNetRequest"],enable:true)
                return try await normal.installExtension(package,approval:approval)
            }
            let targetID = try await install(),peerID = try await install()
            try await normal.prepareExtensions(profileID:profile)
            func openPages(_ id:UUID) async throws -> (UUID,WKWebView,UUID,WKWebView) {
                let tab = try await normal.openExtensionOptions(id,profileID:profile),context = (normal.extensionHosting as! NativeBrowserExtensionHost).profiles[profile]!.contexts[id]!
                guard let configuration = context.webViewConfiguration else {throw OwnedExtensionErasureError.missingFixture}
                // Only this generated, prohibited fixture enables automatic popups
                // so it can exercise the real native callback without a physical click.
                configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
                let web = WKWebView(frame:window.contentLayoutRect,configuration:configuration)
                normal.registerView(web,for:tab,profile:profile);window.contentView = web
                web.load(URLRequest(url:context.optionsPageURL!))
                try await wait{(try? await web.evaluateJavaScript("window.ownedErasureReady === true")) as? Bool == true}
                let existing = Set(normal.views.keys)
                _ = try await web.evaluateJavaScript("!!window.open('about:blank','_blank')")
                try await wait{!Set(normal.views.keys).subtracting(existing).isEmpty}
                guard let popupID = Set(normal.views.keys).subtracting(existing).first,let popup = normal.views[popupID] else {throw OwnedExtensionErasureError.missingFixture}
                try await wait{(try? await popup.evaluateJavaScript("!!window.opener")) as? Bool == true}
                _ = try await popup.evaluateJavaScript("window.ownedPopupKept='keep peer popup';true")
                return (tab,web,popupID,popup)
            }
            var targetPages: (UUID,WKWebView,UUID,WKWebView)? = try await openPages(targetID)
            let targetTab = targetPages!.0,targetPopupID = targetPages!.2
            let targetReference = ClosingProfilePage(targetPages!.1,profileID:profile)
            let (peerTab,peer,peerPopupID,peerPopup) = try await openPages(peerID)
            _ = try await js(peer,"await browser.storage.local.set({ownedPeer:'keep unrelated extension'});window.ownedPeerDocument='keep live peer';return true;")
            let websiteID = normal.newTab(url:fixture.appendingPathComponent("open-pages-form")),website = normal.view(for:websiteID)
            try await wait{(try? await website.evaluateJavaScript("document.body?.dataset.ownedExtensionPage === 'ready'")) as? Bool == true}
            _ = try await website.evaluateJavaScript("document.getElementById('owned-form').value='retain removal form';document.cookie='owned_removal_form=keep; path=/';true")
            _ = try await js(targetReference.webView!,"return await new Promise((resolve,reject)=>{let r=indexedDB.open('owned-open-options',1);r.onupgradeneeded=()=>r.result.createObjectStore('items');r.onerror=()=>reject(r.error);r.onsuccess=()=>{window.ownedHeldDatabase=r.result;window.ownedRemovalRequested=false;r.result.onversionchange=()=>{window.ownedRemovalRequested=true};resolve(true)}});")
            targetPages = nil
            try normal.beginRemoveExtension(targetID,profileID:profile)
            var outcome:Result<ExtensionErasureReceipt,Error>?
            let removal = Task { @MainActor in do {outcome = .success(try await normal.finishRemoveExtension(targetID,profileID:profile))} catch {outcome = .failure(error)} }
            do {
                try await wait{if outcome != nil {return true};return (try? await targetReference.webView?.evaluateJavaScript("window.ownedRemovalRequested === true")) as? Bool == true}
                check(normal.views[targetTab] == nil && normal.tab(targetTab) == nil,"Removal closes its real options tab before deleting an origin with held database handles")
                check(normal.views[targetPopupID] == nil && normal.tab(targetPopupID) == nil,"Removal also closes its actual related about:blank popup using captured extension ownership")
                let completed:Bool;if case .success = outcome {completed = true} else {completed = false}
                check(completed,"Closing the removed extension's own page releases its actual database handle without user intervention")
                // Baseline RED recovery: only the generated fixture's own handle.
                _ = try? await targetReference.webView?.evaluateJavaScript("window.ownedHeldDatabase?.close();window.ownedHeldDatabase=null;true")
                await removal.value
                if case .failure(let error) = outcome {throw error}
            } catch {
                _ = try? await targetReference.webView?.evaluateJavaScript("window.ownedHeldDatabase?.close();window.ownedHeldDatabase=null;true")
                await removal.value;throw error
            }
            let peerKept = (try await peer.evaluateJavaScript("window.ownedPeerDocument === 'keep live peer'")) as? Bool
            let popupKept = (try await peerPopup.evaluateJavaScript("window.ownedPopupKept === 'keep peer popup' && !!window.opener")) as? Bool
            check(normal.views[peerTab] === peer && normal.views[peerPopupID] === peerPopup && peerKept == true && popupKept == true,"Removal preserves another extension's live options document and actual related blank popup")
            try await normal.prepareExtensions(profileID:profile)
            let peerContext = (normal.extensionHosting as! NativeBrowserExtensionHost).profiles[profile]!.contexts[peerID]!,peerReadback = try await page(peerContext)
            check((try await js(peerReadback,"return (await browser.storage.local.get('ownedPeer')).ownedPeer === 'keep unrelated extension';")) as? Bool == true,"Removal preserves the unrelated extension's native settings across catalog reload")
            let formKept = (try await website.evaluateJavaScript("document.getElementById('owned-form').value === 'retain removal form' && document.cookie.includes('owned_removal_form=keep')")) as? Bool
            check(normal.views[websiteID] === website && formKept == true,"Extension-page disposal preserves the ordinary website view, unsaved form and cookie")
            nativeCleanupSafe = true
        }
        func retainedPageExercise(clearing:Bool = false) async throws {
            nativeCleanupSafe = false
            let normal = BrowserStore(dataRoot:root.appendingPathComponent(clearing ? "retained-clear-view" : "retained-options-view"),keyProvider:{_ in key});defer {normal.shutdown()}
            let profile = try normal.createProfile(name:"Owned retained options"),controllerID = normal.profiles.first(where:{$0.id == profile})!.extensionControllerID!
            try owned.register(profile);try controllers.register(controllerID)
            let window = NSWindow(contentRect:NSRect(x:0,y:0,width:600,height:400),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            window.isReleasedWhenClosed = false;normal.registerExtensionWindow(window,kind:.primary)
            defer {normal.unregisterExtensionWindow(kind:.primary);window.contentView = nil;window.close()}
            let package = try ExtensionPackage.prepare(at:root.appendingPathComponent("source"),stagingRoot:root.appendingPathComponent("retained-staging")),approval = try normal.extensionInstallApproval(for:package,profileID:profile,permissions:["storage","scripting","declarativeNetRequest"],enable:true),id = try await normal.installExtension(package,approval:approval)
            let tab = try await normal.openExtensionOptions(id,profileID:profile)
            var retained:WKWebView? = normal.views[tab]
            window.contentView = retained
            try await wait{(try? await retained?.evaluateJavaScript("window.ownedErasureReady === true")) as? Bool == true}
            _ = try await js(retained!,"localStorage.setItem('owned-retained-document','keep until released');return true;")
            let original = ClosingProfilePage(retained!,profileID:profile)
            if !clearing {try normal.beginRemoveExtension(id,profileID:profile)}
            var refused = false
            do {if clearing {try await normal.clearProfileData(profile)} else {try await normal.finishRemoveExtension(id,profileID:profile)}} catch ProfileError.pagesClosing {refused = true}
            try controllers.register(normal.profiles.first(where:{$0.id == profile})!.extensionControllerID!)
            let kept = (try await retained?.evaluateJavaScript("localStorage.getItem('owned-retained-document') === 'keep until released'")) as? Bool
            if clearing {
                check(refused && !ExtensionErasureJobs.holds(controllerID) && kept == true && normal.profiles.first(where:{$0.id == profile})?.isPendingClear == true && normal.profiles.first(where:{$0.id == profile})?.extensionControllerID == controllerID,"An actual retained extension document keeps profile clearing pending in its original namespace before erasure starts")
            } else {
                check(refused && !ExtensionErasureJobs.holds(controllerID) && kept == true && normal.extensionRecords(profileID:profile).first?.pendingRemoval == true,"An actual retained options view leaves removal pending before any native erasure starts")
            }
            window.contentView = nil;retained = nil
            try await wait{original.webView == nil}
            if clearing {
                try await normal.clearProfileData(profile);try controllers.register(normal.profiles.first(where:{$0.id == profile})!.extensionControllerID!)
                check(normal.profiles.first(where:{$0.id == profile})?.isPendingClear == false && normal.profiles.first(where:{$0.id == profile})?.extensionControllerID != controllerID && normal.extensionRecords(profileID:profile).first?.grants == nil,"Releasing the old extension document allows profile-clear retry to erase data and then rotate its namespace")
            } else {
                try await normal.finishRemoveExtension(id,profileID:profile)
                check(normal.extensionRecords(profileID:profile).isEmpty,"Releasing a retained extension document allows explicit removal retry to complete")
            }
            nativeCleanupSafe = true
        }
        func retiredNamespaceExercise(removing:Bool) async throws {
            nativeCleanupSafe = false
            let normal = BrowserStore(dataRoot:root.appendingPathComponent(removing ? "retired-uninstall" : "retired-namespace"),keyProvider:{_ in key}),owner = BrowserWindowOwner(store:normal),primary = try owner.acquirePrimary(),profile = try normal.createProfile(name:"Owned retired controller")
            defer {owner.release(primary);normal.shutdown()}
            let oldID = normal.profiles.first(where:{$0.id == profile})!.extensionControllerID!
            try owned.register(profile);try controllers.register(oldID)
            let package = try ExtensionPackage.prepare(at:root.appendingPathComponent("source"),stagingRoot:root.appendingPathComponent("retired-staging")),approval = try normal.extensionInstallApproval(for:package,profileID:profile,permissions:["storage","scripting","declarativeNetRequest"],allowPrivate:true,enable:true)
            let id = try await normal.installExtension(package,approval:approval);try await normal.prepareExtensions(profileID:profile)
            let record = normal.extensionRecords(profileID:profile).first!,context = (normal.extensionHosting as! NativeBrowserExtensionHost).profiles[profile]!.contexts[id]!,api = try await page(context)
            _ = try await js(api,"await browser.storage.local.set({retired:'erase old controller'});await browser.storage.sync.set({retired:'erase old sync'});return true;")
            var privateKeys = 0
            let client = BrowserStore(isPrivate:true,dataRoot:root.appendingPathComponent("retired-private"),keyProvider:{_ in privateKeys += 1;throw CocoaError(.fileReadNoPermission)})
            defer {client.shutdown()}
            try client.associateExtensions(with:owner,profileID:profile)
            let privateID = client.selectedID!,url = fixture.appendingPathComponent("retired-private-form"),web = client.view(for:privateID)
            client.update(privateID){$0.url = url.absoluteString};web.load(URLRequest(url:url))
            try await wait{(try? await web.evaluateJavaScript("document.body?.dataset.ownedExtensionPage === 'ready'")) as? Bool == true}
            _ = try await web.evaluateJavaScript("document.getElementById('owned-form').value='keep retired-controller form';document.cookie='owned_retired_private=keep; path=/';true")
            normal.extensionHosting = nil
            var changed = normal.makeDocument();let changedIndex = changed.profiles!.firstIndex(where:{$0.id == profile})!
            changed.profiles?[changedIndex].extensionControllerID = UUID()
            try normal.commitProfileDocument(changed)
            try controllers.register(normal.profiles.first(where:{$0.id == profile})!.extensionControllerID!)
            if removing {try normal.beginRemoveExtension(id,profileID:profile);try await normal.finishRemoveExtension(id,profileID:profile)}
            else {try await normal.clearProfileData(profile)}
            try controllers.register(normal.profiles.first(where:{$0.id == profile})!.extensionControllerID!)
            let configuration = WKWebExtensionController.Configuration(identifier:oldID);configuration.defaultWebsiteDataStore = .nonPersistent()
            let background = WKWebViewConfiguration();background.websiteDataStore = configuration.defaultWebsiteDataStore;configuration.webViewConfiguration = background
            let inspector = WKWebExtensionController(configuration:configuration),types = WKWebExtensionController.allExtensionDataTypes.subtracting([.session]),remaining = await inspector.dataRecords(ofTypes:types).filter{$0.uniqueIdentifier == record.runtimeIdentifier}
            check(remaining.allSatisfy{$0.errors.isEmpty && $0.totalSizeInBytes == 0},removing ? "Individual removal erases its extension identity from retained private-controller namespaces" : "Profile clearing follows its structurally attached private controller after host retirement and a saved namespace change")
            let kept = (try await web.evaluateJavaScript("document.getElementById('owned-form').value === 'keep retired-controller form' && document.cookie.includes('owned_retired_private=keep')")) as? Bool
            check(client.views[privateID] === web && kept == true && privateKeys == 0 && web.configuration.webExtensionController?.configuration.identifier == oldID,"Retired-controller erasure preserves the private view, old configuration, form and temporary cookie")
            await inspector.removeData(ofTypes:types,from:remaining)
            nativeCleanupSafe = true
        }
        do {try await exercise();try await lifetimeExercise(cancelWaiter:true);try await lifetimeExercise(cancelWaiter:false);try await lifetimeExercise(cancelWaiter:false,failFinalSave:true);try await damagedPackageExercise(missing:false);try await damagedPackageExercise(missing:true);try await profileClearExercise();try await profileDeleteExercise();try await retiredNamespaceExercise(removing:false);try await retiredNamespaceExercise(removing:true);try await openPagesExercise();try await retainedPageExercise();try await retainedPageExercise(clearing:true)} catch {check(false,"Owned erasure fixture failed: "+String(describing:error))}
        if nativeCleanupSafe {check(await controllers.cleanup(),"Erasure fixtures clear only their journaled native storage")}
        else {print("RECOVERY_REQUIRED",root.path)}
        check(await owned.cleanup(),"Erasure fixtures remove only their owned named website stores")
        if nativeCleanupSafe {try? manager.removeItem(at:root)}
        print("Extension erasure checks: \(failures) failures");exit(failures == 0 ? 0 : 1)
    }
}
