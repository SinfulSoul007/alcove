import AppKit
import BrowserCore
import ImageIO
import UniformTypeIdentifiers

// Catches unbounded decoded caching, full-raster previews, repeated decoding,
// and a cached private image remaining readable after its browsing group closes.
@main struct EaselImagePreviewChecks {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited); setbuf(stdout, nil)
        var checks = 0, failures = 0
        func check(_ value: Bool, _ name: String) { checks += 1; print("\(value ? "PASS" : "FAIL"): \(name)"); if !value { failures += 1 } }
        let store = BrowserStore(isPrivate: true, keyProvider: { _ in fatalError("Private preview requested a key") }); defer { store.shutdown() }
        let tab = try store.createEasel()
        let context = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 800, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        let data = NSMutableData(), encoder = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(encoder, context.makeImage()!, nil); precondition(CGImageDestinationFinalize(encoder))
        let item = try store.addEaselImage(EaselRaster(data: data as Data), to: store.easelImageDestination(for: tab))
        guard case .image(let id, _, _, _, _) = item.content else { fatalError() }
        let profile = BrowserProfile.defaultID
        let cache = EaselImagePreviewCache(owner: store, maximumBytes: 2048)
        let first = try await cache.load(assetID: id, profileID: profile, maxPixelSize: 16)
        check(first.width == 16 && first.height == 8, "Preview cache decodes to the requested display size")
        let second = try await cache.load(assetID: id, profileID: profile, maxPixelSize: 16)
        check(first === second, "Repeated previews reuse the same bounded decoded image")
        _ = try await cache.load(assetID: id, profileID: profile, maxPixelSize: 24)
        _ = try await cache.load(assetID: id, profileID: profile, maxPixelSize: 32)
        check(cache.decodedBytes <= 2048 && cache.image(assetID: id, profileID: profile, maxPixelSize: 16) == nil, "Decoded preview cache evicts old sizes within its byte budget")
        let canvas = EaselCanvasView(store: store, tabID: tab)
        guard let content = canvas.cards[item.id]?.imageContent else { fatalError("No native image card") }
        content.requestPreview()
        for _ in 0..<200 where content.displayedImage == nil { try await Task.sleep(for: .milliseconds(10)) }
        check(content.displayedImage?.width == 200 && content.displayedImage?.height == 100, "A native canvas image card displays a real validated raster")
        _ = try canvas.addImage(EaselRaster(data: data as Data), to: store.easelImageDestination(for: tab))
        canvas.undoManager?.undo()
        check(store.easelContext(for: tab)?.easel.items.count == 1, "Adding an image participates in native canvas undo")
        canvas.undoManager?.redo()
        check(store.easelContext(for: tab)?.easel.items.count == 2, "Native canvas redo restores an imported image card")
        store.shutdown()
        check(content.displayedImage == nil, "A retired native image card cannot display retained private data")
        var rejected = false
        do { _ = try await cache.load(assetID: id, profileID: profile, maxPixelSize: 16) } catch { rejected = true }
        check(rejected && cache.image(assetID: id, profileID: profile, maxPixelSize: 16) == nil, "A held preview cache cannot return private pixels after shutdown")
        print("Easel image preview checks: \(checks) checked, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
