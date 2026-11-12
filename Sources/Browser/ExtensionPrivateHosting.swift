import Foundation
import WebKit
import BrowserCore

extension BrowserStore {
    /// Only a new temporary session may attach a controller. Existing documents require
    /// an explicit reopen flow, since WKWebView configurations cannot change in place.
    func associateExtensions(with owner:BrowserWindowOwner,profileID:UUID) throws {
        guard isPrivate,!isShuttingDown,!owner.isClosed,!owner.store.isPrivate else {throw ExtensionHostError.closed}
        guard views.isEmpty,peekPages.isEmpty,extensionHosting == nil else {throw QuickBrowseError.consentRequired}
        let normal = owner.store
        guard !normal.isShuttingDown,!normal.awaitingInitialMetadata,normal.vault != nil,
              !normal.profileUnavailable(profileID),normal.persistedProfileIDs.contains(profileID),
              let controllerID = normal.profiles.first(where:{$0.id == profileID})?.extensionControllerID,
              let metadataOwnership = normal.metadataOwnership else {throw ProfileError.locked}
        try metadataOwnership.validate()
        guard #available(macOS 15.4,*) else {throw ExtensionHostError.unavailable}
        guard let server = normal.ensureExtensionHost() as? NativeBrowserExtensionHost else {throw ExtensionHostError.unavailable}
        let lease = try owner.acquireAuxiliary()
        extensionHosting = AssociatedPrivateExtensionHost(owner:owner,server:server,profileID:profileID,controllerID:controllerID,lease:lease)
    }
}

@available(macOS 15.4,*) @MainActor final class AssociatedPrivateExtensionHost:BrowserExtensionHosting {
    private var owner:BrowserWindowOwner?
    private let server:NativeBrowserExtensionHost,profileID:UUID,controllerID:UUID,lease:UUID
    init(owner:BrowserWindowOwner,server:NativeBrowserExtensionHost,profileID:UUID,controllerID:UUID,lease:UUID) {
        self.owner = owner;self.server = server;self.profileID = profileID;self.controllerID = controllerID;self.lease = lease
    }
    private func normal() throws -> BrowserStore {
        guard let owner,!owner.isClosed,!owner.store.isShuttingDown else {throw ExtensionHostError.closed}
        let normal = owner.store
        guard !normal.awaitingInitialMetadata,normal.vault != nil,!normal.profileUnavailable(profileID),
              normal.extensionHosting === server,
              normal.profiles.first(where:{$0.id == profileID})?.extensionControllerID == controllerID,
              let metadataOwnership = normal.metadataOwnership else {throw ExtensionHostError.stale}
        try metadataOwnership.validate();return normal
    }
    private func expectsPrivateExtensions() throws -> Bool {
        try normal().extensionRecords(profileID:profileID).contains{$0.enabled && $0.pendingRemoval != true && $0.grants?.allowPrivate == true}
    }
    func configure(_ configuration:WKWebViewConfiguration,profileID localID:UUID) {
        guard localID == BrowserProfile.defaultID,(try? normal()) != nil else {configuration.webExtensionController = nil;return}
        server.configure(configuration,profileID:profileID)
    }
    func matches(_ configuration:WKWebViewConfiguration,profileID localID:UUID) -> Bool {
        localID == BrowserProfile.defaultID && (try? normal()) != nil && server.matches(configuration,profileID:profileID)
    }
    func requiresPreparation(profileID localID:UUID) -> Bool {
        guard localID == BrowserProfile.defaultID,let expected = try? expectsPrivateExtensions() else {return true}
        return expected && server.requiresPreparation(profileID:profileID)
    }
    func prepare(profileID localID:UUID) async throws {
        guard localID == BrowserProfile.defaultID else {throw ExtensionHostError.stale}
        guard try expectsPrivateExtensions() else {return}
        try await server.prepare(profileID:profileID)
        _ = try normal()
    }
    func invalidate(profileID localID:UUID) {if localID == BrowserProfile.defaultID,(try? normal()) != nil {server.invalidate(profileID:profileID)}}
    func continueWithout(profileID localID:UUID) throws {
        _ = try normal()
        throw ExtensionHostError.native("Reopen this private session without extensions to change its controller. Unsaved forms would be lost.")
    }
    func refresh() {server.browserStateChanged()}
    func shutdown() {
        guard let owner else {return};self.owner = nil;owner.release(lease)
    }
}
