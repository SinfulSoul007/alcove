import AppKit
import ImageIO
import UniformTypeIdentifiers

// Mutations caught: accepting headers/oversized rasters without decoding checks,
// decoding full-resolution previews, ignoring EXIF orientation, or unbounded file reads.
@main struct EaselImageChecks {
    static func main() throws {
        setbuf(stdout, nil)
        var checks = 0, failures = 0
        func check(_ condition: Bool, _ name: String) {
            checks += 1; print("\(condition ? "PASS" : "FAIL"): \(name)"); if !condition { failures += 1 }
        }
        func rejects(_ name: String, _ body: () throws -> Void) {
            do { try body(); check(false, name) } catch { check(true, name) }
        }
        func raster(_ width: Int, _ height: Int, type: CFString = UTType.png.identifier as CFString, orientation: Int = 1) throws -> Data {
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let bytes = NSMutableData(), destination = CGImageDestinationCreateWithData(bytes, type, 1, nil)!
            CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImagePropertyOrientation: orientation] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }; return bytes as Data
        }
        let data = try raster(600, 300)
        let image = try EaselRaster(data: data)
        check(image.pixelWidth == 600 && image.pixelHeight == 300, "Import derives actual raster dimensions from encoded data")
        let preview = try image.thumbnail(maxPixelSize: 120)
        check(preview.width == 120 && preview.height == 60, "Image preview decodes only the requested bounded thumbnail")
        let portrait = try EaselRaster(data: raster(40, 20, type: UTType.jpeg.identifier as CFString, orientation: 6))
        let oriented = try portrait.thumbnail(maxPixelSize: 40)
        check(portrait.pixelWidth == 20 && portrait.pixelHeight == 40 && oriented.width == 20 && oriented.height == 40, "EXIF rotation is reflected in both model dimensions and preview")
        rejects("Empty images are rejected") { _ = try EaselRaster(data: Data()) }
        rejects("Non-raster HTML is rejected") { _ = try EaselRaster(data: Data("<html><script>alert(1)</script></html>".utf8)) }
        rejects("SVG stays unsupported instead of gaining active content") { _ = try EaselRaster(data: Data("<svg xmlns='http://www.w3.org/2000/svg' width='1' height='1'/>".utf8)) }
        rejects("A truncated raster cannot become a saved image") { _ = try EaselRaster(data: data.prefix(data.count / 2)) }
        rejects("Appending an end marker cannot hide a truncated PNG chunk") { _ = try EaselRaster(data: data.prefix(data.count / 2) + data.suffix(12)) }
        var damaged = data; damaged[damaged.count / 2] ^= 1
        rejects("A damaged PNG chunk checksum is rejected") { _ = try EaselRaster(data: damaged) }
        rejects("Encoded images over 32 MiB are rejected before ImageIO") { _ = try EaselRaster(data: Data(repeating: 0, count: 33_554_433)) }
        rejects("A zero thumbnail bound cannot request a full raster") { _ = try image.thumbnail(maxPixelSize: 0) }
        rejects("An excessive thumbnail bound is rejected") { _ = try image.thumbnail(maxPixelSize: 8193) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Alcove.ImageImport." + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("untrusted-name.svg"); try data.write(to: file)
        let fromFile = try EaselRaster(contentsOf: file)
        check(fromFile.pixelWidth == 600 && fromFile.data == data, "File extension and filename do not select the image parser")
        let link = root.appendingPathComponent("linked.png"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        rejects("Image import refuses a replaced symbolic-link file") { _ = try EaselRaster(contentsOf: link) }
        let large = root.appendingPathComponent("large.png"); _ = FileManager.default.createFile(atPath: large.path, contents: nil)
        let handle = try FileHandle(forWritingTo: large); try handle.truncate(atOffset: 33_554_433); try handle.close()
        rejects("File import bounds bytes before reading a large file") { _ = try EaselRaster(contentsOf: large) }
        rejects("A directory cannot be imported as a raster") { _ = try EaselRaster(contentsOf: root) }
        // A valid TIFF header with impossible dimensions exercises the metadata gate
        // without allocating the declared huge image.
        var tiff = Data([0x49,0x49,42,0,8,0,0,0,2,0])
        func entry(_ tag: UInt16, _ value: UInt32) { tiff += withUnsafeBytes(of: tag.littleEndian) { Data($0) }; tiff += Data([4,0,1,0,0,0]); tiff += withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        entry(256, 20000); entry(257, 20000); tiff += Data(repeating: 0, count: 4)
        rejects("Oversized image dimensions are rejected without allocating the declared raster") { _ = try EaselRaster(data: tiff) }
        print("Easel image checks: \(checks) checked, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
