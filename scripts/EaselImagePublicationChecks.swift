import AppKit
import BrowserCore
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

// Catches plaintext/private disk fallback, key-provider reentry, stale destination
// publication, asset leaks after failed metadata commits, and cross-canvas erasure.
@main struct EaselImagePublicationChecks {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited); setbuf(stdout, nil)
        var checks = 0, failures = 0
        func check(_ value: Bool, _ name: String) { checks += 1; print("\(value ? "PASS" : "FAIL"): \(name)"); if !value { failures += 1 } }
        func rejects(_ name: String, _ body: () throws -> Void) { do { try body(); check(false, name) } catch { check(true, name) } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Alcove.ImagePublication." + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256); var lookups = 0
        let store = BrowserStore(dataRoot: root, keyProvider: { _ in lookups += 1; return key }); defer { store.shutdown() }
        let tab = try store.createEasel(title: "Images"), initialLookups = lookups
        let context = try store.easelImageDestination(for: tab)
        let imageContext = CGContext(data: nil, width: 120, height: 60, bitsPerComponent: 8, bytesPerRow: 480, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        imageContext.setFillColor(CGColor(red: 1, green: 0.3, blue: 0.1, alpha: 1)); imageContext.fill(CGRect(x: 0, y: 0, width: 120, height: 60))
        let data = NSMutableData(), encoder = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(encoder, imageContext.makeImage()!, nil); precondition(CGImageDestinationFinalize(encoder))
        let raster = try EaselRaster(data: data as Data)
        let item = try store.addEaselImage(raster, to: context, sourceURL: "https://example.com/owned", sourceTitle: "Owned page")
        guard case let .image(asset, width, height, source, title) = item.content else { fatalError("Image item missing") }
        check(width == 120 && height == 60 && source == "https://example.com/owned" && title == "Owned page", "Image publication retains actual dimensions and attribution")
        let assets = try store.easelAssets(for: BrowserProfile.defaultID)
        check(try assets.read(asset) == raster.data, "Published image bytes can be read from the matching profile store")
        check(lookups == initialLookups, "Image publication reuses the already-held encryption key without Keychain lookup")
        let folder = root.appendingPathComponent("Easels/" + BrowserProfile.defaultID.uuidString)
        let sealed = folder.appendingPathComponent(asset.uuidString + ".sealed")
        check(try Data(contentsOf: sealed) != raster.data, "Normal imported images are encrypted on disk")
        let saved = try MetadataStore(url: store.sessionURL, key: key).load(BrowserDocument.self)!
        check(saved.library(for: BrowserProfile.defaultID).easels?.first?.items.first == item, "Image metadata is durable before the canvas publishes it")
        rejects("A reused stale destination cannot publish another image") { _ = try store.addEaselImage(raster, to: context) }
        check(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 1, "Stale image publication creates no orphan assets")
        let failureContext = try store.easelImageDestination(for: tab)
        let backup = root.appendingPathComponent("saved-ciphertext"); try FileManager.default.moveItem(at: store.sessionURL, to: backup)
        try FileManager.default.createDirectory(at: store.sessionURL, withIntermediateDirectories: false)
        rejects("A metadata save failure prevents image publication") { _ = try store.addEaselImage(raster, to: failureContext) }
        check(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 1 && store.easelContext(for: tab)?.easel.items.count == 1, "A failed image transaction removes only its newly staged asset")
        try FileManager.default.removeItem(at: store.sessionURL); try FileManager.default.moveItem(at: backup, to: store.sessionURL); store.savingEnabled = true
        let invalidSourceContext = try store.easelImageDestination(for: tab)
        rejects("Image attribution rejects active-content URLs") { _ = try store.addEaselImage(raster, to: invalidSourceContext, sourceURL: "javascript:alert(1)") }
        check(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 1, "A validation failure does not leak a staged asset")
        let second = try store.createEasel(title: "Shared image")
        let copy = try EaselItem(frame: item.frame, content: item.content)
        _ = try store.editEasel(in: second, expectedRevision: store.easelContext(for: second)!.easel.revision, edits: [.insert(copy)])
        try store.deleteLibraryEasel(store.easelContext(for: tab)!.easel.id, profileID: BrowserProfile.defaultID)
        check(try assets.read(asset) == raster.data, "Deleting one canvas preserves an image still referenced by another")
        try store.deleteLibraryEasel(store.easelContext(for: second)!.easel.id, profileID: BrowserProfile.defaultID)
        check(try assets.read(asset) == nil, "Deleting the final referencing canvas removes its unused encrypted image")
        let clearedTab = try store.createEasel(title: "Keep on website clear")
        let clearedItem = try store.addEaselImage(raster, to: store.easelImageDestination(for: clearedTab))
        guard case .image(let clearedAsset, _, _, _, _) = clearedItem.content else { fatalError() }
        let beforeClear = try store.easelImageDestination(for: clearedTab)
        try await store.clearProfileData(BrowserProfile.defaultID, removeData: { _ in })
        check(try store.library.easels?.contains(where: { $0.items.contains(clearedItem) }) == true && assets.read(clearedAsset) == raster.data, "Website-data clear preserves saved canvases and their image assets")
        rejects("Website-data clear invalidates an earlier image chooser destination") { _ = try store.addEaselImage(raster, to: beforeClear) }
        let undoA = try store.createEasel(title: "Delete A")
        let sharedItem = try store.addEaselImage(raster, to: store.easelImageDestination(for: undoA))
        guard case .image(let undoAsset, _, _, _, _) = sharedItem.content else { fatalError() }
        let undoB = try store.createEasel(title: "Undo B")
        let sharedCopy = try EaselItem(frame: sharedItem.frame, content: sharedItem.content)
        _ = try store.editEasel(in: undoB, expectedRevision: store.easelContext(for: undoB)!.easel.revision, edits: [.insert(sharedCopy)])
        let canvas = EaselCanvasView(store: store, tabID: undoB)
        canvas.select(sharedCopy.id); canvas.deleteSelected()
        try store.deleteLibraryEasel(store.easelContext(for: undoA)!.easel.id, profileID: BrowserProfile.defaultID)
        canvas.undoManager?.undo()
        check(try store.easelContext(for: undoB)?.easel.items.contains(sharedCopy) == true && assets.read(undoAsset) == raster.data, "Permanent deletion preserves an image needed by another live canvas undo")
        let named = try store.createProfile(name: "Image profile deletion")
        let namedSpace = store.space.id, namedTab = try store.createEasel()
        let namedItem = try store.addEaselImage(raster, to: store.easelImageDestination(for: namedTab))
        guard case .image(let namedAsset, _, _, _, _) = namedItem.content else { fatalError() }
        let namedAssets = try store.easelAssets(for: named)
        try store.assignProfile(BrowserProfile.defaultID, to: namedSpace)
        let foreign = root.appendingPathComponent("Easels/" + named.uuidString + "/" + UUID().uuidString + ".sealed")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false)
        var deletionFailed = false
        do { try await store.deleteProfile(named, removeStore: { _ in }) } catch { deletionFailed = true }
        check(deletionFailed && store.profiles.first(where: { $0.id == named })?.isPendingDeletion == true, "Asset erasure failure leaves the durable profile tombstone available for retry")
        check(try assets.read(clearedAsset) == raster.data, "A failed named-profile erasure keeps another profile's images")
        try FileManager.default.removeItem(at: foreign)
        try await store.deleteProfile(named, removeStore: { _ in })
        check(try !store.profiles.contains(where: { $0.id == named }) && namedAssets.read(namedAsset) == nil, "Profile deletion retry erases its images before removing the tombstone")
        let reopeningBoard = store.library.easels!.first(where: { $0.items.contains(clearedItem) })!.id
        let privateRoot = root.appendingPathComponent("private-must-not-exist")
        let privateStore = BrowserStore(isPrivate: true, dataRoot: privateRoot, keyProvider: { _ in fatalError("Private images must not request a key") })
        let privateTab = try privateStore.createEasel(), privateAssets = try privateStore.easelAssets(for: BrowserProfile.defaultID)
        let privateItem = try privateStore.addEaselImage(raster, to: privateStore.easelImageDestination(for: privateTab))
        guard case .image(let privateID, _, _, _, _) = privateItem.content else { fatalError() }
        check(try privateAssets.read(privateID) == raster.data && !FileManager.default.fileExists(atPath: privateRoot.path), "Private imported images stay in memory without a normal key or directory")
        let stalePrivate = try privateStore.easelImageDestination(for: privateTab); privateStore.shutdown()
        rejects("Shutdown prevents delayed private image publication") { _ = try privateStore.addEaselImage(raster, to: stalePrivate) }
        check(try privateAssets.read(privateID) == nil, "Closing the private store erases retained private image memory")
        store.shutdown()
        let reopened = BrowserStore(dataRoot: root, keyProvider: { _ in key }); defer { reopened.shutdown() }
        try reopened.deleteLibraryEasel(reopeningBoard, profileID: BrowserProfile.defaultID)
        let reopenedAssets = try reopened.easelAssets(for: BrowserProfile.defaultID)
        check(try reopenedAssets.read(clearedAsset) == nil, "Deleting a canvas after relaunch also cleans its now-unused images")
        print("Easel image publication checks: \(checks) checked, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
