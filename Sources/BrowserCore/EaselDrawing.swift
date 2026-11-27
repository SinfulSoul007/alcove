import Foundation

public struct EaselDrawingPoint: Codable, Equatable, Sendable {
    public let x: Double, y: Double
    public init(x: Double, y: Double) throws {
        guard x.isFinite, y.isFinite, (0...4096).contains(x), (0...4096).contains(y) else { throw EaselError.invalidContent }
        self.x = x; self.y = y
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(x: c.decode(Double.self, forKey: .x), y: c.decode(Double.self, forKey: .y))
    }
}

public struct EaselDrawingStyle: Codable, Equatable, Sendable {
    public let color: String
    public let lineWidth: Double, opacity: Double
    public init(color: String, lineWidth: Double, opacity: Double) throws {
        let bytes = color.utf8
        guard bytes.count == 7, bytes.first == 35,
              bytes.dropFirst().allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              lineWidth.isFinite, (1...32).contains(lineWidth), opacity.isFinite, (0.1...1).contains(opacity) else { throw EaselError.invalidContent }
        self.color = color.uppercased(); self.lineWidth = lineWidth; self.opacity = opacity
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(color: c.decode(String.self, forKey: .color), lineWidth: c.decode(Double.self, forKey: .lineWidth), opacity: c.decode(Double.self, forKey: .opacity))
    }
}

public enum EaselDrawingKind: String, Codable, CaseIterable, Sendable {
    case pen, line, arrow, rectangle, ellipse
}

/// Typed, locally generated geometry. Website/user SVG is never parsed.
public enum EaselDrawingCommand: Equatable, Sendable {
    case move(EaselDrawingPoint), line(EaselDrawingPoint)
    case quadratic(control: EaselDrawingPoint, end: EaselDrawingPoint)
    case cubic(control1: EaselDrawingPoint, control2: EaselDrawingPoint, end: EaselDrawingPoint)
    case close
    fileprivate var points: [EaselDrawingPoint] {
        switch self {
        case .move(let p), .line(let p): return [p]
        case .quadratic(let control, let end): return [control, end]
        case .cubic(let a, let b, let end): return [a, b, end]
        case .close: return []
        }
    }
}

public struct EaselDrawingPath: Equatable, Sendable {
    public let commands: [EaselDrawingCommand]
    public let filled: Bool
}

/// Samples use a fixed logical view box; the canvas item frame supplies the
/// complete scale when moved/resized. Only samples/style are stored on disk.
public struct EaselDrawing: Codable, Equatable, Sendable {
    public let kind: EaselDrawingKind
    public let viewBoxWidth: Double, viewBoxHeight: Double
    public let points: [EaselDrawingPoint]
    public let style: EaselDrawingStyle
    public let path: EaselDrawingPath
    private enum CodingKeys: String, CodingKey { case kind, viewBoxWidth, viewBoxHeight, points, style }

    public init(kind: EaselDrawingKind, viewBoxWidth: Double, viewBoxHeight: Double,
                points: [EaselDrawingPoint], style: EaselDrawingStyle) throws {
        guard viewBoxWidth.isFinite, viewBoxHeight.isFinite,
              (40...4096).contains(viewBoxWidth), (40...4096).contains(viewBoxHeight),
              !points.isEmpty, points.count <= 4096,
              points.allSatisfy({ $0.x <= viewBoxWidth && $0.y <= viewBoxHeight }) else { throw EaselError.invalidContent }
        if kind != .pen {
            guard points.count == 2, points[0] != points[1] else { throw EaselError.invalidContent }
            if kind == .rectangle || kind == .ellipse {
                guard points[0].x != points[1].x, points[0].y != points[1].y else { throw EaselError.invalidContent }
            }
        }
        let path = try Self.makePath(kind: kind, points: points, style: style)
        let margin = path.filled ? 0 : style.lineWidth / 2
        // Beziers stay in their control-point convex hull. Including every
        // control/arrowhead and the stroke radius prevents clipped saved ink.
        guard path.commands.allSatisfy({ command in command.points.allSatisfy({
            $0.x >= margin && $0.y >= margin && $0.x <= viewBoxWidth - margin && $0.y <= viewBoxHeight - margin
        }) }) else { throw EaselError.invalidContent }
        self.kind = kind; self.viewBoxWidth = viewBoxWidth; self.viewBoxHeight = viewBoxHeight
        self.points = points; self.style = style; self.path = path
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(EaselDrawingKind.self, forKey: .kind)
        let width = try c.decode(Double.self, forKey: .viewBoxWidth), height = try c.decode(Double.self, forKey: .viewBoxHeight)
        let style = try c.decode(EaselDrawingStyle.self, forKey: .style)
        var input = try c.nestedUnkeyedContainer(forKey: .points)
        var points: [EaselDrawingPoint] = []
        while !input.isAtEnd {
            guard points.count < 4096 else { throw EaselError.invalidContent }
            points.append(try input.decode(EaselDrawingPoint.self))
        }
        try self.init(kind: kind, viewBoxWidth: width, viewBoxHeight: height, points: points, style: style)
    }

    private static func ellipse(cx: Double, cy: Double, rx: Double, ry: Double) throws -> [EaselDrawingCommand] {
        let k = 0.5522847498307936
        func p(_ x: Double, _ y: Double) throws -> EaselDrawingPoint { try .init(x: x, y: y) }
        return try [.move(p(cx + rx, cy)),
            .cubic(control1: p(cx + rx, cy + k * ry), control2: p(cx + k * rx, cy + ry), end: p(cx, cy + ry)),
            .cubic(control1: p(cx - k * rx, cy + ry), control2: p(cx - rx, cy + k * ry), end: p(cx - rx, cy)),
            .cubic(control1: p(cx - rx, cy - k * ry), control2: p(cx - k * rx, cy - ry), end: p(cx, cy - ry)),
            .cubic(control1: p(cx + k * rx, cy - ry), control2: p(cx + rx, cy - k * ry), end: p(cx + rx, cy)), .close]
    }
    private static func makePath(kind: EaselDrawingKind, points: [EaselDrawingPoint], style: EaselDrawingStyle) throws -> EaselDrawingPath {
        let a = points[0]
        func p(_ x: Double, _ y: Double) throws -> EaselDrawingPoint { try .init(x: x, y: y) }
        if kind == .pen {
            if points.allSatisfy({ $0 == a }) {
                return EaselDrawingPath(commands: try ellipse(cx: a.x, cy: a.y, rx: style.lineWidth / 2, ry: style.lineWidth / 2), filled: true)
            }
            if points.count == 2 { return EaselDrawingPath(commands: [.move(a), .line(points[1])], filled: false) }
            var commands: [EaselDrawingCommand] = [.move(a)]
            for index in 1..<points.count {
                let previous = points[index - 1], current = points[index]
                commands.append(.quadratic(control: previous, end: try p((previous.x + current.x) / 2, (previous.y + current.y) / 2)))
            }
            commands.append(.line(points[points.count - 1]))
            return EaselDrawingPath(commands: commands, filled: false)
        }
        let b = points[1]
        switch kind {
        case .pen: preconditionFailure("Pen path returned above")
        case .line: return EaselDrawingPath(commands: [.move(a), .line(b)], filled: false)
        case .arrow:
            let dx = b.x - a.x, dy = b.y - a.y, length = hypot(dx, dy)
            let head = min(max(12, style.lineWidth * 3), length * 0.4)
            let ux = dx / length, uy = dy / length
            return EaselDrawingPath(commands: try [.move(a), .line(b),
                .move(p(b.x - ux * head - uy * head / 2, b.y - uy * head + ux * head / 2)), .line(b),
                .line(p(b.x - ux * head + uy * head / 2, b.y - uy * head - ux * head / 2))], filled: false)
        case .rectangle:
            let left = min(a.x, b.x), right = max(a.x, b.x), top = min(a.y, b.y), bottom = max(a.y, b.y)
            return EaselDrawingPath(commands: try [.move(p(left, top)), .line(p(right, top)), .line(p(right, bottom)), .line(p(left, bottom)), .close], filled: false)
        case .ellipse:
            return EaselDrawingPath(commands: try ellipse(cx: (a.x + b.x) / 2, cy: (a.y + b.y) / 2, rx: abs(b.x - a.x) / 2, ry: abs(b.y - a.y) / 2), filled: false)
        }
    }
}
