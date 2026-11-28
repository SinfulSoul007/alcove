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
        // Review R1: hand-selected 120% viewport coordinates previously failed
        // strict path validation after local-coordinate subtraction rounded.
        for (kind, start, end) in [
            (EaselDrawingKind.line, try sample(4.0 / 1.2, 160), try sample(78.0 / 1.2, 160)),
            (.line, try sample(78.0 / 1.2, 160), try sample(4.0 / 1.2, 160)),
            (.rectangle, try sample(4.0 / 1.2, 160), try sample(78.0 / 1.2, 220.0 / 1.2)),
            (.ellipse, try sample(4.0 / 1.2, 160), try sample(78.0 / 1.2, 220.0 / 1.2)),
            (.ellipse, try sample(78.0 / 1.2, 220.0 / 1.2), try sample(4.0 / 1.2, 160))
        ] {
            do {
                var input = try EaselDrawingGesture(kind: kind, style: style, start: start)
                try input.append(end)
                let item = try input.makeItem()
                if case .drawing(let drawing) = item.content {
                    let actualFirst = drawing.points.first!, actualLast = drawing.points.last!
                    check(abs(item.frame.x + actualFirst.x - start.x) < 0.000001 && abs(item.frame.y + actualFirst.y - start.y) < 0.000001 &&
                          abs(item.frame.x + actualLast.x - end.x) < 0.000001 && abs(item.frame.y + actualLast.y - end.y) < 0.000001,
                          "Fractional-zoom \(kind) preserves valid endpoints and produces a saved drawing")
                } else { check(false, "Fractional-zoom input remains a drawing") }
            } catch { check(false, "Fractional-zoom \(kind) remains representable: \(error)") }
        }
        // Review R2: a large early landmark must survive repeated compaction,
        // including its actually rendered quadratic apex, not only its bounds.
        do {
            var landmark = try EaselDrawingGesture(kind: .pen, style: style, start: sample(100, 100))
            for i in 1...512 { try landmark.append(sample(100 + Double(i), 100 + Double(i))) }
            for i in 1...512 { try landmark.append(sample(612 + Double(i), 612 - Double(i))) }
            for i in 0..<32_680 { try landmark.append(sample(1124 + Double(i % 2), 100)) }
            let item = try landmark.makeItem()
            if case .drawing(let drawing) = item.content {
                check(drawing.points.contains { abs(item.frame.x + $0.x - 612) < 0.000001 && abs(item.frame.y + $0.y - 612) < 0.000001 },
                      "Repeated compaction keeps the large early triangle landmark")
                var current = try EaselDrawingPoint(x: 0, y: 0), maximumY = 0.0
                for command in drawing.path.commands {
                    switch command {
                    case .move(let point), .line(let point): current = point; maximumY = max(maximumY, point.y)
                    case .quadratic(let control, let end):
                        for step in 0...100 {
                            let t = Double(step) / 100, u = 1 - t
                            maximumY = max(maximumY, u * u * current.y + 2 * u * t * control.y + t * t * end.y)
                        }
                        current = end
                    default: break
                    }
                }
                check(item.frame.y + maximumY >= 611.5, "The simplified rendered curve retains the hand-derived 611.75-point triangle apex")
            } else { check(false, "The compacted landmark remains drawing content") }
        } catch { check(false, "A triangle followed by a simple tail remains representable: \(error)") }
        var fractionalSweepFailures = 0
        for zoom in [0.25, 0.33, 0.5, 0.67, 0.8, 1, 1.1, 1.2, 1.25, 1.5, 1.75, 2] {
            for base in [0.0, 10_000, 15_000] {
                for width in [1.0, 4, 32] {
                    for kind in [EaselDrawingKind.pen, .line, .arrow, .rectangle, .ellipse] {
                        do {
                            let ink = try EaselDrawingStyle(color: "#3466CC", lineWidth: width, opacity: 1)
                            var input = try EaselDrawingGesture(kind: kind, style: ink, start: sample(base + 100 + 100.1 / zoom, 100 + 120.2 / zoom))
                            try input.append(sample(base + 100 + 200.3 / zoom, 100 + 220.4 / zoom))
                            _ = try input.makeItem()
                        } catch {
                            fractionalSweepFailures += 1
                            if fractionalSweepFailures <= 5 { print("FRACTIONAL_SWEEP_FAILURE", kind, zoom, base, width, error) }
                        }
                    }
                }
            }
        }
        check(fractionalSweepFailures == 0, "Fractional input stays representable across twelve zooms, three board positions and all pen widths/kinds")
        var complex = try EaselDrawingGesture(kind: .pen, style: style, start: sample(200, 200))
        var seed: UInt64 = 93, reportedComplexity = false, unchangedOnRefusal = false
        for _ in 0..<8192 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let x = 100 + Double((seed >> 32) % 500)
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let y = 100 + Double((seed >> 32) % 500)
            let previous = complex.samples
            do { try complex.append(sample(x, y)) }
            catch EaselDrawingGestureError.tooComplex {
                reportedComplexity = true; unchangedOnRefusal = complex.samples == previous; break
            }
        }
        check(reportedComplexity && unchangedOnRefusal && complex.samples.count <= 4096,
              "An unsimplifiable stroke reports its limit without truncating or mutating its last valid preview")
        print("Easel drawing gesture checks: \(checked) checked, \(failed) failed")
        if failed != 0 { exit(1) }
    }
}
