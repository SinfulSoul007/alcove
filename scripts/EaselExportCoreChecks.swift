import Foundation
import BrowserCore
import ImageIO

// Catches canvas-sized bitmap allocation/cropping, omitted remote cards,
// executable exported text/URLs, and silently missing image references.
@main struct EaselExportCoreChecks {
    static func main() throws {
        var checks = 0, failures = 0
        func check(_ value: Bool, _ name: String) { checks += 1; print("\(value ? "PASS" : "FAIL"): \(name)"); if !value { failures += 1 } }
        func rejects(_ name: String, _ body: () throws -> Void) { do { try body(); check(false, name) } catch { check(true, name) } }
        let empty = try Easel(title: "Empty")
        let emptyLayout = EaselExportLayout(easel: empty)
        check(emptyLayout.pixelWidth == 1920 && emptyLayout.pixelHeight == 1280, "An empty export uses a useful 960 by 640 point page at 2x")
        let note = try EaselItem(frame: EaselFrame(x: 100, y: 200, width: 300, height: 100), content: .note(text: "<script>alert('x')</script>\n& 🌲 مرحبا"))
        var board = try Easel(title: "<Canvas & \"ideas\">")
        try board.apply(.insert(note), expectedRevision: board.revision)
        let layout = EaselExportLayout(easel: board)
        check(layout.originX == 52 && layout.originY == 152 && layout.width == 396 && layout.height == 196 && layout.pixelWidth == 792 && layout.pixelHeight == 392, "Export bounds include every card plus exactly 48 points of margin")
        var far = try Easel(title: "Distant corners")
        let a = try EaselItem(frame: EaselFrame(x: 0, y: 0, width: 40, height: 40), content: .note(text: "First"))
        let b = try EaselItem(frame: EaselFrame(x: 16344, y: 16344, width: 40, height: 40), content: .note(text: "Last"))
        for item in [a,b] { try far.apply(.insert(item), expectedRevision: far.revision) }
        let bounded = EaselExportLayout(easel: far)
        check(bounded.pixelWidth == 4000 && bounded.pixelHeight == 4000 && bounded.originX == -48 && bounded.originY == -48 && bounded.width == 16480, "Distant content fits one complete export within the 16 million pixel bound")
        let link = try EaselItem(frame: EaselFrame(x: 20, y: 30, width: 100, height: 80), content: .link(title: "Click <me> & \"them\"", url: "https://example.com/?a=1&b=2"))
        try board.apply(.insert(link), expectedRevision: board.revision)
        let html = try EaselHTMLExport(easel: board, pngForAsset: { _ in throw CocoaError(.fileNoSuchFile) })
        let text = String(decoding: html.data, as: UTF8.self)
        check(text.contains("&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt;") && !text.contains("<script>"), "Exported note markup remains escaped inert text")
        check(text.contains("🌲 مرحبا") && text.contains("&lt;Canvas &amp; &quot;ideas&quot;&gt;"), "Offline export preserves Unicode while escaping its title")
        check(text.contains("href=\"https://example.com/?a=1&amp;b=2\"") && text.contains("rel=\"noopener noreferrer\""), "Explicit source links retain their URL without breaking HTML attributes")
        check(text.contains("default-src 'none'") && text.contains("img-src data:") && text.contains("script-src 'none'"), "Offline HTML blocks scripts, connections and external image requests")
        check(!text.contains("<iframe") && !text.contains("<object") && !text.contains("<form"), "Canvas export creates no active embedded page or form")
        let imageID = UUID(), png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgYPgPAAEDAQAIicLsAAAAAElFTkSuQmCC")!
        let image = try EaselItem(frame: EaselFrame(x: 10, y: 10, width: 120, height: 80), content: .image(assetID: imageID, pixelWidth: 1, pixelHeight: 1, sourceURL: "https://example.com/source", sourceTitle: "Source <&>"))
        try board.apply(.insert(image), expectedRevision: board.revision)
        rejects("A missing image aborts export instead of silently losing its card") { _ = try EaselHTMLExport(easel: board, pngForAsset: { _ in throw CocoaError(.fileNoSuchFile) }) }
        rejects("Non-PNG provider bytes cannot masquerade as a portable image") { _ = try EaselHTMLExport(easel: board, pngForAsset: { _ in Data("<svg onload='alert(1)'/>".utf8) }) }
        let withImage = try EaselHTMLExport(easel: board, pngForAsset: { id in guard id == imageID else { throw CocoaError(.fileNoSuchFile) }; return png })
        let embedded = String(decoding: withImage.data, as: UTF8.self)
        check(embedded.contains("data:image/png;base64,iVBORw0KGgoAAAANS") && embedded.contains("Source &lt;&amp;&gt;"), "Portable images are embedded locally with escaped attribution")
        check(!embedded.contains("src=\"https://") && !embedded.contains("src=\"http://"), "Opening offline HTML never fetches an original image URL")
        var noise = [UInt8](repeating: 255, count: 272 * 272 * 4), seed: UInt32 = 73
        for index in stride(from: 0, to: noise.count, by: 4) {
            for channel in 0..<3 { seed = seed &* 1664525 &+ 1013904223; noise[index + channel] = UInt8(truncatingIfNeeded: seed >> 24) }
        }
        let noisyPNG: Data = noise.withUnsafeMutableBytes { pixels in
            let context = CGContext(data: pixels.baseAddress, width: 272, height: 272, bitsPerComponent: 8, bytesPerRow: 1088, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            let bytes = NSMutableData(), destination = CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, context.makeImage()!, nil); precondition(CGImageDestinationFinalize(destination)); return bytes as Data
        }
        var largeBoard = try Easel(title: "Large portable canvas")
        for _ in 0..<500 {
            let item = try EaselItem(frame: EaselFrame(x: 0, y: 0, width: 120, height: 80), content: .image(assetID: imageID, pixelWidth: 272, pixelHeight: 272, sourceURL: nil, sourceTitle: nil))
            try largeBoard.apply(.insert(item), expectedRevision: largeBoard.revision)
        }
        rejects("Oversized portable HTML fails explicitly instead of building an unbounded in-memory file") { _ = try EaselHTMLExport(easel: largeBoard, pngForAsset: { _ in noisyPNG }) }
        print("Easel export core checks: \(checks) checked, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
