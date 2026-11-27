import Foundation
import CoreGraphics
import BrowserCore

enum EaselDrawingRenderer {
    private static func path(_ drawing: EaselDrawing) -> CGPath {
        let result = CGMutablePath()
        func p(_ point: EaselDrawingPoint) -> CGPoint { CGPoint(x: point.x, y: point.y) }
        for command in drawing.path.commands {
            switch command {
            case .move(let point): result.move(to: p(point))
            case .line(let point): result.addLine(to: p(point))
            case .quadratic(let control, let end): result.addQuadCurve(to: p(end), control: p(control))
            case .cubic(let a, let b, let end): result.addCurve(to: p(end), control1: p(a), control2: p(b))
            case .close: result.closeSubpath()
            }
        }
        return result
    }
    static func draw(_ drawing: EaselDrawing, in rect: CGRect, context: CGContext) {
        guard rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0 else { return }
        // Color is immutable and has already passed the exact ASCII RGB validator.
        let rgb = UInt32(drawing.style.color.dropFirst(), radix: 16)!
        let color = CGColor(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255,
                            blue: Double(rgb & 255) / 255, alpha: drawing.style.opacity)
        context.saveGState(); defer { context.restoreGState() }
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: rect.width / drawing.viewBoxWidth, y: rect.height / drawing.viewBoxHeight)
        context.addPath(path(drawing)); context.setLineWidth(drawing.style.lineWidth)
        context.setLineCap(.round); context.setLineJoin(.round)
        context.setFillColor(color); context.setStrokeColor(color)
        context.drawPath(using: drawing.path.filled ? .fill : .stroke)
    }
    static func contains(_ drawing: EaselDrawing, point: CGPoint, in rect: CGRect, tolerance: CGFloat) -> Bool {
        guard point.x.isFinite, point.y.isFinite, rect.width.isFinite, rect.height.isFinite,
              rect.width > 0, rect.height > 0, tolerance.isFinite, tolerance >= 0 else { return false }
        let logical = path(drawing)
        let ink = drawing.path.filled ? logical : logical.copy(strokingWithWidth: drawing.style.lineWidth, lineCap: .round, lineJoin: .round, miterLimit: 10)
        var transform = CGAffineTransform(a: rect.width / drawing.viewBoxWidth, b: 0, c: 0, d: rect.height / drawing.viewBoxHeight, tx: rect.minX, ty: rect.minY)
        guard let visible = ink.copy(using: &transform) else { return false }
        if visible.contains(point) { return true }
        return tolerance > 0 && visible.copy(strokingWithWidth: tolerance * 2, lineCap: .round, lineJoin: .round, miterLimit: 10).contains(point)
    }
}
