import AppKit
import WebKit
import BrowserCore

/// Structural cleanup ownership survives retirement of the currently active host.
/// This weak registry never grants browser API access or retains a private session.
@MainActor final class PrivateExtensionAttachment {
    weak var client:BrowserStore?,association:(any BrowserExtensionHosting)?
    let profileID:UUID,controllerID:UUID
    init(client:BrowserStore,association:any BrowserExtensionHosting,profileID:UUID,controllerID:UUID) {
        self.client = client;self.association = association;self.profileID = profileID;self.controllerID = controllerID
    }
    var attached:BrowserStore? {
        guard let client,let association,client.isPrivate,!client.isShuttingDown,client.extensionHosting === association else {return nil}
        return client
    }
}

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
        let association = AssociatedPrivateExtensionHost(client:self,owner:owner,server:server,profileID:profileID,controllerID:controllerID,lease:lease)
        extensionHosting = association
        association.publishAttachment()
        server.privateClients[extensionStoreID] = NativePrivateExtensionClient(store:self,association:association,profileID:profileID)
        server.browserStateChanged()
    }
}

@available(macOS 15.4,*) @MainActor final class AssociatedPrivateExtensionHost:BrowserExtensionHosting {
    private weak var client:BrowserStore?
    private var owner:BrowserWindowOwner?
    private let server:NativeBrowserExtensionHost,profileID:UUID,controllerID:UUID,lease:UUID
    init(client:BrowserStore,owner:BrowserWindowOwner,server:NativeBrowserExtensionHost,profileID:UUID,controllerID:UUID,lease:UUID) {
        self.client = client;self.owner = owner;self.server = server;self.profileID = profileID;self.controllerID = controllerID;self.lease = lease
    }
    func publishAttachment() {
        guard let owner,let client,client.extensionHosting === self else {return}
        owner.store.extensionPrivateAttachments[client.extensionStoreID] = PrivateExtensionAttachment(client:client,association:self,profileID:profileID,controllerID:controllerID)
    }
    /// Cleanup must retain a live attachment while its normal profile is paused or
    /// its controller identity changes. This does not authorize extension API access.
    func isAttached(client:BrowserStore,profileID:UUID) -> Bool {
        guard let owner,!owner.isClosed,!owner.store.isShuttingDown else {return false}
        return self.client === client && client.isPrivate && !client.isShuttingDown && client.extensionHosting === self && self.profileID == profileID
    }
    func matches(client:BrowserStore,profileID:UUID) -> Bool {
        isAttached(client:client,profileID:profileID) && (try? normal()) != nil
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
    func browserStateChanged() {server.browserStateChanged()}
    func sourceDocumentChanged(_ web:WKWebView) {server.sourceDocumentChanged(web)}
    func allowsExtensionURL(_ url:URL,profileID localID:UUID) -> Bool {
        guard localID == BrowserProfile.defaultID,(try? normal()) != nil,
              let context = server.profiles[profileID]?.controller.extensionContext(for:url),let client,
              server.authorized(context,profileID:profileID,client:client) else {return false}
        return server.allowsExtensionURL(url,profileID:profileID)
    }
    func configuration(for url:URL,profileID localID:UUID) -> WKWebViewConfiguration? {
        // Context configurations are related to the normal extension process/data store.
        // Replacing that store aborts WKWebView initialization; borrowing it would leak
        // normal website state. A private extension-page runtime is required first.
        return nil
    }
    func optionsURL(_ id:UUID,profileID localID:UUID) -> URL? {
        guard localID == BrowserProfile.defaultID,(try? normal()) != nil,
              let url = server.optionsURL(id,profileID:profileID),
              allowsExtensionURL(url,profileID:localID) else {return nil}
        return url
    }
    func actionSummaries(for web:WKWebView,profileID localID:UUID) -> [BrowserExtensionActionSummary] {
        guard localID == BrowserProfile.defaultID,(try? normal()) != nil,let client else {return []}
        return server.actionSummaries(for:web,profileID:profileID,client:client)
    }
    func performAction(_ id:UUID,from web:WKWebView,profileID localID:UUID,anchor:NSView) throws {
        guard localID == BrowserProfile.defaultID,let client else {throw ExtensionHostError.stale}
        _ = try normal();try server.performAction(id,from:web,profileID:profileID,client:client,anchor:anchor)
    }
    func shutdown() {
        guard let owner else {return}
        if let client,owner.store.extensionPrivateAttachments[client.extensionStoreID]?.association === self {owner.store.extensionPrivateAttachments.removeValue(forKey:client.extensionStoreID)}
        if let client {server.privateClients.removeValue(forKey:client.extensionStoreID);server.synchronizeBrowserState()}
        self.owner = nil;owner.release(lease)
    }
    func commandSummaries(for web:WKWebView,profileID localID:UUID) -> [BrowserExtensionCommandSummary] {
        guard localID == BrowserProfile.defaultID,(try? normal()) != nil,let client else {return []}
        return server.commandSummaries(for:web,profileID:profileID,client:client)
    }
    func performCommand(_ id:UUID,command:String,from web:WKWebView,profileID localID:UUID,anchor:NSView) throws {
        guard localID == BrowserProfile.defaultID,let client else {throw ExtensionHostError.stale}
        _ = try normal();try server.performCommand(id,command:command,from:web,profileID:profileID,client:client,anchor:anchor)
    }
    func performCommand(for event:NSEvent,from web:WKWebView,profileID localID:UUID,anchor:NSView) throws -> Bool {
        guard localID == BrowserProfile.defaultID,let client else {return false}
        _ = try normal();return try server.performCommand(for:event,from:web,profileID:profileID,client:client,anchor:anchor)
    }
    func contextMenuGroups(for target:BrowserExtensionTabTarget,profileID localID:UUID) -> [BrowserExtensionMenuGroup] {
        guard localID == BrowserProfile.defaultID,(try? normal()) != nil,let client else {return []}
        return server.contextMenuGroups(for:target,profileID:profileID,client:client)
    }
}

@available(macOS 15.4,*) @MainActor final class NativePrivateExtensionClient {
    weak var store:BrowserStore?,association:AssociatedPrivateExtensionHost?
    let profileID:UUID
    init(store:BrowserStore,association:AssociatedPrivateExtensionHost,profileID:UUID) {self.store = store;self.association = association;self.profileID = profileID}
    var attached:BrowserStore? {guard let store,association?.isAttached(client:store,profileID:profileID) == true else {return nil};return store}
    var current:BrowserStore? {guard let store,association?.matches(client:store,profileID:profileID) == true else {return nil};return store}
}
