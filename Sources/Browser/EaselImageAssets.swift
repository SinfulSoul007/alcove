import Foundation
import BrowserCore

@MainActor struct EaselImageDestination {
    weak var store: BrowserStore?
    let tabID: UUID, profileID: UUID, easelID: UUID, revision: UUID, generation: UUID
    let presentation: NSUUID?
}

extension BrowserStore {
    func easelImageGeneration(for profile: UUID) -> UUID {
        let writer = isPrivate ? self : metadataWriter
        if let value = writer.easelImageGenerations[profile] { return value }
        let value = UUID(); writer.easelImageGenerations[profile] = value; return value
    }
    func invalidateEaselImages(for profile: UUID) {
        let writer = isPrivate ? self : metadataWriter
        writer.easelImageGenerations[profile] = UUID()
        writer.retainedEaselImagePreviews?.clear(profileID: profile)
    }
    func easelAssets(for profile: UUID) throws -> EaselAssetStore {
        guard !isShuttingDown, !profileUnavailable(profile), canModifyLocalMetadata else { throw ProfileError.locked }
        let writer = isPrivate ? self : metadataWriter
        if let existing = writer.easelAssetStores[profile] { return existing }
        let assets: EaselAssetStore
        if isPrivate { assets = EaselAssetStore(privateProfileID: profile) }
        else {
            guard !writer.isPrivate, !writer.isShuttingDown, let vault = writer.vault, let lease = writer.metadataOwnership else { throw ProfileError.locked }
            try lease.validate()
            assets = try EaselAssetStore(root: vault.url.deletingLastPathComponent(), profileID: profile, key: vault.key, ownership: lease)
        }
        writer.easelAssetStores[profile] = assets
        return assets
    }
    func easelImageDestination(for tab: UUID) throws -> EaselImageDestination {
        try flushEaselBoardDrafts(in: tab)
        guard let context = easelContext(for: tab), canModifyLocalMetadata else { throw EaselActionError.missing }
        return EaselImageDestination(store: self, tabID: tab, profileID: context.profileID, easelID: context.easel.id,
                                     revision: context.easel.revision, generation: easelImageGeneration(for: context.profileID),
                                     presentation: windowGroup?.extensionPresentationIdentity(for: tab))
    }
    func isCurrentEaselImageDestination(_ destination: EaselImageDestination) -> Bool {
        guard destination.store === self, canModifyLocalMetadata,
              let context = easelContext(for: destination.tabID), context.profileID == destination.profileID,
              context.easel.id == destination.easelID, context.easel.revision == destination.revision,
              easelImageGeneration(for: destination.profileID) == destination.generation else { return false }
        guard existingEaselDrafts?.hasDrafts(easelID: destination.easelID, profileID: destination.profileID) != true else { return false }
        return windowGroup?.extensionPresentationIdentity(for: destination.tabID) === destination.presentation
    }
    @discardableResult func addEaselImage(_ raster: EaselRaster, to destination: EaselImageDestination,
                                         sourceURL: String? = nil, sourceTitle: String? = nil) throws -> EaselItem {
        guard isCurrentEaselImageDestination(destination) else { throw SearchInputError.contextChanged }
        let assets = try easelAssets(for: destination.profileID)
        let id = try assets.put(raster.data)
        var committed = false
        defer { if !committed { try? assets.remove(id) } }
        let width = min(640, max(120, Double(raster.pixelWidth)))
        let height = min(640, max(80, width * Double(raster.pixelHeight) / Double(raster.pixelWidth)))
        let item = try EaselItem(frame: EaselFrame(x: 80, y: 80, width: width, height: height),
                                 content: .image(assetID: id, pixelWidth: raster.pixelWidth, pixelHeight: raster.pixelHeight, sourceURL: sourceURL, sourceTitle: sourceTitle))
        guard isCurrentEaselImageDestination(destination) else { throw SearchInputError.contextChanged }
        _ = try editEasel(in: destination.tabID, expectedRevision: destination.revision, edits: [.insert(item)])
        committed = true; return item
    }
    func pruneEaselAssets(for profile: UUID) throws {
        let writer = isPrivate ? self : metadataWriter
        let assets = try easelAssets(for: profile)
        var retained = Set((library(for: profile).easels ?? []).flatMap(\.items).compactMap { item -> UUID? in
            item.content.previewAssetID
        })
        for canvas in writer.easelCanvasViews.allObjects { retained.formUnion(canvas.retainedImageIDs(profile: profile)) }
        try assets.prune(retaining: retained)
    }
    /// Capture the directory-bound store before an asynchronous profile operation.
    /// Later metadata retry/failure state cannot redirect the erasure root.
    func prepareEaselAssetErasure(for profile: UUID) throws -> EaselAssetStore {
        guard !isPrivate, metadataWriter === self, !isShuttingDown,
              profiles.contains(where: { $0.id == profile }), let vault, let lease = metadataOwnership else { throw ProfileError.pending }
        try lease.validate()
        if let held = easelAssetStores[profile] { return held }
        return try EaselAssetStore(root: sessionURL.deletingLastPathComponent(), profileID: profile, key: vault.key, ownership: lease)
    }
    func eraseEaselAssets(for profile: UUID, using assets: EaselAssetStore) throws {
        guard !isPrivate, metadataWriter === self, !isShuttingDown, assets.profileID == profile,
              profiles.contains(where: { $0.id == profile && $0.isPendingDeletion }) else { throw ProfileError.pending }
        try assets.prune(retaining: [])
        retainedEaselImagePreviews?.clear(profileID: profile)
        easelAssetStores.removeValue(forKey: profile)
    }
    func closeEaselAssets() {
        retainedEaselImagePreviews?.clear(); retainedEaselImagePreviews = nil
        easelImageGenerations.removeAll()
        easelCanvasViews.removeAllObjects()
        if isPrivate { for assets in easelAssetStores.values { try? assets.prune(retaining: []) } }
        easelAssetStores.removeAll()
    }
}
