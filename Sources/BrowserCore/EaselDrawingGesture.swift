import Foundation

/// Board-space input, distinct from the smaller local drawing coordinate system.
public struct EaselCanvasSample: Equatable, Sendable {
    public let x: Double, y: Double
    public init(x: Double, y: Double) throws {
        guard x.isFinite, y.isFinite, (0...EaselFrame.canvasSize).contains(x),
              (0...EaselFrame.canvasSize).contains(y) else { throw EaselError.invalidContent }
        self.x = x; self.y = y
    }
}

/// A bounded transient gesture. It never writes a document or silently scales ink.
public struct EaselDrawingGesture: Sendable {
    public let id: UUID
    public let kind: EaselDrawingKind
    public let style: EaselDrawingStyle
    public private(set) var samples: [EaselCanvasSample]
    public private(set) var didCompactSamples = false
    private var minX: Double, minY: Double, maxX: Double, maxY: Double
    private var margin: Double {
        style.lineWidth / 2 + (kind == .arrow ? max(12, 3 * style.lineWidth) / 2 : 0)
    }
    public init(kind: EaselDrawingKind, style: EaselDrawingStyle, start: EaselCanvasSample, id: UUID = UUID()) throws {
        self.id = id; self.kind = kind; self.style = style
        samples = []; minX = start.x; minY = start.y; maxX = start.x; maxY = start.y
        let point = try clamped(start)
        samples = [point]; minX = point.x; minY = point.y; maxX = point.x; maxY = point.y
    }
    private func clamped(_ sample: EaselCanvasSample) throws -> EaselCanvasSample {
        try .init(x: min(EaselFrame.canvasSize - margin, max(margin, sample.x)),
                  y: min(EaselFrame.canvasSize - margin, max(margin, sample.y)))
    }
    public mutating func append(_ sample: EaselCanvasSample) throws {
        let point = try clamped(sample)
        guard point != samples.last else { return }
        if kind == .pen {
            if samples.count == 4096 {
                // Retain the initial sample and every other interior sample;
                // the newest endpoint is appended below, never dropped.
                samples = stride(from: 0, to: samples.count, by: 2).map { samples[$0] }
                didCompactSamples = true
            }
            samples.append(point)
            // Keep the historical extent even if an extreme was compacted out.
            minX = min(minX, point.x); minY = min(minY, point.y)
            maxX = max(maxX, point.x); maxY = max(maxY, point.y)
        } else {
            if samples.count == 1 { samples.append(point) } else { samples[1] = point }
            minX = min(samples[0].x, point.x); minY = min(samples[0].y, point.y)
            maxX = max(samples[0].x, point.x); maxY = max(samples[0].y, point.y)
        }
    }
    public func makeItem() throws -> EaselItem {
        let inkWidth = maxX - minX + 2 * margin, inkHeight = maxY - minY + 2 * margin
        let width = max(40, inkWidth), height = max(40, inkHeight)
        guard width <= 4096, height <= 4096 else { throw EaselError.invalidFrame }
        let x = min(EaselFrame.canvasSize - width, max(0, minX - margin - (width - inkWidth) / 2))
        let y = min(EaselFrame.canvasSize - height, max(0, minY - margin - (height - inkHeight) / 2))
        let points = try samples.map { try EaselDrawingPoint(x: $0.x - x, y: $0.y - y) }
        let drawing = try EaselDrawing(kind: kind, viewBoxWidth: width, viewBoxHeight: height, points: points, style: style)
        return try EaselItem(id: id, frame: EaselFrame(x: x, y: y, width: width, height: height), content: .drawing(drawing))
    }
}
