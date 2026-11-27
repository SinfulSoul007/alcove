import Foundation
import BrowserCore

/// Pure value/geometry/decoder checks; never creates an application or window.
@main struct EaselDrawingCoreChecks {
    static func main() throws {
        var checked = 0, failed = 0
        func check(_ value: Bool, _ name: String) {
            checked += 1; if !value { failed += 1 }
            print("\(value ? "PASS" : "FAIL"): \(name)")
        }
        func rejects(_ name: String, _ body: () throws -> Void) {
            do { try body(); check(false, name) }
            catch EaselError.invalidContent { check(true, name) }
            catch { check(false, name + " (unexpected \(error))") }
        }
        func p(_ x: Double, _ y: Double) throws -> EaselDrawingPoint { try .init(x: x, y: y) }
        let style = try EaselDrawingStyle(color: "#aBc123", lineWidth: 4, opacity: 0.5)
        func drawing(_ kind: EaselDrawingKind, _ points: [EaselDrawingPoint], width: Double = 100, height: Double = 80) throws -> EaselDrawing {
            try .init(kind: kind, viewBoxWidth: width, viewBoxHeight: height, points: points, style: style)
        }
        check(style.color == "#ABC123", "Saved ink colors have a stable ASCII RGB representation")
        for color in ["123456", "#12345", "#12345678", "#12G456", "#１２３４５６", "red", "#000000\n"] {
            rejects("Unsupported ink color is refused: \(color.debugDescription)") { _ = try EaselDrawingStyle(color: color, lineWidth: 4, opacity: 1) }
        }
        for width in [0.0, 0.99, 32.01, .infinity, .nan] {
            rejects("Invalid line thickness is refused: \(width)") { _ = try EaselDrawingStyle(color: "#000000", lineWidth: width, opacity: 1) }
        }
        for opacity in [0.0, 0.09, 1.01, .infinity, .nan] {
            rejects("Invisible or invalid ink opacity is refused: \(opacity)") { _ = try EaselDrawingStyle(color: "#000000", lineWidth: 4, opacity: opacity) }
        }
        for coordinate in [-0.01, 4096.01, .infinity, .nan] {
            rejects("Out-of-canvas sample x is refused: \(coordinate)") { _ = try p(coordinate, 10) }
            rejects("Out-of-canvas sample y is refused: \(coordinate)") { _ = try p(10, coordinate) }
        }
        for size in [39.99, 4096.01, .infinity, .nan] {
            rejects("Invalid logical width is refused: \(size)") { _ = try drawing(.pen, [p(20, 20)], width: size) }
            rejects("Invalid logical height is refused: \(size)") { _ = try drawing(.pen, [p(20, 20)], height: size) }
        }
        let thinDot = try EaselDrawing(kind: .pen, viewBoxWidth: 40, viewBoxHeight: 40, points: [p(0.5, 20)],
                                       style: EaselDrawingStyle(color: "#000000", lineWidth: 1, opacity: 1))
        check(thinDot.path.commands.first == .move(try p(1, 20)) && thinDot.path.filled, "The smallest box and finest opaque pen retain a dot exactly against the box edge")
        let wideDot = try EaselDrawing(kind: .pen, viewBoxWidth: 4096, viewBoxHeight: 4096, points: [p(4080, 4080)],
                                       style: EaselDrawingStyle(color: "#FFFFFF", lineWidth: 32, opacity: 0.1))
        check(wideDot.path.commands.first == .move(try p(4096, 4080)) && wideDot.style.opacity == 0.1, "The largest supported box and widest translucent pen keep the full dot inside the boundary")

        let rectangle = try drawing(.rectangle, [p(90, 60), p(10, 20)])
        let rectangleCommands: [EaselDrawingCommand] = try [.move(p(10, 20)), .line(p(90, 20)), .line(p(90, 60)), .line(p(10, 60)), .close]
        check(rectangle.path.commands == rectangleCommands && !rectangle.path.filled, "Reversed rectangle drags produce the complete unfilled outline")
        let line = try drawing(.line, [p(10, 40), p(90, 40)])
        check(line.path.commands == [.move(try p(10, 40)), .line(try p(90, 40))] && !line.path.filled, "A horizontal line preserves its actual endpoints")
        let arrow = try drawing(.arrow, [p(10, 40), p(90, 40)])
        let arrowCommands: [EaselDrawingCommand] = try [.move(p(10, 40)), .line(p(90, 40)), .move(p(78, 46)), .line(p(90, 40)), .line(p(78, 34))]
        check(arrow.path.commands == arrowCommands && !arrow.path.filled, "Arrow shaft and both head sides meet at the endpoint")
        let reverseArrow = try drawing(.arrow, [p(90, 40), p(10, 40)])
        let reverseCommands: [EaselDrawingCommand] = try [.move(p(90, 40)), .line(p(10, 40)), .move(p(22, 34)), .line(p(10, 40)), .line(p(22, 46))]
        check(reverseArrow.path.commands == reverseCommands, "Reversing an arrow reverses its head rather than only its shaft")
        let shortArrow = try drawing(.arrow, [p(40, 40), p(50, 40)])
        check(shortArrow.path.commands == [.move(try p(40, 40)), .line(try p(50, 40)), .move(try p(46, 42)), .line(try p(50, 40)), .line(try p(46, 38))], "Short arrows keep the head shorter than the shaft")

        let ellipse = try drawing(.ellipse, [p(90, 60), p(10, 20)])
        let ellipseStart = try p(90, 40)
        let ellipseEnds = try [p(50, 60), p(10, 40), p(50, 20), p(90, 40)]
        var ends: [EaselDrawingPoint] = []
        for command in ellipse.path.commands { if case .cubic(_, _, let end) = command { ends.append(end) } }
        check(!ellipse.path.filled && ellipse.path.commands.first == .move(ellipseStart) && ellipse.path.commands.last == .close && ends == ellipseEnds, "Ellipse quadrants close through the four hand-derived axis endpoints")
        if ellipse.path.commands.count == 6, case .cubic(let a, let b, _) = ellipse.path.commands[1] {
            check(abs(a.x - 90) < 1e-9 && abs(a.y - 51.04569499661587) < 1e-9 && abs(b.x - 72.09138999323174) < 1e-9 && abs(b.y - 60) < 1e-9,
                  "Ellipse control points retain the expected smooth cubic geometry")
        } else { check(false, "Ellipse exposes a complete smooth four-quadrant path") }

        let pen = try drawing(.pen, [p(10, 10), p(20, 30), p(30, 10)])
        let penCommands: [EaselDrawingCommand] = try [.move(p(10, 10)), .quadratic(control: p(10, 10), end: p(15, 20)), .quadratic(control: p(20, 30), end: p(25, 20)), .line(p(30, 10))]
        check(pen.path.commands == penCommands && !pen.path.filled, "Pen smoothing keeps the first and last sample while rounding the interior")
        let dot = try drawing(.pen, [p(20, 20)])
        let coincident = try drawing(.pen, [p(20, 20), p(20, 20)])
        let dotStart = try p(22, 20)
        check(dot.path.filled && dot.path.commands.count == 6 && dot.path.commands.first == .move(dotStart) && dot.path.commands.last == .close,
              "A single pen sample creates a filled visible dot instead of an empty path")
        check(coincident.path == dot.path, "Coincident pen samples retain the same visible dot geometry")
        rejects("An empty pen mark is refused") { _ = try drawing(.pen, []) }
        for kind in [EaselDrawingKind.line, .arrow, .rectangle, .ellipse] {
            rejects("\(kind) refuses a single endpoint") { _ = try drawing(kind, [p(20, 20)]) }
            rejects("\(kind) refuses coincident endpoints") { _ = try drawing(kind, [p(20, 20), p(20, 20)]) }
            rejects("\(kind) refuses an extra endpoint") { _ = try drawing(kind, [p(10, 10), p(20, 30), p(30, 10)]) }
        }
        for kind in [EaselDrawingKind.rectangle, .ellipse] {
            rejects("\(kind) refuses zero-area horizontal outlines") { _ = try drawing(kind, [p(10, 20), p(90, 20)]) }
            rejects("\(kind) refuses zero-area vertical outlines") { _ = try drawing(kind, [p(20, 10), p(20, 60)]) }
        }
        rejects("Sample data beyond its logical view box is refused") { _ = try drawing(.pen, [p(120, 20)]) }
        rejects("A dot crossing its logical box boundary is refused") { _ = try drawing(.pen, [p(1, 20)]) }
        rejects("A thick shaft crossing its logical box boundary is refused") { _ = try drawing(.line, [p(1, 40), p(90, 40)]) }
        rejects("An arrowhead outside the logical box is refused even when its shaft fits") { _ = try drawing(.arrow, [p(4, 4), p(90, 4)]) }
        let maximumPen = try drawing(.pen, Array(repeating: p(20, 20), count: 4096))
        check(maximumPen.path == dot.path && maximumPen.points.count == 4096, "A bounded long coincident gesture stays representable without a giant empty path")
        rejects("An oversized pen gesture is refused") { _ = try drawing(.pen, Array(repeating: p(20, 20), count: 4097)) }

        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let data = try encoder.encode(pen)
        check(try decoder.decode(EaselDrawing.self, from: data) == pen, "Drawing JSON roundtrip preserves editable samples, style and derived geometry")
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        check(json["path"] == nil && (json["points"] as? [Any])?.count == 3, "Stored drawing data retains samples without duplicating generated geometry")
        var changedStyle = json["style"] as! [String: Any]; changedStyle["lineWidth"] = 0; json["style"] = changedStyle
        rejects("Decoded drawing styles are validated before use") { _ = try decoder.decode(EaselDrawing.self, from: JSONSerialization.data(withJSONObject: json)) }
        json = try JSONSerialization.jsonObject(with: data) as! [String: Any]; json["viewBoxWidth"] = 20
        rejects("Decoded view-box dimensions are validated before use") { _ = try decoder.decode(EaselDrawing.self, from: JSONSerialization.data(withJSONObject: json)) }
        json = try JSONSerialization.jsonObject(with: data) as! [String: Any]; json["points"] = [["x": -1, "y": 20]]
        rejects("Decoded points cannot bypass coordinate validation") { _ = try decoder.decode(EaselDrawing.self, from: JSONSerialization.data(withJSONObject: json)) }
        json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        json["points"] = Array(repeating: ["x": 20, "y": 20] as Any, count: 4096) + ["must not decode this excess sample"]
        rejects("Oversized JSON is refused before decoding an excess sample") { _ = try decoder.decode(EaselDrawing.self, from: JSONSerialization.data(withJSONObject: json)) }
        print("Easel drawing core checks: \(checked) checked, \(failed) failed")
        if failed != 0 { exit(1) }
    }
}
