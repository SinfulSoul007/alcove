import Foundation

/// Native web-view bounds and page zoom, with scroll in CSS document points.
public struct EaselCaptureViewport: Codable, Equatable, Sendable {
    public let width: Double, height: Double, scrollX: Double, scrollY: Double, pageZoom: Double
    public init(width: Double, height: Double, scrollX: Double, scrollY: Double, pageZoom: Double) throws {
        guard [width, height, scrollX, scrollY, pageZoom].allSatisfy(\.isFinite),
              (1...8192).contains(width), (1...8192).contains(height),
              (0...16_777_216).contains(scrollX), (0...16_777_216).contains(scrollY),
              (0.5...3).contains(pageZoom) else { throw EaselError.invalidContent }
        self.width = width; self.height = height; self.scrollX = scrollX; self.scrollY = scrollY; self.pageZoom = pageZoom
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(width: c.decode(Double.self, forKey: .width), height: c.decode(Double.self, forKey: .height),
                      scrollX: c.decode(Double.self, forKey: .scrollX), scrollY: c.decode(Double.self, forKey: .scrollY),
                      pageZoom: c.decode(Double.self, forKey: .pageZoom))
    }
}

/// A strict normalized region. Producers clamp edge rounding before construction.
public struct EaselCaptureCrop: Codable, Equatable, Sendable {
    public let x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) throws {
        guard [x, y, width, height].allSatisfy(\.isFinite),
              (0...1).contains(x), (0...1).contains(y), width > 0, height > 0,
              width <= 1 - x, height <= 1 - y else { throw EaselError.invalidContent }
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(x: c.decode(Double.self, forKey: .x), y: c.decode(Double.self, forKey: .y),
                      width: c.decode(Double.self, forKey: .width), height: c.decode(Double.self, forKey: .height))
    }
}

/// Only the protected definition and offline preview identity are persistent.
public struct EaselLiveCapture: Codable, Equatable, Sendable {
    public let previewAssetID: UUID
    public let pixelWidth: Int, pixelHeight: Int
    public let sourceURL: String, sourceTitle: String
    public let viewport: EaselCaptureViewport
    public let crop: EaselCaptureCrop
    public init(previewAssetID: UUID, pixelWidth: Int, pixelHeight: Int, sourceURL: String, sourceTitle: String,
                viewport: EaselCaptureViewport, crop: EaselCaptureCrop) throws {
        try EaselItemContent.image(assetID: previewAssetID, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                                   sourceURL: sourceURL, sourceTitle: sourceTitle).validate()
        guard crop.width * viewport.width >= 1, crop.height * viewport.height >= 1 else { throw EaselError.invalidContent }
        self.previewAssetID = previewAssetID; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
        self.sourceURL = sourceURL; self.sourceTitle = sourceTitle; self.viewport = viewport; self.crop = crop
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(previewAssetID: c.decode(UUID.self, forKey: .previewAssetID),
                      pixelWidth: c.decode(Int.self, forKey: .pixelWidth), pixelHeight: c.decode(Int.self, forKey: .pixelHeight),
                      sourceURL: c.decode(String.self, forKey: .sourceURL), sourceTitle: c.decode(String.self, forKey: .sourceTitle),
                      viewport: c.decode(EaselCaptureViewport.self, forKey: .viewport), crop: c.decode(EaselCaptureCrop.self, forKey: .crop))
    }
}
