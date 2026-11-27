import AppKit
import BrowserCore
import ImageIO

@main struct EaselExportRenderChecks {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited); setbuf(stdout, nil)
        var checks = 0, failures = 0
        func check(_ value: Bool, _ name: String) { checks += 1; print("\(value ? "PASS" : "FAIL"): \(name)"); if !value { failures += 1 } }
        func rejects(_ name: String, _ body: () throws -> Void) { do { try body(); check(false, name) } catch { check(true, name) } }
        let assets = EaselAssetStore(privateProfileID: UUID())
        let empty = try EaselCanvasExport(easel: Easel(title: "Empty"), assets: assets).png()
        let emptyBitmap = NSBitmapImageRep(data: empty)!
        check(emptyBitmap.pixelsWide == 1920 && emptyBitmap.pixelsHigh == 1280, "PNG export renders the bounded empty canvas at the advertised size")
        let context = CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 160, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 20, width: 40, height: 20))
        let bytes = NSMutableData(), encoder = CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(encoder, context.makeImage()!, nil); precondition(CGImageDestinationFinalize(encoder))
        let asset = try assets.put(bytes as Data)
        var board = try Easel(title: "A portable image")
        let item = try EaselItem(frame: EaselFrame(x: 100, y: 100, width: 160, height: 160), content: .image(assetID: asset, pixelWidth: 40, pixelHeight: 40, sourceURL: nil, sourceTitle: nil))
        try board.apply(.insert(item), expectedRevision: board.revision)
        let render = EaselCanvasExport(easel: board, assets: assets)
        let image = NSBitmapImageRep(data: try render.png())!, original = NSBitmapImageRep(data: bytes as Data)!
        check(image.pixelsWide == 512 && image.pixelsHigh == 512, "PNG export uses card bounds and margins instead of allocating the full 16384 canvas")
        func same(_ lhs: NSColor?, _ rhs: NSColor?) -> Bool {
            guard let a = lhs?.usingColorSpace(.deviceRGB), let b = rhs?.usingColorSpace(.deviceRGB) else { return false }
            return abs(a.redComponent - b.redComponent) < 0.1 && abs(a.greenComponent - b.greenComponent) < 0.1 && abs(a.blueComponent - b.blueComponent) < 0.1
        }
        check(same(image.colorAt(x: 256, y: 186), original.colorAt(x: 20, y: 5)) && same(image.colorAt(x: 256, y: 362), original.colorAt(x: 20, y: 35)), "PNG preserves the saved image's top and bottom orientation")
        let html = String(decoding: try render.html(), as: UTF8.self)
        let regex = try NSRegularExpression(pattern: "data:image/png;base64,([A-Za-z0-9+/=]+)")
        let range = NSRange(html.startIndex..., in: html), match = regex.firstMatch(in: html, range: range)!
        let encoded = String(html[Range(match.range(at: 1), in: html)!]), embedded = NSBitmapImageRep(data: Data(base64Encoded: encoded)!)!
        check(embedded.pixelsWide == 40 && embedded.pixelsHigh == 40, "HTML renderer embeds a real portable PNG rather than a reference to encrypted storage")
        var noteBoard = try Easel(title: "Unicode notes")
        try noteBoard.apply(.insert(EaselItem(frame: EaselFrame(x: 20, y: 30, width: 300, height: 160), content: .note(text: "Hello 🌲 مرحبا\nA note with & < >"))), expectedRevision: noteBoard.revision)
        let note = NSBitmapImageRep(data: try EaselCanvasExport(easel: noteBoard, assets: assets).png())!
        var ink = 0
        for y in stride(from: 150, to: 300, by: 3) { for x in stride(from: 115, to: 500, by: 3) {
            if let c = note.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.redComponent < 0.5, c.greenComponent < 0.5, c.blueComponent < 0.5 { ink += 1 }
        } }
        check(ink > 20, "PNG includes actual native Unicode note text instead of blank cards")
        try assets.remove(asset)
        rejects("Missing image data aborts PNG export") { _ = try render.png() }
        rejects("Missing image data aborts portable HTML export") { _ = try render.html() }
        let corrupt = try assets.put(Data("Not an image".utf8))
        var broken = try Easel(title: "Broken image")
        try broken.apply(.insert(EaselItem(frame: item.frame, content: .image(assetID: corrupt, pixelWidth: 40, pixelHeight: 40, sourceURL: nil, sourceTitle: nil))), expectedRevision: broken.revision)
        rejects("Damaged image bytes cannot become a misleading PNG export") { _ = try EaselCanvasExport(easel: broken, assets: assets).png() }
        rejects("Damaged image bytes cannot become an active HTML payload") { _ = try EaselCanvasExport(easel: broken, assets: assets).html() }
        check(board.items == [item] && assets.profileID != BrowserProfile.defaultID, "Render failures preserve the original canvas and isolated private asset scope")
        let highDepthURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("Easel16Bit.png")
        let highDepthID = try assets.put(Data(contentsOf: highDepthURL))
        var highDepth = try Easel(title: "16-bit photo")
        try highDepth.apply(.insert(EaselItem(frame: item.frame, content: .image(assetID: highDepthID, pixelWidth: 4096, pixelHeight: 4096, sourceURL: nil, sourceTitle: nil))), expectedRevision: highDepth.revision)
        let highHTML = String(decoding: try EaselCanvasExport(easel: highDepth, assets: assets).html(), as: UTF8.self)
        let highMatch = regex.firstMatch(in: highHTML, range: NSRange(highHTML.startIndex..., in: highHTML))!
        let highBytes = Data(base64Encoded: String(highHTML[Range(highMatch.range(at: 1), in: highHTML)!]))!
        let highBitmap = NSBitmapImageRep(data: highBytes)!
        print("HDR_EXPORT_DECODED_BYTES", highBitmap.bytesPerRow * highBitmap.pixelsHigh, "BITS", highBitmap.bitsPerSample)
        check(highBitmap.bytesPerRow * highBitmap.pixelsHigh <= 96 * 1024 * 1024, "High-depth portable images remain within the decoded image budget")
        print("Easel export render checks: \(checks) checked, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
