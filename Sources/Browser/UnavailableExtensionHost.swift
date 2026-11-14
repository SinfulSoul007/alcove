import Foundation
import WebKit
import BrowserCore

/// Non-native recovery host for supported macOS versions without extension APIs.
/// It never loads extension code and never turns a saved approval off silently.
@MainActor final class UnavailableBrowserExtensionHost:BrowserExtensionHosting {
    private final class Binding:NSObject {
        let profile:UUID
        weak var dataStore:WKWebsiteDataStore?
        init(_ profile:UUID,_ dataStore:WKWebsiteDataStore) {self.profile=profile;self.dataStore=dataStore}
    }
    private weak var owner:BrowserStore?
    private let bindings=NSMapTable<WKUserContentController,Binding>(keyOptions:.weakMemory,valueOptions:.strongMemory)
    private var bypasses:[UUID:([BrowserExtensionRecord],UUID)]=[:]
    init(owner:BrowserStore) {self.owner=owner}
    private func current(_ profile:UUID) throws -> BrowserStore {
        guard let owner,!owner.isShuttingDown,!owner.isPrivate,!owner.awaitingInitialMetadata,owner.vault != nil,!owner.profileUnavailable(profile) else {throw ProfileError.locked}
        try owner.metadataOwnership?.validate();return owner
    }
    private func expected(_ profile:UUID) -> Bool {owner?.extensionRecords(profileID:profile).contains{$0.enabled && $0.pendingRemoval != true}==true}
    private func bypassed(_ profile:UUID) -> Bool {
        guard let owner,let value=bypasses[profile] else {return false}
        return value.0==owner.extensionRecords(profileID:profile) && value.1==owner.extensionReviewEpoch(for:profile)
    }
    func configure(_ configuration:WKWebViewConfiguration,profileID:UUID) {
        guard (try? current(profileID)) != nil else {return}
        bindings.setObject(Binding(profileID,configuration.websiteDataStore),forKey:configuration.userContentController)
    }
    func matches(_ configuration:WKWebViewConfiguration,profileID:UUID) -> Bool {
        guard (try? current(profileID)) != nil,let binding=bindings.object(forKey:configuration.userContentController) else {return false}
        return binding.profile==profileID && binding.dataStore === configuration.websiteDataStore
    }
    func requiresPreparation(profileID:UUID) -> Bool {expected(profileID) && !bypassed(profileID)}
    func prepare(profileID:UUID) async throws {
        let owner=try current(profileID)
        guard requiresPreparation(profileID:profileID) else {return}
        owner.extensionStates[profileID] = .failed(ExtensionHostError.unavailable.localizedDescription)
        throw ExtensionHostError.unavailable
    }
    func continueWithout(profileID:UUID) throws {
        let owner=try current(profileID)
        bypasses[profileID]=(owner.extensionRecords(profileID:profileID),owner.extensionReviewEpoch(for:profileID))
        owner.extensionStates[profileID] = .failed("Continuing without extensions in this profile for this session. Saved approvals are unchanged. Update macOS before retrying extension setup.")
    }
    func invalidate(profileID:UUID) {bypasses.removeValue(forKey:profileID);owner?.extensionStates.removeValue(forKey:profileID)}
    func refresh() {
        guard let owner,!owner.isShuttingDown else {shutdown();return}
        for profile in Array(bypasses.keys) where !bypassed(profile) {bypasses.removeValue(forKey:profile)}
        for profile in owner.profiles where !owner.profileUnavailable(profile.id) {
            if requiresPreparation(profileID:profile.id) {
                let state=ExtensionProfileState.failed(ExtensionHostError.unavailable.localizedDescription)
                if owner.extensionStates[profile.id] != state {owner.extensionStates[profile.id]=state}
            } else if !expected(profile.id) {owner.extensionStates.removeValue(forKey:profile.id)}
        }
    }
    func shutdown() {bindings.removeAllObjects();bypasses=[:];owner=nil}
}
