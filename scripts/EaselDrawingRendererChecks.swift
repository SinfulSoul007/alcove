import Foundation
import CoreGraphics
import BrowserCore

/// Run in the dedicated VM/hosted macOS. Uses actual Core Graphics pixels.
@main struct EaselDrawingRendererChecks {
    static func main() throws {
        var checked = 0, failed = 0
        func check(_ value: Bool, _ name: String) { checked += 1; if !value { failed += 1 }; print("\(value ? "PASS" : "FAIL"): \(name)") }
        func bitmap() -> CGContext {
            let c = CGContext(data: nil, width: 240, height: 100, bitsPerComponent: 8, bytesPerRow: 960,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.clear(CGRect(x: 0, y: 0, width: 240, height: 100)); return c
        }
        func pixel(_ context: CGContext, _ x: Int, _ y: Int) -> [UInt8] {
            let p = context.data!.assumingMemoryBound(to: UInt8.self).advanced(by: context.bytesPerRow * y + x * 4)
            return Array(UnsafeBufferPointer(start: p, count: 4))
        }
        let red = try EaselDrawingStyle(color: "#FF0000", lineWidth: 4, opacity: 0.5)
        let line = try EaselDrawing(kind: .line, viewBoxWidth: 100, viewBoxHeight: 80,
                                   points: [EaselDrawingPoint(x: 10, y: 40), EaselDrawingPoint(x: 90, y: 40)], style: red)
        let rect = CGRect(x: 10, y: 10, width: 200, height: 80), context = bitmap()
        EaselDrawingRenderer.draw(line, in: rect, context: context)
        let ink = pixel(context, 110, 50)
        check((126...129).contains(ink[0]) && ink[1] == 0 && ink[2] == 0 && (126...129).contains(ink[3]),
              "Native line rendering paints the actual premultiplied ink color and opacity")
        check(pixel(context, 110, 20) == [0, 0, 0, 0] && pixel(context, 15, 15) == [0, 0, 0, 0],
              "A drawing leaves its transparent background and empty frame corners untouched")
        check(EaselDrawingRenderer.contains(line, point: CGPoint(x: 110, y: 50), in: rect, tolerance: 0), "Path hit testing follows the resized visible shaft")
        check(!EaselDrawingRenderer.contains(line, point: CGPoint(x: 110, y: 20), in: rect, tolerance: 0), "Empty drawing bounds let selection reach a lower layer")
        check(EaselDrawingRenderer.contains(line, point: CGPoint(x: 110, y: 55), in: rect, tolerance: 4), "Selection tolerance makes thin marks usable without filling their entire bounds")
        let compressed = bitmap(), compressedRect = CGRect(x: 10, y: 10, width: 200, height: 40)
        EaselDrawingRenderer.draw(line, in: compressedRect, context: compressed)
        check(pixel(compressed, 110, 30)[3] >= 126 && pixel(compressed, 110, 33)[3] == 0,
              "Resizing scales line thickness along with the logical drawing")
        let dot = try EaselDrawing(kind: .pen, viewBoxWidth: 100, viewBoxHeight: 100,
                                  points: [EaselDrawingPoint(x: 50, y: 50)], style: red)
        let dotContext = bitmap()
        EaselDrawingRenderer.draw(dot, in: CGRect(x: 0, y: 0, width: 100, height: 100), context: dotContext)
        check(pixel(dotContext, 50, 50)[3] >= 126 && pixel(dotContext, 50, 55)[3] == 0, "A single pen sample paints a real visible dot")
        let ellipse = try EaselDrawing(kind: .ellipse, viewBoxWidth: 100, viewBoxHeight: 100,
                                      points: [EaselDrawingPoint(x: 90, y: 80), EaselDrawingPoint(x: 10, y: 20)], style: red)
        let ellipseRect = CGRect(x: 0, y: 0, width: 100, height: 100)
        check(!EaselDrawingRenderer.contains(ellipse, point: CGPoint(x: 50, y: 50), in: ellipseRect, tolerance: 0)
                && EaselDrawingRenderer.contains(ellipse, point: CGPoint(x: 50, y: 20), in: ellipseRect, tolerance: 0),
              "Reversed ellipse drags preserve a selectable outline and click-through center")
        print("Easel drawing renderer checks: \(checked) checked, \(failed) failed")
        if failed != 0 { exit(1) }
    }
}
