import AppKit
let directory = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    let scale = CGFloat(size) / 1024
    context.cgContext.scaleBy(x: scale, y: scale)
    NSColor(calibratedRed: 0.72, green: 0.86, blue: 0.80, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 30, y: 30, width: 964, height: 964), xRadius: 210, yRadius: 210).fill()
    NSColor(calibratedRed: 0.13, green: 0.28, blue: 0.26, alpha: 1).setFill()
    let arch = NSBezierPath()
    arch.move(to: NSPoint(x: 265, y: 220)); arch.line(to: NSPoint(x: 265, y: 535))
    arch.curve(to: NSPoint(x: 759, y: 535), controlPoint1: NSPoint(x: 265, y: 855), controlPoint2: NSPoint(x: 759, y: 855))
    arch.line(to: NSPoint(x: 759, y: 220)); arch.close(); arch.fill()
    NSColor(calibratedRed: 0.93, green: 0.96, blue: 0.87, alpha: 1).setFill()
    let inside = NSBezierPath()
    inside.move(to: NSPoint(x: 390, y: 220)); inside.line(to: NSPoint(x: 390, y: 520))
    inside.curve(to: NSPoint(x: 634, y: 520), controlPoint1: NSPoint(x: 390, y: 690), controlPoint2: NSPoint(x: 634, y: 690))
    inside.line(to: NSPoint(x: 634, y: 220)); inside.close(); inside.fill()
    NSGraphicsContext.restoreGraphicsState()
    let data = rep.representation(using: .png, properties: [:])!
    let names: [String]
    switch size {
    case 16: names = ["icon_16x16.png"]
    case 32: names = ["icon_16x16@2x.png", "icon_32x32.png"]
    case 64: names = ["icon_32x32@2x.png"]
    case 128: names = ["icon_128x128.png"]
    case 256: names = ["icon_128x128@2x.png", "icon_256x256.png"]
    case 512: names = ["icon_256x256@2x.png", "icon_512x512.png"]
    default: names = ["icon_512x512@2x.png"]
    }
    for name in names { try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name)) }
}
// Write the standard ICNS chunk container directly. This avoids iconutil's
// ImageIO conversion dependency on development machines with partial tool updates.
func word(_ value: Int) -> Data { var number = UInt32(value).bigEndian; return withUnsafeBytes(of: &number) { Data($0) } }
let representations = [
    ("icp4", "icon_16x16.png"), ("icp5", "icon_32x32.png"),
    ("ic11", "icon_16x16@2x.png"), ("ic12", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"), ("ic13", "icon_128x128@2x.png"),
    ("ic08", "icon_256x256.png"), ("ic14", "icon_256x256@2x.png"),
    ("ic09", "icon_512x512.png"), ("ic10", "icon_512x512@2x.png")]
var chunks = Data()
for (type, filename) in representations {
    let png = try Data(contentsOf: URL(fileURLWithPath: directory).appendingPathComponent(filename))
    chunks.append(Data(type.utf8)); chunks.append(word(png.count + 8)); chunks.append(png)
}
var icon = Data("icns".utf8); icon.append(word(chunks.count + 8)); icon.append(chunks)
let output = URL(fileURLWithPath: directory).deletingLastPathComponent().appendingPathComponent("Alcove.icns")
try icon.write(to: output)
guard let decoded = NSImage(contentsOf: output), !decoded.representations.isEmpty else { fatalError("Generated ICNS cannot be decoded by AppKit") }
print("Generated and decoded Alcove app icon")
