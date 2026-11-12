import AppKit
import WebKit
import BrowserCore

/// Framework callbacks may outlive a window. Completion and timeout own only this result,
/// never a BrowserStore, window or web view; late native results cannot load a context.
@MainActor final class ExtensionBoundedResult<Value> {
    private var continuation:CheckedContinuation<Value,Error>?
    private var worker:Task<Void,Never>?, timeout:Task<Void,Never>?
    func finish(_ result:Result<Value,Error>) {
        guard let continuation else {return}
        self.continuation = nil; worker?.cancel(); timeout?.cancel(); worker = nil; timeout = nil
        continuation.resume(with:result)
    }
    func run(seconds:Double = 15,operation:@escaping @MainActor () async throws -> Value) async throws -> Value {
        try await withTaskCancellationHandler(operation:{
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                if Task.isCancelled {finish(.failure(CancellationError()));return}
                worker = Task { [self] in
                    do {finish(.success(try await operation()))} catch {finish(.failure(error))}
                }
                timeout = Task { [self] in
                    do {try await Task.sleep(for:.seconds(seconds));finish(.failure(ExtensionHostError.timedOut))} catch {}
                }
            }
        },onCancel:{Task { @MainActor [self] in finish(.failure(CancellationError())) }})
    }
}

@available(macOS 15.4,*) @MainActor final class NativeExtensionProfile {
    let id:UUID, controllerID:UUID
    let controller:WKWebExtensionController
    var contexts:[UUID:WKWebExtensionContext] = [:]
    var loaded:[BrowserExtensionRecord]?, epoch:UUID?
    var task:Task<Void,Error>?, taskID:UUID?, preparing:[BrowserExtensionRecord]?
    init(id:UUID,controllerID:UUID,dataStore:WKWebsiteDataStore) {
        self.id = id; self.controllerID = controllerID
        let configuration = WKWebExtensionController.Configuration(identifier:controllerID)
        configuration.defaultWebsiteDataStore = dataStore
        let background = WKWebViewConfiguration(); background.websiteDataStore = dataStore
        configuration.webViewConfiguration = background
        controller = WKWebExtensionController(configuration:configuration)
    }
    func unload() throws {
        task?.cancel(); task = nil; taskID = nil; preparing = nil; loaded = nil; epoch = nil
        var failure:Error?
        for (id,context) in contexts {
            context.grantedPermissions = [:]; context.grantedPermissionMatchPatterns = [:]; context.hasAccessToPrivateData = false
            do {try controller.unload(context);contexts.removeValue(forKey:id)} catch {failure = error}
        }
        if let failure {throw failure}
    }
}

@available(macOS 15.4,*) @MainActor final class NativeBrowserExtensionHost:NSObject,BrowserExtensionHosting,WKWebExtensionControllerDelegate {
    weak var owner:BrowserStore?
    var profiles:[UUID:NativeExtensionProfile] = [:]
    private var reconciliation:Task<Void,Error>?
    private var reconciled = false
    private var bypasses:[UUID:([BrowserExtensionRecord],UUID)] = [:]
    var nativeWindows:[NativeExtensionWindowKey:NativeExtensionWindow] = [:]
    var focusedWindows:[UUID:NativeExtensionWindowKey] = [:]
    var privateClients:[UUID:NativePrivateExtensionClient] = [:]
    var nativeTabs:[NativeExtensionTabKey:NativeExtensionTab] = [:]
    var tabsByView:[ObjectIdentifier:NativeExtensionTab] = [:]
    var synchronization:Task<Void,Never>?
    var permissionPrompt = NativeExtensionPermissionPrompt.live
    var permissionRequestTimeout:Duration = .seconds(60)
    var permissionTickets:[UUID:NativeExtensionPermissionTicket] = [:]
    var permissionSessionGrants:[UUID:NativeExtensionSessionGrant] = [:]
    init(owner:BrowserStore) {self.owner = owner}
    private func currentOwner(_ id:UUID) throws -> (BrowserStore,BrowserProfile) {
        guard let owner, !owner.isShuttingDown else {throw ExtensionHostError.closed}
        guard !owner.isPrivate, !owner.awaitingInitialMetadata, owner.vault != nil,
              !owner.profileUnavailable(id), let profile = owner.profiles.first(where:{$0.id == id}),
              profile.extensionControllerID != nil else {throw ProfileError.locked}
        try owner.metadataOwnership?.validate()
        return (owner,profile)
    }
    private func profile(_ id:UUID) throws -> NativeExtensionProfile {
        let (owner,profile) = try currentOwner(id)
        if let runtime = profiles[id], runtime.controllerID == profile.extensionControllerID {return runtime}
        if let old = profiles[id] {try old.unload()}
        let runtime = NativeExtensionProfile(id:id,controllerID:profile.extensionControllerID!,dataStore:owner.websiteDataStore(forProfile:id))
        runtime.controller.delegate = self; profiles[id] = runtime
        return runtime
    }
    func configure(_ configuration:WKWebViewConfiguration,profileID:UUID) {
        do {configuration.webExtensionController = try profile(profileID).controller}
        catch {configuration.webExtensionController = nil;owner?.extensionStates[profileID] = .failed(error.localizedDescription)}
    }
    func invalidate(profileID:UUID) {
        bypasses.removeValue(forKey:profileID)
        do {try profiles[profileID]?.unload();owner?.extensionStates.removeValue(forKey:profileID)}
        catch {owner?.extensionStates[profileID] = .failed(error.localizedDescription)}
        reconcilePermissionRequests()
    }
    func matches(_ configuration:WKWebViewConfiguration,profileID:UUID) -> Bool {
        guard (try? currentOwner(profileID)) != nil, let runtime = profiles[profileID] else {return false}
        return configuration.webExtensionController === runtime.controller
    }
    func requiresPreparation(profileID:UUID) -> Bool {
        guard let owner else {return true}
        let records = owner.extensionRecords(profileID:profileID), epoch = owner.extensionReviewEpoch(for:profileID)
        if let bypass = bypasses[profileID], bypass.0 == records, bypass.1 == epoch {return false}
        if !records.contains(where:{$0.enabled && $0.pendingRemoval != true}) {return false}
        guard let runtime = profiles[profileID] else {return true}
        return runtime.loaded != records || runtime.epoch != epoch
    }
    func continueWithout(profileID:UUID) throws {
        let (owner,_) = try currentOwner(profileID)
        try profiles[profileID]?.unload()
        bypasses[profileID] = (owner.extensionRecords(profileID:profileID),owner.extensionReviewEpoch(for:profileID))
        owner.extensionStates[profileID] = .failed("Continuing without extensions in this profile. Retry to enable them again.")
    }
    func refresh() {
        guard let owner, !owner.isShuttingDown else {shutdown();return}
        for (id,runtime) in profiles {
            if owner.profileUnavailable(id) {
                invalidate(profileID:id)
                runtime.controller.delegate = nil
                profiles.removeValue(forKey:id)
                continue
            }
            let expected = runtime.preparing ?? runtime.loaded
            if owner.profiles.first(where:{$0.id == id})?.extensionControllerID != runtime.controllerID ||
                expected.map({$0 != owner.extensionRecords(profileID:id)}) == true ||
                runtime.epoch.map({$0 != owner.extensionReviewEpoch(for:id)}) == true {invalidate(profileID:id)}
        }
        synchronizeBrowserState()
    }
    private func reconcileBeforeLoading(_ owner:BrowserStore) async throws {
        if reconciled {return}
        if let reconciliation {try await reconciliation.value;return}
        let operation = Task { @MainActor [weak owner] in
            guard let owner, !owner.isShuttingDown else {throw ExtensionHostError.closed}
            _ = try await owner.reconcileExtensionPackages()
        }
        reconciliation = operation
        do {try await operation.value;reconciled = true;reconciliation = nil}
        catch {reconciliation = nil;throw error}
    }
    func prepare(profileID:UUID) async throws {
        let (owner,_) = try currentOwner(profileID), runtime = try profile(profileID)
        let records = owner.extensionRecords(profileID:profileID), epoch = owner.extensionReviewEpoch(for:profileID)
        if runtime.loaded == records && runtime.epoch == epoch {return}
        if let task = runtime.task {try await task.value;return}
        try runtime.unload()
        let operationID = UUID()
        runtime.preparing = records; runtime.epoch = epoch; runtime.taskID = operationID
        owner.extensionStates[profileID] = .preparing
        let task = Task { @MainActor [weak self,weak runtime] in
            guard let self, let runtime else {throw ExtensionHostError.closed}
            do {
                try await self.load(records,in:runtime,epoch:epoch,operationID:operationID)
                guard runtime.taskID == operationID else {throw ExtensionHostError.stale}
                runtime.loaded = records;runtime.preparing = nil;runtime.task = nil;runtime.taskID = nil
                self.owner?.extensionStates[profileID] = .ready
            } catch {
                if runtime.taskID == operationID {
                    try? runtime.unload()
                    self.owner?.extensionStates[profileID] = .failed(error.localizedDescription)
                    self.owner?.message = "Extensions did not start. Your existing page was kept. " + error.localizedDescription
                }
                throw error
            }
        }
        runtime.task = task
        try await task.value
    }
    private func validate(_ records:[BrowserExtensionRecord],runtime:NativeExtensionProfile,epoch:UUID,operationID:UUID) throws -> BrowserStore {
        try Task.checkCancellation()
        let (owner,profile) = try currentOwner(runtime.id)
        guard runtime.taskID == operationID, profile.extensionControllerID == runtime.controllerID,
              owner.extensionReviewEpoch(for:runtime.id) == epoch, owner.extensionRecords(profileID:runtime.id) == records else {throw ExtensionHostError.stale}
        return owner
    }
    private func load(_ records:[BrowserExtensionRecord],in runtime:NativeExtensionProfile,epoch:UUID,operationID:UUID) async throws {
        let owner = try validate(records,runtime:runtime,epoch:epoch,operationID:operationID)
        let active = records.filter{$0.enabled && $0.pendingRemoval != true}
        guard active.count <= 128 else {throw ExtensionHostError.native("Too many enabled extensions in this profile.")}
        if active.isEmpty {return}
        try await reconcileBeforeLoading(owner)
        synchronizeBrowserState()
        let root = owner.extensionPackagesRoot, profileID = runtime.id
        for record in active {
            _ = try validate(records,runtime:runtime,epoch:epoch,operationID:operationID)
            guard record.hasValidIdentity, record.grants != nil,
                  ExtensionCatalog.repaired([record],profileID:profileID,controllerID:runtime.controllerID).first == record else {throw ExtensionHostError.stale}
            let inspection = Task.detached(priority:.userInitiated) {try ExtensionPackage.inspectInstalled(record:record,profileID:profileID,packagesRoot:root)}
            let revision = try await withTaskCancellationHandler(operation:{try await inspection.value},onCancel:{inspection.cancel()})
            _ = try validate(records,runtime:runtime,epoch:epoch,operationID:operationID)
            let resourceURL = revision.url
            let extensionObject = try await ExtensionBoundedResult<WKWebExtension>().run {try await WKWebExtension(resourceBaseURL:resourceURL)}
            // Parsing does not execute code. Revalidate asynchronous filesystem/owner drift before loading.
            let confirmation = Task.detached(priority:.userInitiated) {try ExtensionPackage.inspectInstalled(record:record,profileID:profileID,packagesRoot:root)}
            _ = try await withTaskCancellationHandler(operation:{try await confirmation.value},onCancel:{confirmation.cancel()})
            _ = try validate(records,runtime:runtime,epoch:epoch,operationID:operationID)
            guard extensionObject.manifest["sandbox"] == nil else {throw ExtensionHostError.unsupportedIsolation}
            let diagnostics = extensionObject.errors.map {$0 as NSError}
            self.owner?.extensionDiagnostics[profileID,default:[:]][record.id] = diagnostics.map(\.localizedDescription)
            if record.grants?.hostPatterns.contains("<all_urls>") == true {
                self.owner?.extensionDiagnostics[profileID,default:[:]][record.id,default:[]].append("All-sites approval covers HTTP and HTTPS in WebKit. File, FTP and unsupported standalone WebSocket patterns are excluded.")
            }
            // WebKit reports optional display metadata (including a missing description) as an
            // invalid-entry diagnostic. Preserve every diagnostic for review, while malformed
            // archives, resources, background persistence and unsupported versions remain fatal.
            let blocking = diagnostics.filter {$0.domain != WKWebExtension.errorDomain || $0.code != WKWebExtension.Error.invalidManifestEntry.rawValue}
            guard blocking.isEmpty else {throw ExtensionHostError.native(blocking.map(\.localizedDescription).joined(separator:"\n"))}
            let context = WKWebExtensionContext(for:extensionObject)
            context.uniqueIdentifier = record.runtimeIdentifier
            context.baseURL = URL(string:"webkit-extension://" + record.runtimeIdentifier + "/")!
            context.isInspectable = false
            context.unsupportedAPIs = ["browser.runtime.sendNativeMessage","browser.runtime.connectNative","browser.debugger","browser.devtools","browser.sidePanel"]
            try apply(record.grants!,to:context)
            runtime.contexts[record.id] = context
            do {try runtime.controller.load(context)} catch {runtime.contexts.removeValue(forKey:record.id);throw error}
        }
    }
    private func patterns(_ raw:String) throws -> [WKWebExtension.MatchPattern] {
        // Native <all_urls> also includes local files. Alcove approvals cover web schemes only.
        let values = raw == "<all_urls>" ? ["http://*/*","https://*/*"] : [raw]
        return try values.map {try WKWebExtension.MatchPattern(string:$0)}
    }
    private func apply(_ grant:ExtensionGrantSet,to context:WKWebExtensionContext) throws {
        context.grantedPermissions = Dictionary(uniqueKeysWithValues:grant.permissions.map{(WKWebExtension.Permission(rawValue:$0),Date.distantFuture)})
        context.deniedPermissions = Dictionary(uniqueKeysWithValues:(grant.deniedPermissions ?? []).map{(WKWebExtension.Permission(rawValue:$0),Date.distantFuture)})
        var allowed:[WKWebExtension.MatchPattern:Date] = [:], denied:[WKWebExtension.MatchPattern:Date] = [:]
        for raw in grant.hostPatterns {for pattern in try patterns(raw) {allowed[pattern] = .distantFuture}}
        for raw in grant.deniedHostPatterns ?? [] {for pattern in try patterns(raw) {denied[pattern] = .distantFuture}}
        context.grantedPermissionMatchPatterns = allowed;context.deniedPermissionMatchPatterns = denied
        context.hasAccessToPrivateData = grant.allowPrivate
    }
    func shutdown() {
        cancelPermissionRequests()
        synchronization?.cancel();synchronization = nil
        reconciliation?.cancel();reconciliation = nil
        for runtime in profiles.values {try? runtime.unload();runtime.controller.delegate = nil}
        profiles = [:];bypasses = [:];nativeTabs = [:];nativeWindows = [:];focusedWindows = [:];tabsByView = [:];privateClients = [:];owner = nil
    }
}
