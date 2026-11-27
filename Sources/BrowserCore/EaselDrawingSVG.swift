import Foundation

/// Only validated numeric path commands and an ASCII RGB color reach markup.
public enum EaselDrawingSVG {
    public static func markup(for drawing: EaselDrawing) -> String {
        func p(_ value: EaselDrawingPoint) -> String { "\(value.x) \(value.y)" }
        let data = drawing.path.commands.map { command -> String in
            switch command {
            case .move(let point): return "M " + p(point)
            case .line(let point): return "L " + p(point)
            case .quadratic(let control, let end): return "Q " + p(control) + " " + p(end)
            case .cubic(let a, let b, let end): return "C " + p(a) + " " + p(b) + " " + p(end)
            case .close: return "Z"
            }
        }.joined(separator: " ")
        let color = drawing.style.color
        let fill = drawing.path.filled ? color : "none", stroke = drawing.path.filled ? "none" : color
        return "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(drawing.viewBoxWidth) \(drawing.viewBoxHeight)\" preserveAspectRatio=\"none\" width=\"100%\" height=\"100%\" role=\"img\" aria-label=\"\(drawing.kind.rawValue.capitalized) drawing\"><path d=\"\(data)\" fill=\"\(fill)\" stroke=\"\(stroke)\" stroke-width=\"\(drawing.style.lineWidth)\" opacity=\"\(drawing.style.opacity)\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/></svg>"
    }
}
