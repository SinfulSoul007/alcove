import AppKit
import BrowserCore

private actor EaselRasterDecoder {
    static let shared = EaselRasterDecoder()
    func preview(assets: EaselAssetStore, id: UUID, size: Int) throws -> CGImage {
        try Task.checkCancellation()
        guard let bytes = try assets.read(id) else { throw EaselImageError.unreadable }
        let image = try EaselRaster(data: bytes).thumbnail(maxPixelSize: size)
        try Task.checkCancellation()
        return image
    }
}

/// Native cards borrow pixels only while drawing. The cache is their sole
/// persistent raster owner; offscreen cards never retain full-size images.
@MainActor final class EaselImagePreviewCache {
    private struct Key: Hashable { let profile: UUID, asset: UUID, size: Int }
    private struct Entry { let image: CGImage, generation: UUID, cost: Int; var access: UInt64 }
    private weak var owner: BrowserStore?
    private let maximumBytes: Int
    private var entries: [Key: Entry] = [:]
    private struct Pending { let id = UUID(); let task: Task<CGImage, Error> }
    private var pending: [Key: Pending] = [:]
    private var clock: UInt64 = 0
    private(set) var decodedBytes = 0
    init(owner: BrowserStore, maximumBytes: Int = 96 * 1024 * 1024) {
        self.owner = owner; self.maximumBytes = max(1024, min(96 * 1024 * 1024, maximumBytes))
    }
    func image(assetID: UUID, profileID: UUID, maxPixelSize: Int) -> CGImage? {
        guard let owner, !owner.isShuttingDown, !owner.profileUnavailable(profileID) else { clear(); return nil }
        let key = Key(profile: profileID, asset: assetID, size: maxPixelSize)
        guard var entry = entries[key] else { return nil }
        guard owner.easelImageGeneration(for: profileID) == entry.generation else { clear(profileID: profileID); return nil }
        clock &+= 1; entry.access = clock; entries[key] = entry
        return entry.image
    }
    func load(assetID: UUID, profileID: UUID, maxPixelSize: Int) async throws -> CGImage {
        guard (1...8192).contains(maxPixelSize), let owner, !owner.isShuttingDown, !owner.profileUnavailable(profileID) else { clear(); throw EaselImageError.unreadable }
        if let image = image(assetID: assetID, profileID: profileID, maxPixelSize: maxPixelSize) { return image }
        let key = Key(profile: profileID, asset: assetID, size: maxPixelSize)
        let generation = owner.easelImageGeneration(for: profileID)
        let request: Pending
        if let existing = pending[key] { request = existing }
        else {
            let assets = try owner.easelAssets(for: profileID)
            request = Pending(task: Task { try await EaselRasterDecoder.shared.preview(assets: assets, id: assetID, size: maxPixelSize) })
            pending[key] = request
        }
        defer { if pending[key]?.id == request.id { pending.removeValue(forKey: key) } }
        let image = try await request.task.value
        guard !owner.isShuttingDown, !owner.profileUnavailable(profileID), owner.easelImageGeneration(for: profileID) == generation else { throw CancellationError() }
        let cost = image.bytesPerRow * image.height
        guard cost <= maximumBytes else { throw EaselImageError.size }
        if let old = entries.removeValue(forKey: key) { decodedBytes -= old.cost }
        while decodedBytes > maximumBytes - cost, let oldest = entries.min(by: { $0.value.access < $1.value.access }) {
            entries.removeValue(forKey: oldest.key); decodedBytes -= oldest.value.cost
        }
        clock &+= 1; entries[key] = Entry(image: image, generation: generation, cost: cost, access: clock); decodedBytes += cost
        return image
    }
    func clear(profileID: UUID? = nil) {
        for key in Array(entries.keys) where profileID == nil || key.profile == profileID {
            if let entry = entries.removeValue(forKey: key) { decodedBytes -= entry.cost }
        }
        for key in Array(pending.keys) where profileID == nil || key.profile == profileID { pending.removeValue(forKey: key)?.task.cancel() }
    }
}

extension BrowserStore {
    var easelImagePreviews: EaselImagePreviewCache {
        let writer = isPrivate ? self : metadataWriter
        if let cache = writer.retainedEaselImagePreviews { return cache }
        let cache = EaselImagePreviewCache(owner: writer); writer.retainedEaselImagePreviews = cache; return cache
    }
}

@MainActor final class EaselImageCardContent: NSView {
    private weak var store: BrowserStore?
    private var profile: UUID?, asset: UUID?, generation: UUID?
    private var currentScope: () -> Bool = { false }
    private var task: Task<Void, Never>?
    private var failed = false
    private let previewSize = 1024
    override var isFlipped: Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); setAccessibilityRole(.image); setAccessibilityLabel("Saved canvas image") }
    required init?(coder: NSCoder) { nil }
    func configure(store: BrowserStore, profile: UUID, asset: UUID, isCurrent: @escaping () -> Bool) {
        let generation = store.easelImageGeneration(for: profile)
        if self.store !== store || self.profile != profile || self.asset != asset || self.generation != generation {
            task?.cancel(); task = nil; failed = false
        }
        self.store = store; self.profile = profile; self.asset = asset; self.generation = generation; currentScope = isCurrent
        needsDisplay = true
    }
    var displayedImage: CGImage? {
        guard currentScope(), let store, !store.isShuttingDown, let profile, let asset,
              store.easelImageGeneration(for: profile) == generation else { return nil }
        return store.easelImagePreviews.image(assetID: asset, profileID: profile, maxPixelSize: previewSize)
    }
    func requestPreview() {
        guard !failed, task == nil, displayedImage == nil, currentScope(), let store, !store.isShuttingDown,
              let profile, let asset, store.easelImageGeneration(for: profile) == generation else { return }
        let cache = store.easelImagePreviews, captured = generation
        task = Task { [weak self] in
            do { _ = try await cache.load(assetID: asset, profileID: profile, maxPixelSize: 1024) }
            catch { if !Task.isCancelled { self?.failed = true } }
            guard let self, !Task.isCancelled, self.generation == captured else { return }
            self.task = nil; self.needsDisplay = true
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        if let raster = displayedImage {
            let ratio = min(bounds.width / CGFloat(raster.width), bounds.height / CGFloat(raster.height))
            let size = NSSize(width: CGFloat(raster.width) * ratio, height: CGFloat(raster.height) * ratio)
            let rect = NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
            NSImage(cgImage: raster, size: size).draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            requestPreview()
            let text = failed ? "Image unavailable" : "Loading image…"
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]
            let size = (text as NSString).size(withAttributes: attrs)
            (text as NSString).draw(at: NSPoint(x: max(0, (bounds.width - size.width) / 2), y: max(0, (bounds.height - size.height) / 2)), withAttributes: attrs)
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
