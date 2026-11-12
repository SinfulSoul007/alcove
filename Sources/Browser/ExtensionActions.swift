import Foundation
import BrowserCore

enum ExtensionActionError:LocalizedError {
    case missing, stale, approvalRequired, invalidApproval, busy
    var errorDescription:String? {
        switch self {
        case .missing: return "This extension no longer exists."
        case .stale: return "This extension, account or review changed. Inspect it again before continuing."
        case .approvalRequired: return "Review this code version's permissions before enabling it."
        case .invalidApproval: return "Choose permissions declared by this extension and supported by Alcove."
        case .busy: return "An extension installation is still finishing. Try again shortly."
        }
    }
}

@MainActor final class ExtensionInstallApproval {
    weak var store:BrowserStore?
    let profileID:UUID
    let controllerID:UUID
    let policyEpoch:UUID
    let record:BrowserExtensionRecord
    let previous:BrowserExtensionRecord?
    var consumed = false
    init(store:BrowserStore,profileID:UUID,controllerID:UUID,record:BrowserExtensionRecord,previous:BrowserExtensionRecord?) {
        self.store = store; self.profileID = profileID; self.controllerID = controllerID; policyEpoch = store.extensionReviewEpoch(for:profileID); self.record = record; self.previous = previous
    }
}

@MainActor private enum ExtensionPublicationOwners {
    static var roots = Set<URL>()
    static func begin(_ root:URL) throws { guard roots.insert(root).inserted else { throw ExtensionActionError.busy } }
    static func end(_ root:URL) { roots.remove(root) }
}

extension BrowserStore {
    func extensionReviewEpoch(for profileID:UUID) -> UUID {
        if let epoch = extensionReviewEpochs[profileID] {return epoch}
        let epoch = UUID(); extensionReviewEpochs[profileID] = epoch; return epoch
    }
    func invalidateExtensionReviewEpochs(from old:[BrowserProfile],to new:[BrowserProfile]) {
        for previous in old where !new.contains(where:{$0.id == previous.id}) {extensionReviewEpochs.removeValue(forKey:previous.id)}
        for profile in new {
            guard let previous = old.first(where:{$0.id == profile.id}) else {continue}
            if previous.extensionControllerID != profile.extensionControllerID || previous.isPendingClear != profile.isPendingClear || previous.isPendingDeletion != profile.isPendingDeletion {
                extensionReviewEpochs[profile.id] = UUID()
            }
        }
    }
    func resetExtensionReviewEpochs() {
        for id in Array(extensionReviewEpochs.keys) {extensionReviewEpochs[id] = UUID()}
    }
    var extensionPackagesRoot:URL { sessionURL.deletingLastPathComponent().appendingPathComponent("Extensions",isDirectory:true) }
    var extensionStagingRoot:URL { sessionURL.deletingLastPathComponent().appendingPathComponent("ExtensionStaging",isDirectory:true) }
    func extensionRecords(profileID:UUID) -> [BrowserExtensionRecord] { library(for:profileID).extensions ?? [] }
    private func requireExtensionEdits(_ profileID:UUID) throws -> BrowserProfile {
        guard !isShuttingDown else { throw CancellationError() }
        guard !isPrivate else { throw ProfileError.privateMode }
        guard savingEnabled, vault != nil, let metadataOwnership else { throw ProfileError.locked }
        try metadataOwnership.validate()
        guard !profileDataOperationInProgress else { throw ProfileError.busy }
        try requireQuickProfile(profileID)
        guard let profile = profiles.first(where:{$0.id == profileID}), profile.extensionControllerID != nil else { throw ProfileError.locked }
        return profile
    }
    func extensionInstallApproval(for package:PreparedExtensionPackage,profileID:UUID,replacing:UUID? = nil,permissions:[String] = [],hostPatterns:[String] = [],allowPrivate:Bool = false,enable:Bool = false) throws -> ExtensionInstallApproval {
        let profile = try requireExtensionEdits(profileID), records = extensionRecords(profileID:profileID)
        let previous = replacing.flatMap { id in records.first(where:{$0.id == id}) }
        guard replacing == nil || previous != nil else { throw ExtensionActionError.missing }
        guard previous?.pendingRemoval != true else { throw ExtensionActionError.stale }
        if let signer = previous?.signerID, signer != package.signerID { throw ExtensionActionError.stale }
        let id = previous?.id ?? UUID()
        var record = BrowserExtensionRecord(id:id,name:package.manifest.name,version:package.manifest.version,manifestVersion:package.manifest.manifestVersion,packageDigest:package.digest,source:package.source,
            requestedPermissions:package.manifest.requestedPermissions,optionalPermissions:package.manifest.optionalPermissions,hostPermissions:package.manifest.hostPermissions,optionalHostPermissions:package.manifest.optionalHostPermissions)
        record.packageID = previous?.packageID ?? id; record.summary = package.manifest.summary; record.incognito = package.manifest.incognito
        record.signerID = package.signerID; record.storeID = package.storeID; record.publisherVerified = package.publisherVerified
        if enable || !permissions.isEmpty || !hostPatterns.isEmpty || allowPrivate {
            record.grants = ExtensionGrantSet(profileID:profileID,recordID:id,controllerID:profile.extensionControllerID!,packageDigest:package.digest,permissions:permissions,hostPatterns:hostPatterns,allowPrivate:allowPrivate)
            record.enabled = enable
            record = try validatedExtensionRecord(record,profile:profile)
        }
        guard record.hasValidIdentity else { throw ExtensionActionError.invalidApproval }
        guard !records.contains(where:{$0.id != replacing && $0.runtimeIdentifier == record.runtimeIdentifier}) else { throw ExtensionActionError.stale }
        return ExtensionInstallApproval(store:self,profileID:profileID,controllerID:profile.extensionControllerID!,record:record,previous:previous)
    }
    private func validateExtensionReview(_ approval:ExtensionInstallApproval,replacing:UUID?) throws {
        let profile = try requireExtensionEdits(approval.profileID)
        guard approval.store === self, profile.extensionControllerID == approval.controllerID,
              extensionReviewEpoch(for:approval.profileID) == approval.policyEpoch,
              approval.previous?.id == replacing else { throw ExtensionActionError.stale }
        let records = extensionRecords(profileID:approval.profileID)
        if let previous = approval.previous { guard records.first(where:{$0.id == previous.id}) == previous else { throw ExtensionActionError.stale } }
        else { guard !records.contains(where:{$0.id == approval.record.id}) else { throw ExtensionActionError.stale } }
        guard !records.contains(where:{$0.id != replacing && $0.runtimeIdentifier == approval.record.runtimeIdentifier}) else { throw ExtensionActionError.stale }
    }
    @discardableResult func installExtension(_ package:PreparedExtensionPackage,replacing:UUID? = nil,approval:ExtensionInstallApproval) async throws -> UUID {
        guard !approval.consumed else { throw ExtensionActionError.stale }; approval.consumed = true
        try validateExtensionReview(approval,replacing:replacing)
        guard package.digest == approval.record.packageDigest, package.source == approval.record.source,
              package.signerID == approval.record.signerID, package.storeID == approval.record.storeID else { throw ExtensionActionError.stale }
        try ExtensionPublicationOwners.begin(sessionURL)
        defer {ExtensionPublicationOwners.end(sessionURL)}
        let operationLease = try MetadataOwnership.acquire(for:sessionURL)
        defer {operationLease.release()}
        let root = extensionPackagesRoot, record = approval.record, profileID = approval.profileID
        extensionInstallationInProgress = true
        defer {extensionInstallationInProgress = false; extensionPublication = nil}
        let publication = Task.detached(priority:.userInitiated) { try ExtensionPackage.publish(package,profileID:profileID,extensionID:record.packageID ?? record.id,packagesRoot:root) }
        extensionPublication = publication
        let installed = try await withTaskCancellationHandler(operation:{ try await publication.value },onCancel:{publication.cancel()})
        do {
            try Task.checkCancellation(); try operationLease.validate(); try validateExtensionReview(approval,replacing:replacing)
            var candidate = makeDocument(), library = candidate.library(for:profileID)
            var records = library.extensions ?? []
            if let replacing, let index = records.firstIndex(where:{$0.id == replacing}) { records[index] = record }
            else { records.append(record) }
            library.extensions = records; candidate.setLibrary(library,for:profileID)
            try commitProfileDocument(candidate)
            return record.id
        } catch {
            // A newly created revision is not another installation's rollback material.
            if installed.created { _ = try? await Task.detached { try installed.removeIfCreated() }.value }
            throw error
        }
    }
    private func validatedExtensionRecord(_ record:BrowserExtensionRecord,profile:BrowserProfile) throws -> BrowserExtensionRecord {
        guard let controller = profile.extensionControllerID, record.grants != nil,
              let repaired = ExtensionCatalog.repaired([record],profileID:profile.id,controllerID:controller).first, repaired.grants != nil else { throw ExtensionActionError.invalidApproval }
        return repaired
    }
    private func persistExtensionRecord(_ record:BrowserExtensionRecord,profileID:UUID) throws {
        var candidate = makeDocument(), library = candidate.library(for:profileID), records = library.extensions ?? []
        guard let index = records.firstIndex(where:{$0.id == record.id}) else { throw ExtensionActionError.missing }
        records[index] = record; library.extensions = records; candidate.setLibrary(library,for:profileID)
        try commitProfileDocument(candidate)
    }
    func setExtensionEnabled(_ id:UUID,profileID:UUID,enabled:Bool) throws {
        let profile = try requireExtensionEdits(profileID)
        guard var record = extensionRecords(profileID:profileID).first(where:{$0.id == id}) else { throw ExtensionActionError.missing }
        guard record.pendingRemoval != true else { throw ExtensionActionError.stale }
        if enabled {
            guard record.grants != nil else { throw ExtensionActionError.approvalRequired }
            record = try validatedExtensionRecord(record,profile:profile)
        }
        record.enabled = enabled; try persistExtensionRecord(record,profileID:profileID)
    }
    func setExtensionGrants(_ id:UUID,profileID:UUID,grants:ExtensionGrantSet?) throws {
        let profile = try requireExtensionEdits(profileID)
        guard var record = extensionRecords(profileID:profileID).first(where:{$0.id == id}) else { throw ExtensionActionError.missing }
        guard record.pendingRemoval != true else { throw ExtensionActionError.stale }
        record.grants = grants
        if grants != nil { record = try validatedExtensionRecord(record,profile:profile) }
        else {record.revokeApproval()}
        try persistExtensionRecord(record,profileID:profileID)
    }
    func beginRemoveExtension(_ id:UUID,profileID:UUID) throws {
        _ = try requireExtensionEdits(profileID)
        guard var record = extensionRecords(profileID:profileID).first(where:{$0.id == id}) else { throw ExtensionActionError.missing }
        record.pendingRemoval = true; record.revokeApproval(); try persistExtensionRecord(record,profileID:profileID)
    }
    /// Used during extension startup/repair before native contexts are loaded.
    @discardableResult func reconcileExtensionPackages() async throws -> Int {
        guard !isShuttingDown else {throw CancellationError()}
        guard !isPrivate else {throw ProfileError.privateMode}
        guard savingEnabled, vault != nil, let metadataOwnership else {throw ProfileError.locked}
        try metadataOwnership.validate()
        guard !profileDataOperationInProgress else {throw ProfileError.busy}
        try ExtensionPublicationOwners.begin(sessionURL)
        defer {ExtensionPublicationOwners.end(sessionURL)}
        let lease = try MetadataOwnership.acquire(for:sessionURL)
        defer {lease.release()}
        let packages = extensionPackagesRoot, staging = extensionStagingRoot, libraries = profileLibraries
        let work = Task.detached(priority:.utility) {try ExtensionPackage.reconcile(packagesRoot:packages,stagingRoot:staging,libraries:libraries)}
        extensionMaintenance = work; defer {extensionMaintenance = nil}
        return try await withTaskCancellationHandler(operation:{try await work.value},onCancel:{work.cancel()})
    }
    func finishRemoveExtension(_ id:UUID,profileID:UUID) throws {
        _ = try requireExtensionEdits(profileID)
        guard let record = extensionRecords(profileID:profileID).first(where:{$0.id == id}), record.pendingRemoval == true else { throw ExtensionActionError.stale }
        try ExtensionPackage.removeRevision(profileID:profileID,extensionID:record.packageID ?? record.id,digest:record.packageDigest,packagesRoot:extensionPackagesRoot)
        var candidate = makeDocument(), library = candidate.library(for:profileID)
        library.extensions?.removeAll{$0.id == id}; candidate.setLibrary(library,for:profileID)
        try commitProfileDocument(candidate)
    }
}
