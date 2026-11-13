import AppKit
import WebKit
import BrowserCore

struct ExtensionErasureReceipt {let controllerID:UUID,identifier:String,lastNativeVersion:String}

enum ExtensionErasureError:LocalizedError {
    case busy,failed,unknown
    var errorDescription:String? {
        switch self {
        case .busy:return "Extension data removal is still running for this account. Wait for it to finish before retrying."
        case .failed:return "Extension data removal did not finish. The removal entry was kept so you can retry."
        case .unknown:return "WebKit stopped responding during extension data removal. Restart Alcove before retrying; the removal entry was kept."
        }
    }
}

extension BrowserStore {
    /// Remove only the selected extension's documents, including native related
    /// blank popups whose URL no longer identifies their owning extension.
    func closeRemovedExtensionPages(_ identifier:String,profileID:UUID) async throws {
        try await disposeExtensionPages(identifier,profileID:profileID)
        for attachment in Array(extensionPrivateAttachments.values) where attachment.profileID == profileID {
            if let client = attachment.attached {try await client.disposeExtensionPages(identifier,profileID:BrowserProfile.defaultID)}
        }
    }
    private func disposeExtensionPages(_ identifier:String,profileID:UUID) async throws {
        func owns(_ url:URL?) -> Bool {url?.scheme?.lowercased() == "webkit-extension" && url?.host == identifier}
        func owns(_ web:WKWebView) -> Bool {owns(web.url) || extensionPopupOwners.object(forKey:web).map{String($0)} == identifier}
        let liveIDs = Set(views.filter{viewProfileIDs[$0.key] == profileID && owns($0.value)}.keys)
        let peekContexts = peekPages.filter{$0.value.profileID == profileID && owns($0.value.web)}.map(\.key)
        let pages = (liveIDs.compactMap{views[$0]}+peekContexts.compactMap{peekPages[$0]?.web}).map{ClosingProfilePage($0,profileID:profileID)} + closingPages.filter{$0.profileID == profileID && ($0.extensionIdentifier == identifier || $0.webView.map{owns($0)} == true)}
        var candidate = makeDocument(),ids = liveIDs
        for space in candidate.session.spaces where isPrivate || space.effectiveProfileID == profileID {
            for tab in space.tabs where ids.contains(tab.id) || (views[tab.id] == nil && owns(URL(string:tab.url))) {ids.insert(tab.id);candidate.session.close(tab.id,in:space.id)}
        }
        var library = candidate.library(for:profileID)
        for tab in library.favoriteTabs ?? [] where ids.contains(tab.id) || (views[tab.id] == nil && owns(URL(string:tab.url))) {ids.insert(tab.id)}
        for page in library.quickPages ?? [] where ids.contains(page.id) || (views[page.id] == nil && owns(URL(string:page.tab.url))) {ids.insert(page.id)}
        library.favoriteTabs?.removeAll{ids.contains($0.id)};library.quickPages?.removeAll{ids.contains($0.id)}
        candidate.setLibrary(library,for:profileID)
        if !ids.isEmpty {try commitQuickDocument(candidate,discarding:Array(ids))}
        for context in peekContexts {closePeek(in:context)}
        revision += 1
        // WebKit ignores navigation from an unloaded extension document. Releasing
        // its actual WKWebView is the public boundary that destroys that document;
        // a blank load or removal from the tab dictionary alone is insufficient.
        let deadline = ContinuousClock.now.advanced(by:.seconds(5))
        while pages.contains(where:{$0.webView != nil}) {
            try Task.checkCancellation();guard !isShuttingDown else {throw CancellationError()}
            guard ContinuousClock.now < deadline else {throw ProfileError.pagesClosing}
            try await Task.sleep(for:.milliseconds(20))
        }
    }
    func retainedExtensionNamespaces(profileID:UUID) throws -> Set<UUID> {
        var result = Set(profiles.first(where:{$0.id == profileID})?.extensionControllerID.map{[$0]} ?? [])
        extensionPrivateAttachments = extensionPrivateAttachments.filter{$0.value.attached != nil}
        for attachment in extensionPrivateAttachments.values where attachment.profileID == profileID {result.insert(attachment.controllerID)}
        if #available(macOS 15.4,*) {
            func append(_ web:WKWebView) {if let id = web.configuration.webExtensionController?.configuration.identifier {result.insert(id)}}
            for (id,web) in views where viewProfileIDs[id] == profileID {append(web)}
            for page in peekPages.values where page.profileID == profileID {append(page.web)}
            for page in closingPages where page.profileID == profileID {if let web = page.webView {append(web)}}
            if let host = extensionHosting as? NativeBrowserExtensionHost,let runtime = host.profiles[profileID] {result.insert(runtime.controllerID)}
            for attachment in extensionPrivateAttachments.values where attachment.profileID == profileID {
                guard let client = attachment.attached else {continue}
                for web in client.views.values {append(web)}
                for page in client.peekPages.values {append(page.web)}
                for page in client.closingPages {if let web = page.webView {append(web)}}
            }
        }
        guard !profiles.contains(where:{$0.id != profileID && $0.extensionControllerID.map{result.contains($0)} == true}) else {throw ExtensionHostError.stale}
        return result
    }
    /// Called only after the profile operation's durable intent has revoked its
    /// catalog grants. Pending profiles cannot use the ordinary runtime loader.
    func eraseProfileExtensionData(_ records:[BrowserExtensionRecord],profileID:UUID,controllerIDs:Set<UUID>,expectedControllerID:UUID?,dataStore:WKWebsiteDataStore) async throws {
        guard !isPrivate else {throw ProfileError.privateMode}
        guard !controllerIDs.isEmpty else {guard records.isEmpty else {throw ExtensionHostError.unavailable};return}
        guard #available(macOS 15.4,*) else {guard records.isEmpty else {throw ExtensionHostError.unavailable};return}
        for controllerID in controllerIDs.sorted(by:{$0.uuidString < $1.uuidString}) {
        let configuration = WKWebExtensionController.Configuration(identifier:controllerID);configuration.defaultWebsiteDataStore = dataStore
        let background = WKWebViewConfiguration();background.websiteDataStore = dataStore;configuration.webViewConfiguration = background
        let inspector = WKWebExtensionController(configuration:configuration),types = WKWebExtensionController.allExtensionDataTypes.subtracting([.session]),stored = await inspector.dataRecords(ofTypes:types)
        guard stored.allSatisfy({$0.errors.isEmpty}) else {throw ExtensionErasureError.failed}
        var identities:[String:String] = [:]
        for record in records {guard record.hasValidIdentity else {throw ExtensionErasureError.failed};identities[record.runtimeIdentifier] = record.version}
        for record in stored where identities[record.uniqueIdentifier] == nil {identities[record.uniqueIdentifier] = "1"}
        for (identifier,version) in identities.sorted(by:{$0.key < $1.key}) {
            try Task.checkCancellation()
            guard !isShuttingDown,profiles.first(where:{$0.id == profileID})?.extensionControllerID == expectedControllerID else {throw CancellationError()}
            try metadataOwnership?.validate()
            try await closeRemovedExtensionPages(identifier,profileID:profileID)
            let erasure = try NativeExtensionErasure(controllerID:controllerID,identifier:identifier,version:version,stagingRoot:extensionStagingRoot,dataStore:dataStore)
            let lease = try MetadataOwnership.acquire(for:sessionURL)
            try await ExtensionErasureJobs.perform(erasure,lease:lease)
        }
        }
    }
}

/// The worker, lease and native context outlive a cancelled UI waiter. An uncertain
/// native result keeps its namespace reserved until this process exits.
@available(macOS 15.4,*) @MainActor enum ExtensionErasureJobs {
    struct Key:Hashable {let controllerID:UUID,identifier:String}
    final class Entry {
        let lease:MetadataOwnershipLease,erasure:NativeExtensionErasure
        var task:Task<Void,Error>?
        init(lease:MetadataOwnershipLease,erasure:NativeExtensionErasure) {self.lease = lease;self.erasure = erasure}
    }
    private static var entries:[Key:Entry] = [:]
    static func holds(_ controllerID:UUID) -> Bool {entries.keys.contains{$0.controllerID == controllerID}}
    static func perform(_ erasure:NativeExtensionErasure,lease:MetadataOwnershipLease) async throws {
        let key = Key(controllerID:erasure.controllerID,identifier:erasure.identifier)
        guard entries[key] == nil else {lease.release();throw ExtensionErasureError.busy}
        let entry = Entry(lease:lease,erasure:erasure);entries[key] = entry
        let task = Task { @MainActor in
            do {
                try await erasure.run()
                entries.removeValue(forKey:key);entry.task = nil;lease.release()
            } catch {
                entry.task = nil
                if erasure.quiescent {entries.removeValue(forKey:key);lease.release();throw error}
                // Keep the native objects and lease: a failed JS/native waiter does
                // not prove that an IndexedDB or SQLite deletion was cancelled.
                throw ExtensionErasureError.unknown
            }
        }
        entry.task = task
        try await task.value
    }
}

@available(macOS 15.4,*) @MainActor final class NativeExtensionErasure {
    let controllerID:UUID,identifier:String
    private let version:String,stagingRoot:URL,dataStore:WKWebsiteDataStore
    private var prepared:[PreparedExtensionPackage] = []
    private var controller:WKWebExtensionController?,context:WKWebExtensionContext?,web:WKWebView?
    private(set) var quiescent = true
    private(set) var lastNativeVersion:String?
    convenience init(controllerID:UUID,record:BrowserExtensionRecord,stagingRoot:URL,dataStore:WKWebsiteDataStore) throws {
        guard record.hasValidIdentity else {throw ExtensionErasureError.failed}
        try self.init(controllerID:controllerID,identifier:record.runtimeIdentifier,version:record.version,stagingRoot:stagingRoot,dataStore:dataStore)
    }
    init(controllerID:UUID,identifier:String,version:String,stagingRoot:URL,dataStore:WKWebsiteDataStore) throws {
        let uuid = UUID(uuidString:identifier)
        guard BrowserExtensionRecord.validExternalID(identifier) || (uuid != nil && uuid != BrowserProfile.zeroID && uuid?.uuidString.lowercased() == identifier) else {throw ExtensionErasureError.failed}
        self.controllerID = controllerID;self.identifier = identifier;self.version = version;self.stagingRoot = stagingRoot;self.dataStore = dataStore
    }
    private func javascript(_ body:String) async throws -> Any? {
        guard let web else {throw ExtensionErasureError.failed}
        return try await web.callAsyncJavaScript(body,arguments:[:],in:nil,contentWorld:.page)
    }
    func run() async throws {
        guard dataStore.isPersistent else {throw ExtensionErasureError.failed}
        let prefix = "alcove-cleanup-"+UUID().uuidString.lowercased()
        let marker = "ready-"+UUID().uuidString.lowercased(),sentinel = "sentinel-"+UUID().uuidString.lowercased()
        var files:[String:Data] = [:]
        // A distinct native version resets update-scoped registered-script state,
        // including definitions whose resources disappeared in an earlier update.
        let cleanupVersion = version == "1" || version.hasPrefix("1.") ? "2" : "1"
        // Bootstrap the recorded version first. The second, distinct version must
        // perform a native update even after an interrupted previous cleanup or
        // a missing resource prevented old registrations from entering its map.
        for (phase,phaseVersion) in [version,cleanupVersion].enumerated() {
            let manifest:[String:Any] = ["manifest_version":3,"name":"Alcove extension data cleanup","description":"Alcove-owned local maintenance","version":phaseVersion,"permissions":["storage","scripting","declarativeNetRequest"],"incognito":"not_allowed","background":["scripts":[prefix+"/bootstrap.js"],"persistent":false],"options_page":prefix+"/probe.html","content_security_policy":["extension_pages":"default-src 'none'; script-src 'self'; object-src 'none'; connect-src 'none'; worker-src 'self'; base-uri 'none'; form-action 'none'"]]
            files["manifest.json"] = try JSONSerialization.data(withJSONObject:manifest,options:.sortedKeys)
            files[prefix+"/probe.html"] = Data("<!doctype html><title>Alcove local maintenance</title>".utf8)
            files[prefix+"/sentinel.js"] = Data("/* Alcove-owned inert maintenance resource */".utf8)
            files[prefix+"/bootstrap.js"] = Data("(async()=>{try{await browser.scripting.registerContentScripts([{id:'\(sentinel)',matches:['https://alcove-cleanup.invalid/*'],js:['\(prefix)/sentinel.js'],persistAcrossSessions:true,runAt:'document_end'}]);await browser.storage.session.set({'\(marker)':'ready'})}catch{await browser.storage.session.set({'\(marker)':'failed'})}})();".utf8)
            let root = stagingRoot,generated = files
            let stage = try await Task.detached(priority:.utility) {try ExtensionPackage.prepareGeneratedResources(generated,stagingRoot:root)}.value
            prepared.append(stage)
            let object = try await WKWebExtension(resourceBaseURL:stage.stagingURL)
            let configuration = WKWebExtensionController.Configuration(identifier:controllerID);configuration.defaultWebsiteDataStore = dataStore
            let background = WKWebViewConfiguration();background.websiteDataStore = dataStore;configuration.webViewConfiguration = background
            let native = WKWebExtensionController(configuration:configuration),context = WKWebExtensionContext(for:object)
            context.uniqueIdentifier = identifier
            guard let base = URL(string:"webkit-extension://"+identifier+"/") else {throw ExtensionErasureError.failed}
            context.baseURL = base;context.isInspectable = false
            context.unsupportedAPIs = ["browser.runtime.sendNativeMessage","browser.runtime.connectNative","browser.tabs","browser.windows","browser.cookies","browser.webRequest","browser.scripting.executeScript","browser.scripting.insertCSS","browser.scripting.removeCSS"]
            context.grantedPermissions = Dictionary(uniqueKeysWithValues:["storage","scripting","declarativeNetRequest"].map{(WKWebExtension.Permission(rawValue:$0),Date.distantFuture)})
            context.grantedPermissionMatchPatterns = [:];context.hasAccessToPrivateData = false
            controller = native;self.context = context;quiescent = false
            try native.load(context);lastNativeVersion = object.manifest["version"] as? String;try await context.loadBackgroundContent()
            guard context.grantedPermissionMatchPatterns.isEmpty,!context.hasAccessToPrivateData,let pageConfiguration = context.webViewConfiguration else {throw ExtensionErasureError.failed}
            let page = WKWebView(frame:.zero,configuration:pageConfiguration);web = page
            page.load(URLRequest(url:base.appendingPathComponent(prefix+"/probe.html")))
            let deadline = ContinuousClock.now.advanced(by:.seconds(15))
            while true {
                if page.url == base.appendingPathComponent(prefix+"/probe.html"),!page.isLoading {
                    let ready = try await javascript("return (await browser.storage.session.get('\(marker)'))['\(marker)'] || '';") as? String
                    if ready == "ready" {break}
                    if ready == "failed" {throw ExtensionErasureError.failed}
                }
                guard ContinuousClock.now < deadline else {throw ExtensionErasureError.failed}
                try await Task.sleep(for:.milliseconds(20))
            }
            if phase == 0 {
                web = nil;try native.unload(context);self.context = nil;controller = nil
            }
        }
        guard let native = controller,let context = self.context else {throw ExtensionErasureError.failed}
        let clear = #"""
        await browser.scripting.unregisterContentScripts();
        let rules=await browser.declarativeNetRequest.getDynamicRules();
        await browser.declarativeNetRequest.updateDynamicRules({removeRuleIds:rules.map(rule=>rule.id)});
        localStorage.clear();sessionStorage.clear();
        for(let database of await indexedDB.databases()){
            if(!database.name)throw new Error('Could not identify an extension database');
            await new Promise((resolve,reject)=>{let request=indexedDB.deleteDatabase(database.name);request.onsuccess=()=>resolve(true);request.onerror=()=>reject(new Error('Extension database deletion failed'));request.onblocked=()=>{/* Nonterminal: keep this request and its namespace owned. */}});
        }
        if('caches' in globalThis){try{for(let key of await caches.keys())await caches.delete(key);if((await caches.keys()).length)throw new Error('Extension caches remain')}catch(error){if(!['SecurityError','NotSupportedError'].includes(error.name))throw error}}
        if(navigator.storage && typeof navigator.storage.getDirectory==='function'){try{let directory=await navigator.storage.getDirectory();for await(let [name] of directory.entries())await directory.removeEntry(name,{recursive:true});for await(let unused of directory.entries())throw new Error('Extension origin files remain')}catch(error){if(!['SecurityError','NotSupportedError'].includes(error.name))throw error}}
        if(navigator.serviceWorker){try{for(let registration of await navigator.serviceWorker.getRegistrations())await registration.unregister();if((await navigator.serviceWorker.getRegistrations()).length)throw new Error('Extension workers remain')}catch(error){if(!['SecurityError','NotSupportedError'].includes(error.name))throw error}}
        return localStorage.length === 0 && (await indexedDB.databases()).length === 0 && (await browser.scripting.getRegisteredContentScripts()).length === 0 && (await browser.declarativeNetRequest.getDynamicRules()).length === 0;
        """#
        guard (try await javascript(clear)) as? Bool == true else {throw ExtensionErasureError.failed}
        web = nil;try native.unload(context);self.context = nil
        let types = WKWebExtensionController.allExtensionDataTypes.subtracting([.session])
        let before = await native.dataRecords(ofTypes:types).filter{$0.uniqueIdentifier == identifier}
        guard before.allSatisfy({$0.errors.isEmpty}) else {quiescent = true;throw ExtensionErasureError.failed}
        await native.removeData(ofTypes:types,from:before)
        let after = await native.dataRecords(ofTypes:types).filter{$0.uniqueIdentifier == identifier}
        quiescent = true
        guard before.allSatisfy({$0.errors.isEmpty}),after.allSatisfy({$0.errors.isEmpty && $0.totalSizeInBytes == 0}) else {throw ExtensionErasureError.failed}
        controller = nil
        for stage in prepared {try stage.discard()};prepared = []
    }
}
