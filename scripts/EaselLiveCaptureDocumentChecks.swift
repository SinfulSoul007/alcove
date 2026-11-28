import Foundation
import CryptoKit
import BrowserCore

@main struct EaselLiveCaptureDocumentChecks {
    static func main() throws {
        var checked = 0, failed = 0
        func check(_ ok: Bool, _ name: String) { checked += 1; if !ok { failed += 1 }; print("\(ok ? "PASS" : "FAIL"): \(name)") }
        let id = UUID(), frame = try EaselFrame(x: 40, y: 80, width: 320, height: 240)
        let capture = try EaselLiveCapture(previewAssetID: id, pixelWidth: 640, pixelHeight: 480, sourceURL: "https://example.test/page?one=1&two=2", sourceTitle: "Owned live source <canary>", viewport: EaselCaptureViewport(width: 1024, height: 768, scrollX: 0, scrollY: 120, pageZoom: 1), crop: EaselCaptureCrop(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        let item = try EaselItem(frame: frame, content: .liveCapture(capture))
        let encoder = JSONEncoder(), decoder = JSONDecoder(); encoder.outputFormatting = [.sortedKeys]
        check(try decoder.decode(EaselItem.self, from: encoder.encode(item)) == item, "The saved card retains its complete validated live capture definition")
        check(item.content.previewAssetID == id, "Live capture participates in common preview reference accounting")
        check(item.content.imagePreview?.pixelWidth == 640 && item.content.imagePreview?.sourceURL == capture.sourceURL, "Fallback renderers receive the saved image dimensions and source from the same live definition")
        let image = EaselItemContent.image(assetID: id, pixelWidth: 640, pixelHeight: 480, sourceURL: nil, sourceTitle: nil)
        check(image.previewAssetID == id && EaselItemContent.note(text: "note").previewAssetID == nil, "Image and nonimage cards keep their original preview reference behavior")
        let board = try Easel(title: "Owned protected live board", items: [item])
        var document = BrowserDocument(); document.library.easels = [board]; try document.repairProfiles()
        check(document.formatVersion == 11 && document.library.easels == [board], "Live definitions declare metadata format11")
        var previous = BrowserDocument(); previous.formatVersion = 10
        let previousBoard = try Easel(title: "Previous board", items: [EaselItem(frame: frame, content: image), EaselItem(frame: frame, content: .note(text: "Original note"))])
        previous.library.easels = [previousBoard]; try previous.repairProfiles()
        check(previous.formatVersion == 11 && previous.library.easels == [previousBoard], "Format10 images and notes migrate with exact identities and content retained")
        var future = document; future.formatVersion = 12; let before = try encoder.encode(future)
        do { try future.repairProfiles(); check(false, "Newer metadata remains write protected") }
        catch MetadataFormatError.unsupportedVersion { check(true, "Newer metadata remains write protected") }
        check(try encoder.encode(future) == before, "A rejected future document remains byte-for-byte unchanged")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256), url = root.appendingPathComponent("normal/session.enc")
        let normal = MetadataStore(url: url, key: key); try normal.save(document)
        check(try normal.load(BrowserDocument.self)?.library.easels == [board], "Actual encrypted metadata cold-restores the live definition and preview reference")
        let sealed = try Data(contentsOf: url)
        check(sealed.range(of: Data(capture.sourceURL.utf8)) == nil && sealed.range(of: Data(capture.sourceTitle.utf8)) == nil, "Saved normal capture attribution is absent from plaintext metadata")
        let privateURL = root.appendingPathComponent("private-never-created/session.enc")
        try MetadataStore(url: privateURL, key: key, isPrivate: true).save(document)
        check(!FileManager.default.fileExists(atPath: privateURL.deletingLastPathComponent().path), "Private live metadata creates no directory or saved file")
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGPQyAv4DwADjgHmDCzF+wAAAABJRU5ErkJggg==")!
        var requested: [UUID] = []
        let html = try EaselHTMLExport(easel: board, pngForAsset: { asset in requested.append(asset); return png })
        let text = String(decoding: html.data, as: UTF8.self)
        check(requested == [id] && text.contains("data:image/png;base64," + png.base64EncodedString()), "Standalone export embeds only the explicitly saved fallback asset")
        check(text.contains("Owned live source &lt;canary&gt;") && text.contains("one=1&amp;two=2"), "Export retains escaped source attribution")
        check(text.contains("script-src 'none'") && text.contains("default-src 'none'") && !text.contains("<iframe") && !text.contains("<script") && !text.contains("<video"), "Offline export contains no active live page or executable media")
        var missingAssetCalls = 0
        do { _ = try EaselHTMLExport(easel: board, pngForAsset: { _ in missingAssetCalls += 1; throw CocoaError(.fileNoSuchFile) }); check(false, "A missing preview is an explicit export failure") }
        catch { check(missingAssetCalls == 1, "A missing preview is an explicit export failure") }
        var copy = board
        let second = try EaselItem(frame: frame, content: .liveCapture(capture))
        try copy.apply(.insert(second), expectedRevision: copy.revision)
        requested = []
        _ = try EaselHTMLExport(easel: copy, pngForAsset: { asset in requested.append(asset); return png })
        check(copy.items.count == 2 && copy.items[0].id != copy.items[1].id && requested == [id], "Distinct capture cards retain their identities while one shared preview is exported once")
        print("Easel live capture document checks: \(checked) checked, \(failed) failed")
        if failed != 0 { exit(1) }
    }
}
