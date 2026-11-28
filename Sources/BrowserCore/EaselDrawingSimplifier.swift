import Foundation

public enum EaselDrawingGestureError: LocalizedError {
    case tooComplex
    public var errorDescription: String? {
        "This stroke has too much detail to simplify faithfully. Finish a shorter stroke and start another."
    }
}

/// Simplify only a new tail: earlier retained geometry is never thinned again.
/// Significant samples keep their immediate neighbors so midpoint smoothing
/// cannot replace a sharp, densely sampled corner with a broad rounded bend.
enum EaselDrawingSimplifier {
    static func compact(_ samples: [EaselCanvasSample], preservedCount: Int) throws -> [EaselCanvasSample] {
        let start = max(0, min(samples.count, preservedCount) - 1)
        let tail = removingRepeatedCycles(Array(samples[start...]))
        guard !tail.isEmpty else { throw EaselDrawingGestureError.tooComplex }
        var keep = Array(repeating: false, count: tail.count)
        keep[0] = true; keep[tail.count - 1] = true
        var work = [(0, tail.count - 1)], comparisons = 0
        while let (first, last) = work.popLast() {
            guard last - first > 1 else { continue }
            let a = tail[first], b = tail[last]
            let dx = b.x - a.x, dy = b.y - a.y, lengthSquared = dx * dx + dy * dy
            var furthest: Int?, maximumSquared = 0.25 // half a board point
            for index in (first + 1)..<last {
                comparisons += 1
                guard comparisons <= 262_144 else { throw EaselDrawingGestureError.tooComplex }
                let point = tail[index]
                let t = lengthSquared > 0 ? min(1, max(0, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared)) : 0
                let ex = point.x - (a.x + t * dx), ey = point.y - (a.y + t * dy)
                let distanceSquared = ex * ex + ey * ey
                if distanceSquared > maximumSquared { maximumSquared = distanceSquared; furthest = index }
            }
            if let furthest {
                keep[furthest] = true
                work.append((first, furthest)); work.append((furthest, last))
            }
        }
        var selected = Set<Int>()
        for index in keep.indices where keep[index] {
            for neighbor in max(0, index - 1)...min(tail.count - 1, index + 1) { selected.insert(neighbor) }
        }
        var result = Array(samples.prefix(start))
        result.append(contentsOf: selected.sorted().map { tail[$0] })
        guard result.count < 4096 else { throw EaselDrawingGestureError.tooComplex }
        return result
    }

    /// A repeated exact trajectory paints the same single stroked path. Keep
    /// two complete periods (including their join) and the final partial period
    /// so its first/last samples and endpoint smoothing remain unchanged.
    private static func removingRepeatedCycles(_ points: [EaselCanvasSample]) -> [EaselCanvasSample] {
        guard points.count >= 6 else { return points }
        var prefix = Array(repeating: 0, count: points.count)
        for index in 1..<points.count {
            var length = prefix[index - 1]
            while length > 0 && points[index] != points[length] { length = prefix[length - 1] }
            if points[index] == points[length] { length += 1 }
            prefix[index] = length
        }
        let period = points.count - prefix[points.count - 1]
        guard period > 0, points.count / period >= 3 else { return points }
        let remaining = points.count % period
        var result = Array(points.prefix(2 * period))
        if remaining > 0 { result.append(contentsOf: points.suffix(remaining)) }
        return result
    }
}
