import Foundation
import ImageIO
import Darwin
import zlib

enum EaselImageError: LocalizedError {
    case size, unsupported, damaged, unreadable
    var errorDescription: String? {
        switch self {
        case .size: return "Choose an image up to 32 MiB, 16,384 pixels per side and 40 million pixels total."
        case .unsupported: return "Choose a PNG, JPEG, GIF, TIFF, HEIF, WebP or bitmap image."
        case .damaged: return "This image is incomplete or cannot be decoded."
        case .unreadable: return "The image file changed or could not be opened. Choose it again."
        }
    }
}

/// Encoded bytes stay bounded; ImageIO reads dimensions before any raster decode.
/// Renderers request a thumbnail for their actual display/export size.
struct EaselRaster {
    static let maximumBytes = 33_554_432
    let data: Data
    let pixelWidth: Int, pixelHeight: Int
    private static let formats: Set<String> = ["public.png", "public.jpeg", "com.compuserve.gif", "public.tiff", "public.heic", "public.heif", "org.webmproject.webp", "com.microsoft.bmp"]

    init(data: Data) throws {
        guard !data.isEmpty, data.count <= Self.maximumBytes else { throw EaselImageError.size }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source), Self.formats.contains(type as String) else { throw EaselImageError.unsupported }
        if type as String == "public.png" { try Self.validatePNG(data) }
        guard CGImageSourceGetCount(source) > 0, CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { throw EaselImageError.damaged }
        let w = width.intValue, h = height.intValue
        guard width.doubleValue == Double(w), height.doubleValue == Double(h), w > 0, h > 0,
              w <= 16384, h <= 16384, w <= 40_000_000 / h else { throw EaselImageError.size }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        guard (1...8).contains(orientation) else { throw EaselImageError.damaged }
        self.data = data
        pixelWidth = (5...8).contains(orientation) ? h : w
        pixelHeight = (5...8).contains(orientation) ? w : h
        // Metadata alone is insufficient: verify the first frame decodes at a tiny,
        // bounded size without retaining a full-resolution backing image.
        _ = try thumbnail(maxPixelSize: 16)
        guard CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { throw EaselImageError.damaged }
    }

    // ImageIO can return statusComplete and a partial preview for a truncated PNG.
    // Walk bounded chunks and their CRCs so a partial IDAT cannot be persisted.
    private static func validatePNG(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            func word(_ offset: Int) -> UInt32 {
                (0..<4).reduce(UInt32(0)) { ($0 << 8) | UInt32(bytes[offset + $1]) }
            }
            guard bytes.count >= 33, Array(bytes.prefix(8)) == [137,80,78,71,13,10,26,10] else { throw EaselImageError.damaged }
            var offset = 8, sawData = false
            while offset <= bytes.count - 12 {
                let length = Int(word(offset))
                guard length <= bytes.count - offset - 12 else { throw EaselImageError.damaged }
                let kind = word(offset + 4), checksum = word(offset + 8 + length)
                let actual = crc32(0, bytes.baseAddress!.advanced(by: offset + 4), uInt(length + 4))
                guard UInt32(actual) == checksum else { throw EaselImageError.damaged }
                if offset == 8, kind != 0x49484452 || length != 13 { throw EaselImageError.damaged }
                if kind == 0x49444154 { sawData = true }
                offset += length + 12
                if kind == 0x49454E44 {
                    guard length == 0, sawData, offset == bytes.count else { throw EaselImageError.damaged }
                    return
                }
            }
            throw EaselImageError.damaged
        }
    }

    init(contentsOf url: URL) throws {
        guard url.isFileURL else { throw EaselImageError.unreadable }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw EaselImageError.unreadable }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw EaselImageError.unreadable }
        guard info.st_size > 0, info.st_size <= Self.maximumBytes else { throw EaselImageError.size }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        bytes.reserveCapacity(Int(info.st_size))
        while true {
            let count = read(fd, &buffer, min(buffer.count, Self.maximumBytes + 1 - bytes.count))
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw EaselImageError.unreadable }
            if count == 0 { break }
            bytes.append(contentsOf: buffer.prefix(count))
            guard bytes.count <= Self.maximumBytes else { throw EaselImageError.size }
        }
        try self.init(data: bytes)
    }

    func thumbnail(maxPixelSize: Int) throws -> CGImage {
        guard (1...8192).contains(maxPixelSize) else { throw EaselImageError.size }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
              ] as CFDictionary), image.width <= maxPixelSize, image.height <= maxPixelSize else { throw EaselImageError.damaged }
        return image
    }
}
