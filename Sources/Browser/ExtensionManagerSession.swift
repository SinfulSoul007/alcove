import AppKit
import WebKit
import BrowserCore

@MainActor final class ExtensionPermissionPreview:Identifiable {
    let id=UUID(),record:BrowserExtensionRecord,manifest:ExtensionManifest,profileID:UUID,controllerID:UUID,epoch:UUID,generation:UUID
    let supportedPermissions:[String],unsupportedPermissions:[String],diagnostics:[String]
    fileprivate var consumed=false
    init(record:BrowserExtensionRecord,manifest:ExtensionManifest,profileID:UUID,controllerID:UUID,epoch:UUID,generation:UUID,supported:[String],diagnostics:[String]) {
        self.record=record;self.manifest=manifest;self.profileID=profileID;self.controllerID=controllerID;self.epoch=epoch;self.generation=generation
        supportedPermissions=supported.sorted();unsupportedPermissions=Set(manifest.requestedPermissions+manifest.optionalPermissions).subtracting(supported).sorted();self.diagnostics=diagnostics
    }
}

@MainActor final class ExtensionInstallPreview:Identifiable {
    let id = UUID(),package:PreparedExtensionPackage,profileID:UUID,controllerID:UUID,epoch:UUID
    let previous:BrowserExtensionRecord?
    let supportedPermissions:[String],unsupportedPermissions:[String],diagnostics:[String]
    var manifest:ExtensionManifest {package.manifest}
    fileprivate let generation:UUID
    fileprivate var consumed = false
    private var lease:MetadataOwnershipLease?
    init(package:PreparedExtensionPackage,profileID:UUID,controllerID:UUID,epoch:UUID,previous:BrowserExtensionRecord?,generation:UUID,supported:[String],diagnostics:[String],lease:MetadataOwnershipLease) {
        self.package=package;self.profileID=profileID;self.controllerID=controllerID;self.epoch=epoch;self.previous=previous;self.generation=generation
        supportedPermissions=supported.sorted()
        unsupportedPermissions=Set(package.manifest.requestedPermissions+package.manifest.optionalPermissions).subtracting(supported).sorted()
        self.diagnostics=diagnostics;self.lease=lease
    }
    /// Package publication holds the package's own lock. Cleanup must never wait
    /// for that worker on the main thread, including when a window closes.
    fileprivate func discard() {
        guard let lease else {return};self.lease=nil
        let package=self.package
        Task.detached {try? package.discard();lease.release()}
    }
    deinit {
        if let lease {let package=self.package;Task.detached {try? package.discard();lease.release()}}
    }
}

/// Every asynchronous review belongs to the initiating browser window and to a
/// specific account/controller revision. Switching browser Spaces changes neither.
@MainActor final class ExtensionManagerSession:ObservableObject {
    weak var store:BrowserStore?
    let source:ExtensionBrowserWindow
    @Published private(set) var profileID:UUID
    @Published private(set) var currentReview:ExtensionInstallPreview?
    @Published private(set) var currentPermissions:ExtensionPermissionPreview?
    private var generation=UUID(),closed=false
    private var closeObserver:NSObjectProtocol?
    private let transport:ExtensionStoreDownload.Transport
    private var preparation:Task<PreparedExtensionPackage,Error>?
    private var installation:Task<UUID,Error>?
    var canManage:Bool {
        guard let store,!closed,!store.isPrivate,!store.isShuttingDown,
              source.window != nil,store.extensionWindows[source.kind] === source,
              store.savingEnabled,store.metadataWriter.vault != nil,!store.profileUnavailable(profileID),
              store.profiles.contains(where:{$0.id==profileID && $0.extensionControllerID != nil}) else {return false}
        if #available(macOS 15.4,*) {return true};return false
    }
    init(store:BrowserStore,sourceWindow:NSWindow,profileID:UUID,transport:@escaping ExtensionStoreDownload.Transport=ExtensionStoreDownload.liveTransport) throws {
        let window=sourceWindow.sheetParent ?? sourceWindow
        guard let source=store.extensionWindows.values.first(where:{$0.window === window}),store.profiles.contains(where:{$0.id==profileID}) else {throw ExtensionHostError.closed}
        self.store=store;self.source=source;self.profileID=profileID;self.transport=transport
        closeObserver=NotificationCenter.default.addObserver(forName:NSWindow.willCloseNotification,object:window,queue:.main){[weak self] _ in
            MainActor.assumeIsolated {self?.close()}
        }
    }
    deinit {if let closeObserver {NotificationCenter.default.removeObserver(closeObserver)}}
    func selectProfile(_ id:UUID) throws {
        guard let store,!closed,store.profiles.contains(where:{$0.id==id}),!store.profileUnavailable(id) else {throw ExtensionActionError.stale}
        if profileID != id {cancelReview();profileID=id}
    }
    func cancelReview() {
        generation=UUID();preparation?.cancel();preparation=nil;installation?.cancel();installation=nil
        currentReview?.discard();currentReview=nil;currentPermissions=nil
    }
    func close() {guard !closed else {return};closed=true;cancelReview()}
    func managementStore() throws -> BrowserStore {
        guard !closed,let store,!store.isShuttingDown,source.window != nil,store.extensionWindows[source.kind] === source else {throw ExtensionHostError.closed}
        guard !store.isPrivate else {throw ProfileError.privateMode}
        guard #available(macOS 15.4,*) else {throw ExtensionHostError.unavailable}
        guard canManage else {throw ProfileError.locked}
        return store.metadataWriter
    }
    func reviewFile(_ url:URL,replacing:UUID?=nil) async throws -> ExtensionInstallPreview {
        try await review(replacing:replacing){root in
            let access=url.startAccessingSecurityScopedResource();defer {if access {url.stopAccessingSecurityScopedResource()}}
            return try ExtensionPackage.prepare(at:url,stagingRoot:root)
        }
    }
    func reviewWebStore(_ input:String,replacing:UUID?=nil) async throws -> ExtensionInstallPreview {
        let id=try ExtensionStoreLocation(input).id,transport=self.transport
        return try await review(replacing:replacing){root in try await ExtensionStoreDownload.fetch(id:id,stagingRoot:root,transport:transport)}
    }
    private func review(replacing:UUID?,prepare:@escaping @Sendable (URL) async throws -> PreparedExtensionPackage) async throws -> ExtensionInstallPreview {
        let owner=try managementStore();cancelReview()
        let generation=self.generation,profileID=self.profileID
        guard let controller=owner.profiles.first(where:{$0.id==profileID})?.extensionControllerID else {throw ExtensionActionError.stale}
        let epoch=owner.extensionReviewEpoch(for:profileID),previous=replacing.flatMap {id in owner.extensionRecords(profileID:profileID).first(where:{$0.id==id})}
        guard replacing==nil || previous != nil else {throw ExtensionActionError.missing}
        let lease=try MetadataOwnership.acquire(for:owner.sessionURL),root=owner.extensionStagingRoot
        // The lease remains in this operation until the actual worker drains,
        // even if its transport ignores cooperative cancellation.
        let worker=Task.detached(priority:.userInitiated){try await prepare(root)}
        preparation=worker
        var staged:PreparedExtensionPackage?
        do {
            let package=try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()});staged=package
            try validate(generation: generation,profileID:profileID,controller:controller,epoch:epoch,previous:previous)
            if let previous, package.source == .webStore {
                try validateStoreUpdate(package, replacing: previous)
            }
            guard #available(macOS 15.4,*) else {throw ExtensionHostError.unavailable}
            // Native parsing is inspection only: no context, controller or code is loaded.
            let native=try await WKWebExtension(resourceBaseURL:package.stagingURL)
            try validate(generation:generation,profileID:profileID,controller:controller,epoch:epoch,previous:previous)
            guard native.manifest["sandbox"]==nil else {throw ExtensionHostError.unsupportedIsolation}
            let errors=native.errors.map{$0 as NSError}
            let blocking=errors.filter{$0.domain != WKWebExtension.errorDomain || $0.code != WKWebExtension.Error.invalidManifestEntry.rawValue}
            guard blocking.isEmpty else {throw ExtensionHostError.native(blocking.map(\.localizedDescription).joined(separator:"\n"))}
            let supported=Set(native.requestedPermissions.union(native.optionalPermissions).map(\.rawValue)).subtracting(ExtensionCatalog.unavailablePermissions)
            let result=ExtensionInstallPreview(package:package,profileID:profileID,controllerID:controller,epoch:epoch,previous:previous,generation:generation,supported:Array(supported),diagnostics:errors.map(\.localizedDescription),lease:lease)
            preparation=nil;currentReview=result;return result
        } catch {
            if self.generation==generation {preparation=nil}
            let abandoned=staged
            await Task.detached {if let abandoned {try? abandoned.discard()};lease.release()}.value
            throw error
        }
    }
    private func validateStoreUpdate(_ package: PreparedExtensionPackage, replacing previous: BrowserExtensionRecord) throws {
        guard previous.source == .webStore, previous.hasValidIdentity, previous.pendingRemoval != true,
              package.publisherVerified, package.storeID == previous.storeID, package.signerID == previous.signerID else {
            throw ExtensionActionError.identityChanged
        }
        switch ExtensionManifest.compareVersions(package.manifest.version, previous.version) {
        case .orderedDescending: return
        case .orderedSame: throw ExtensionActionError.currentStoreVersion
        case .orderedAscending: throw ExtensionActionError.olderStoreVersion
        case nil: throw ExtensionActionError.unknownStoreVersion
        }
    }
    private func validate(generation:UUID,profileID:UUID,controller:UUID,epoch:UUID,previous:BrowserExtensionRecord?) throws {
        try Task.checkCancellation();let store=try managementStore()
        guard self.generation==generation,self.profileID==profileID,
              store.profiles.first(where:{$0.id==profileID})?.extensionControllerID==controller,
              store.extensionReviewEpoch(for:profileID)==epoch else {throw ExtensionActionError.stale}
        if let previous {guard store.extensionRecords(profileID:profileID).first(where:{$0.id==previous.id})==previous else {throw ExtensionActionError.stale}}
    }
    @discardableResult func approve(_ review:ExtensionInstallPreview,permissions:[String],hostPatterns:[String],allowPrivate:Bool,enable:Bool?=nil) async throws -> UUID {
        let store=try managementStore()
        guard currentReview === review,!review.consumed else {throw ExtensionActionError.stale}
        try validate(generation:review.generation,profileID:review.profileID,controller:review.controllerID,epoch:review.epoch,previous:review.previous)
        // Invalid choices can be corrected without consuming the valid review.
        guard Set(permissions).isSubset(of:Set(review.supportedPermissions)) else {throw ExtensionActionError.invalidApproval}
        let enabled = enable ?? review.previous?.enabled ?? true
        let approval=try store.extensionInstallApproval(for:review.package,profileID:review.profileID,replacing:review.previous?.id,permissions:permissions,hostPatterns:hostPatterns,allowPrivate:allowPrivate,enable:enabled)
        review.consumed=true
        let task=Task {@MainActor in try await store.installExtension(review.package,replacing:review.previous?.id,approval:approval)}
        installation=task
        defer {
            if currentReview === review {currentReview=nil;installation=nil}
            review.discard()
        }
        return try await withTaskCancellationHandler(operation:{try await task.value},onCancel:{task.cancel()})
    }
    func reviewInstalled(_ id:UUID) async throws -> ExtensionPermissionPreview {
        let store=try managementStore();cancelReview()
        let generation=self.generation,profileID=self.profileID,epoch=store.extensionReviewEpoch(for:profileID)
        guard let record=store.extensionRecords(profileID:profileID).first(where:{$0.id==id}),record.pendingRemoval != true,
              let controller=store.profiles.first(where:{$0.id==profileID})?.extensionControllerID else {throw ExtensionActionError.missing}
        let lease=try MetadataOwnership.acquire(for:store.sessionURL);defer {lease.release()}
        let root=store.extensionPackagesRoot
        let worker=Task.detached {try ExtensionPackage.inspectInstalled(record:record,profileID:profileID,packagesRoot:root)}
        let result=try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()})
        try validate(generation:generation,profileID:profileID,controller:controller,epoch:epoch,previous:record)
        guard #available(macOS 15.4,*) else {throw ExtensionHostError.unavailable}
        let native=try await WKWebExtension(resourceBaseURL:result.url)
        try validate(generation:generation,profileID:profileID,controller:controller,epoch:epoch,previous:record)
        let supported=Set(native.requestedPermissions.union(native.optionalPermissions).map(\.rawValue)).subtracting(ExtensionCatalog.unavailablePermissions)
        let preview=ExtensionPermissionPreview(record:record,manifest:result.manifest,profileID:profileID,controllerID:controller,epoch:epoch,generation:generation,supported:Array(supported),diagnostics:native.errors.map(\.localizedDescription))
        currentPermissions=preview;return preview
    }
    func savePermissions(_ review:ExtensionPermissionPreview,permissions:[String],hostPatterns:[String],allowPrivate:Bool) async throws {
        let store=try managementStore()
        guard currentPermissions === review,!review.consumed else {throw ExtensionActionError.stale}
        try validate(generation:review.generation,profileID:review.profileID,controller:review.controllerID,epoch:review.epoch,previous:review.record)
        guard Set(permissions).isSubset(of:Set(review.supportedPermissions)) else {throw ExtensionActionError.invalidApproval}
        let lease=try MetadataOwnership.acquire(for:store.sessionURL);defer {lease.release()}
        let record=review.record,profile=review.profileID,root=store.extensionPackagesRoot
        let worker=Task.detached {try ExtensionPackage.inspectInstalled(record:record,profileID:profile,packagesRoot:root)}
        _ = try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()})
        try validate(generation:review.generation,profileID:review.profileID,controller:review.controllerID,epoch:review.epoch,previous:review.record)
        var grants=ExtensionGrantSet(profileID:profile,recordID:record.id,controllerID:review.controllerID,packageDigest:record.packageDigest,permissions:permissions,hostPatterns:hostPatterns,allowPrivate:allowPrivate)
        grants.preserveDenials(from: record.grants)
        try store.setExtensionGrants(record.id,profileID:profile,grants:grants)
        review.consumed=true;currentPermissions=nil
    }
}
