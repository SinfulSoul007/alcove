import Foundation
import BrowserCore

/// Pure sampling/normalization contracts; no application or GUI is created.
@main struct EaselDrawingGestureChecks {
    static func main() throws {
        var checked = 0, failed = 0
        func check(_ ok: Bool, _ name: String) { checked += 1; if !ok { failed += 1 }; print("\(ok ? "PASS" : "FAIL"): \(name)") }
        func rejects(_ name: String, _ body: () throws -> Void) {
            do { try body(); check(false, name) } catch is EaselError { check(true, name) } catch { check(false, name) }
        }
        let style = try EaselDrawingStyle(color: "#3266CC", lineWidth: 4, opacity: 0.5)
        func sample(_ x: Double, _ y: Double) throws -> EaselCanvasSample { try .init(x: x, y: y) }
        var dot = try EaselDrawingGesture(kind: .pen, style: style, start: sample(300, 400))
        let dotItem = try dot.makeItem()
        check(dotItem.frame == (try EaselFrame(x: 280, y: 380, width: 40, height: 40)), "A pen click becomes a usable centered forty-point item")
        if case .drawing(let drawing) = dotItem.content {
            check(try drawing.path.filled && drawing.points == [try EaselDrawingPoint(x: 20, y: 20)] && drawing.style == style, "A gesture keeps its captured style and creates visible dot geometry")
        } else { check(false, "A pen click creates typed drawing content") }
        try dot.append(sample(340, 430))
        let extended = try dot.makeItem()
        check(extended.id == dotItem.id, "Preview and completed drawing retain one item identity")
        check(extended.frame == (try EaselFrame(x: 298, y: 395, width: 44, height: 40)), "Logical normalization keeps the stroke in the original board coordinates")
        if case .drawing(let d) = extended.content {
            check(d.points == [try .init(x: 2, y: 5), try .init(x: 42, y: 35)], "A normal drag preserves its first and current logical endpoints")
        } else { check(false, "A normal drag remains a drawing") }
        for coordinate in [-1.0, 16384.01, .infinity, .nan] {
            rejects("Invalid board sample x is rejected: \(coordinate)") { _ = try sample(coordinate, 20) }
            rejects("Invalid board sample y is rejected: \(coordinate)") { _ = try sample(20, coordinate) }
        }
        let edge = try EaselDrawingGesture(kind: .pen, style: style, start: sample(0, 0)).makeItem()
        check(edge.frame.x == 0 && edge.frame.y == 0, "A near-edge mark stays inside the board")
        if case .drawing(let d) = edge.content {
            check(d.points == [try .init(x: 2, y: 2)] && d.path.filled, "Edge clamping retains the full dot rather than clipping half its ink")
        } else { check(false, "The edge mark remains typed") }
        var reversed = try EaselDrawingGesture(kind: .rectangle, style: style, start: sample(900, 700))
        try reversed.append(sample(100, 200)); try reversed.append(sample(200, 250))
        check(try reversed.samples.count == 2 && reversed.samples.first == (try sample(900, 700)) && reversed.samples.last == (try sample(200, 250)), "Shape previews replace only their live endpoint")
        if case .drawing(let d) = try reversed.makeItem().content {
            check(d.kind == .rectangle && d.points.count == 2 && d.viewBoxWidth == 704 && d.viewBoxHeight == 454, "Reversed shapes normalize to their complete final outline")
        } else { check(false, "A shape gesture produces editable geometry") }
        var long = try EaselDrawingGesture(kind: .pen, style: style, start: sample(100, 100))
        var maximum = 0
        for i in 1...100_000 { try long.append(sample(100 + Double(i % 200), 100 + Double(i % 100))); maximum = max(maximum, long.samples.count) }
        check(maximum <= 4096 && long.didCompactSamples, "A hundred-thousand-event pen gesture stays bounded while recording compaction")
        check(try long.samples.first == (try sample(100, 100)) && long.samples.last == (try sample(100, 100)), "Compaction retains the initial and latest endpoint")
        if case .drawing(let d) = try long.makeItem().content {
            check(d.points.count <= 4096 && d.points.count > 1, "A compacted gesture remains a bounded editable stroke")
        } else { check(false, "A compacted gesture remains a drawing") }
        var same = try EaselDrawingGesture(kind: .pen, style: style, start: sample(50, 50))
        for _ in 0..<10_000 { try same.append(sample(50, 50)) }
        check(same.samples.count == 1 && !same.didCompactSamples, "Stationary events keep one visible sample without wasted storage")
        for kind in [EaselDrawingKind.line, .arrow, .rectangle, .ellipse] {
            let emptyShape = try EaselDrawingGesture(kind: kind, style: style, start: sample(20, 20))
            rejects("An unfinished \(kind) gesture cannot commit an invisible shape") { _ = try emptyShape.makeItem() }
        }
        var tooWide = try EaselDrawingGesture(kind: .pen, style: style, start: sample(100, 100))
        try tooWide.append(sample(5000, 100))
        rejects("A gesture beyond the item limit is reported instead of silently scaled or truncated") { _ = try tooWide.makeItem() }
        for i in 1...10_000 { try tooWide.append(sample(100 + Double(i % 100), 100)) }
        rejects("Compaction cannot conceal an earlier oversized extent") { _ = try tooWide.makeItem() }
        let thick = try EaselDrawingStyle(color: "#FFFFFF", lineWidth: 32, opacity: 1)
        var arrow = try EaselDrawingGesture(kind: .arrow, style: thick, start: sample(16384, 0))
        try arrow.append(sample(16384, 300))
        let arrowItem = try arrow.makeItem()
        check(arrowItem.frame.x >= 0 && arrowItem.frame.y >= 0 && arrowItem.frame.x + arrowItem.frame.width <= 16384, "A thick near-edge arrow keeps its complete head and stroke inside the board")
        check(try JSONDecoder().decode(EaselItem.self, from: JSONEncoder().encode(arrowItem)) == arrowItem, "Normalized gesture output satisfies the saved document decoder")
        print("Easel drawing gesture checks: \(checked) checked, \(failed) failed")
        if failed != 0 { exit(1) }
    }
}
