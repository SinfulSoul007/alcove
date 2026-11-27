import Foundation
import CoreGraphics
import CoreText
import ImageIO
import BrowserCore

/// Immutable document plus the asset store's serialized, directory-bound reader.
/// Rendering uses local Core Graphics/Core Text objects, with one decoded image
/// at a time; it does not create a view, a WebKit document or a temporary file.
struct EaselCanvasExport: Sendable {
    let easel: Easel
    let assets: EaselAssetStore
    let background: ThemeColor?
    init(easel: Easel, assets: EaselAssetStore, background: ThemeColor? = nil) {
        self.easel = easel; self.assets = assets
        self.background = background.map { ThemeColor($0.red, $0.green, $0.blue) }
    }
    func html() throws -> Data {
        try EaselHTMLExport(easel: easel, background: background, pngForAsset: { id in
            try autoreleasepool {
                guard let bytes = try assets.read(id) else { throw EaselExportError.invalidImage }
                let raster = try EaselRaster(data: bytes), image = try raster.exportThumbnail(maxPixelSize: 4096)
                return try Self.encodePNG(image)
            }
        }).data
    }
    private static func encodePNG(_ image: CGImage) throws -> Data {
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil) else { throw EaselExportError.invalidImage }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw EaselExportError.invalidImage }
        return bytes as Data
    }
    func png() throws -> Data {
        let layout = EaselExportLayout(easel: easel)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: layout.pixelWidth, height: layout.pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw EaselExportError.tooLarge }
        let paper = background ?? ThemeColor(0.973, 0.977, 0.985)
        context.setFillColor(CGColor(srgbRed: paper.red, green: paper.green, blue: paper.blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: layout.pixelWidth, height: layout.pixelHeight))
        context.translateBy(x: 0, y: CGFloat(layout.pixelHeight)); context.scaleBy(x: layout.scale, y: -layout.scale)
        context.translateBy(x: -layout.originX, y: -layout.originY)
        for item in easel.items {
            try Task.checkCancellation()
            try autoreleasepool {
                let f = item.frame, rect = CGRect(x: f.x, y: f.y, width: f.width, height: f.height)
                if case .drawing(let drawing) = item.content {
                    EaselDrawingRenderer.draw(drawing, in: rect, context: context)
                    return
                }
                let path = CGPath(roundedRect: rect.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 12, cornerHeight: 12, transform: nil)
                context.addPath(path); context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fillPath()
                context.addPath(path); context.setStrokeColor(CGColor(gray: 0.82, alpha: 1)); context.setLineWidth(1); context.strokePath()
                context.saveGState(); defer { context.restoreGState() }
                context.addPath(path); context.clip()
                let textRect = CGRect(x: rect.minX + 14, y: rect.minY + 30, width: max(1, rect.width - 28), height: max(1, rect.height - 42))
                switch item.content {
                case .note(let text): Self.draw(text, in: textRect, size: 14, context: context)
                case .link(let title, let url): Self.draw("↗ " + title + "\n" + url, in: textRect, size: 14, context: context, link: true)
                case .drawing: break // Drawing layers are handled before any card fill or clipping.
                case .image(let id, _, _, let source, let title):
                    guard let bytes = try assets.read(id) else { throw EaselExportError.invalidImage }
                    let raster = try EaselRaster(data: bytes)
                    let box = CGRect(x: rect.minX + 12, y: rect.minY + 30, width: max(1, rect.width - 24), height: max(1, rect.height - (source == nil ? 42 : 60)))
                    let fit = min(box.width / Double(raster.pixelWidth), box.height / Double(raster.pixelHeight))
                    let size = CGSize(width: Double(raster.pixelWidth) * fit, height: Double(raster.pixelHeight) * fit)
                    let target = CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height)
                    let pixels = min(8192, max(1, Int(ceil(max(size.width, size.height) * layout.scale))))
                    let image = try raster.exportThumbnail(maxPixelSize: pixels)
                    guard image.bytesPerRow * image.height <= 96 * 1024 * 1024 else { throw EaselExportError.tooLarge }
                    context.saveGState(); context.translateBy(x: target.minX, y: target.maxY); context.scaleBy(x: 1, y: -1)
                    context.draw(image, in: CGRect(origin: .zero, size: target.size)); context.restoreGState()
                    if let source { Self.draw("↗ " + (title ?? source), in: CGRect(x: rect.minX + 12, y: rect.maxY - 27, width: max(1, rect.width - 36), height: 18), size: 11, context: context, link: true) }
                }
            }
        }
        guard let image = context.makeImage() else { throw EaselExportError.tooLarge }
        return try Self.encodePNG(image)
    }
    private static func draw(_ text: String, in rect: CGRect, size: CGFloat, context: CGContext, link: Bool = false) {
        let font = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let color = link ? CGColor(srgbRed: 0.14, green: 0.36, blue: 0.53, alpha: 1) : CGColor(srgbRed: 0.094, green: 0.13, blue: 0.17, alpha: 1)
        let string = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): color])
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let path = CGPath(rect: CGRect(origin: .zero, size: rect.size), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: string.length), path, nil)
        context.saveGState(); context.translateBy(x: rect.minX, y: rect.maxY); context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity; CTFrameDraw(frame, context); context.restoreGState()
    }
}
