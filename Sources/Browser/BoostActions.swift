import Foundation
import BrowserCore

extension BrowserStore {
    func boostCatalog(profileID: UUID) -> BoostCatalog { BoostCatalog(library(for: profileID).siteBoosts) }
    var boostsEnabled: Bool { preferences.boostsEnabled != false }
    var canEditBoosts: Bool { canModifyLocalMetadata && !isShuttingDown && !profileDataOperationInProgress }

    private func requireBoostEdits(profileID: UUID? = nil) throws {
        guard !isShuttingDown else { throw CancellationError() }
        guard isPrivate || savingEnabled else { throw ProfileError.locked }
        guard !profileDataOperationInProgress else { throw ProfileError.busy }
        if let profileID {
            if isPrivate { guard profileID == BrowserProfile.defaultID else { throw ProfileError.missing } }
            else { try requireQuickProfile(profileID) }
        }
    }
    private func persistBoosts(_ entries: [SiteBoost], profileID: UUID) throws {
        try requireBoostEdits(profileID: profileID)
        var candidate = makeDocument(), records = candidate.library(for: profileID)
        records.siteBoosts = entries; candidate.setLibrary(records, for: profileID)
        try commitQuickDocument(candidate)
    }
    func saveBoost(_ raw: SiteBoost, profileID: UUID, expected: SiteBoost? = nil) throws {
        try requireBoostEdits(profileID: profileID)
        let catalog = boostCatalog(profileID: profileID)
        var value: SiteBoost
        if let expected {
            guard raw.id == expected.id, let current = catalog.entries.first(where: { $0.id == raw.id }), current.content == expected.content else { throw BoostError.stale }
            value = current; value.content = try raw.content.validated()
        } else {
            guard !catalog.entries.contains(where: { $0.id == raw.id }) else { throw BoostError.stale }
            value = try raw.validated(); value.approvedJavaScriptHash = nil
        }
        if !value.content.javascript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { _ = try BoostScript.validatedBody(value.content.javascript) }
        try persistBoosts(catalog.upserting(value), profileID: profileID)
    }
    func removeBoost(_ id: UUID, profileID: UUID) throws {
        try requireBoostEdits(profileID: profileID)
        let catalog = boostCatalog(profileID: profileID)
        guard catalog.entries.contains(where: { $0.id == id }) else { throw BoostError.missing }
        try persistBoosts(catalog.removing(id), profileID: profileID)
    }
    func setBoostEnabled(_ id: UUID, profileID: UUID, enabled: Bool) throws {
        try requireBoostEdits(profileID: profileID)
        let catalog = boostCatalog(profileID: profileID)
        guard var current = catalog.entries.first(where: { $0.id == id }) else { throw BoostError.missing }
        current.enabled = enabled; try persistBoosts(catalog.upserting(current), profileID: profileID)
    }
    func setBoostsEnabled(_ enabled: Bool) throws {
        try requireBoostEdits()
        var candidate = makeDocument(); candidate.preferences.boostsEnabled = enabled
        try commitQuickDocument(candidate)
    }
    func addBoostZap(_ id: UUID, profileID: UUID, selector: String, expected: SiteBoost) throws {
        try requireBoostEdits(profileID: profileID)
        let catalog = boostCatalog(profileID: profileID)
        guard var current = catalog.entries.first(where: { $0.id == id }), current.id == expected.id,
              current.content == expected.content, current.hiddenSelectors == expected.hiddenSelectors else { throw BoostError.stale }
        if current.hiddenSelectors.contains(selector) { return }
        current.hiddenSelectors.append(selector)
        try persistBoosts(catalog.upserting(current), profileID: profileID)
    }
    func undoBoostZap(_ id: UUID, profileID: UUID) throws {
        try requireBoostEdits(profileID: profileID)
        let catalog = boostCatalog(profileID: profileID)
        guard var current = catalog.entries.first(where: { $0.id == id }) else { throw BoostError.missing }
        guard !current.hiddenSelectors.isEmpty else { return }
        current.hiddenSelectors.removeLast(); try persistBoosts(catalog.upserting(current), profileID: profileID)
    }
    func approveBoostJavaScript(_ request: BoostJavaScriptRequest) throws {
        guard !request.consumed else { throw BoostError.stale }
        request.consumed = true
        try requireBoostEdits(profileID: request.source.profileID)
        guard request.source.matches(self), request.source.host == request.host else { throw BoostError.stale }
        let catalog = boostCatalog(profileID: request.source.profileID)
        guard var current = catalog.entries.first(where: { $0.id == request.boostID }), current.content.host == request.host,
              current.scriptHash == request.scriptHash, !current.content.javascript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BoostError.stale }
        _ = try BoostScript.validatedBody(current.content.javascript)
        current.approvedJavaScriptHash = current.scriptHash
        try persistBoosts(catalog.upserting(current), profileID: request.source.profileID)
    }
}
