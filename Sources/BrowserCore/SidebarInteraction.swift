public struct SidebarResizeState {
    public private(set) var temporaryWidth: Double?
    private var startingWidth = 236.0
    public init() {}
    public mutating func begin(at width: Double) { startingWidth = width; temporaryWidth = width }
    public mutating func drag(by delta: Double, windowWidth: Double) {
        guard temporaryWidth != nil else { return }
        temporaryWidth = SidebarSizing.width(saved: startingWidth + delta, windowWidth: windowWidth)
    }
    public mutating func finish() -> Double? { let result = temporaryWidth; temporaryWidth = nil; return result }
    public mutating func cancel() { temporaryWidth = nil }
}
public struct SidebarHoverState {
    public private(set) var revealed = false
    private var generation = 0
    public init() {}
    public mutating func schedule() -> Int { generation += 1; return generation }
    public mutating func cancelPending() { generation += 1 }
    public mutating func completeReveal(_ token: Int) { if token == generation { revealed = true } }
    public mutating func completeHide(_ token: Int) { if token == generation { revealed = false } }
    public mutating func reset() { generation += 1; revealed = false }
}

public struct SidebarSpaceSwipe {
    public enum Phase { case began, changed, ended, cancelled }
    public enum Direction: Int { case previous = -1, next = 1 }
    public enum Update: Equatable {
        case passThrough
        case track(Double)
        case reset
        case switchSpace(Direction)
    }

    private enum Axis { case idle, undecided, horizontal, vertical }
    private var axis: Axis = .idle
    private var horizontal: Double = 0
    private var vertical: Double = 0

    public init() {}

    public mutating func update(_ phase: Phase, x: Double = 0, y: Double = 0) -> Update {
        switch phase {
        case .began:
            axis = .undecided
            horizontal = 0
            vertical = 0
        case .changed:
            break
        case .cancelled:
            defer { axis = .idle }
            return axis == .horizontal ? .reset : .passThrough
        case .ended:
            defer { axis = .idle }
            guard axis == .horizontal else { return .passThrough }
            let travel = horizontal + x
            guard abs(travel) >= 64 else { return .reset }
            return .switchSpace(travel < 0 ? .next : .previous)
        }

        guard axis == .undecided || axis == .horizontal else { return .passThrough }
        horizontal += x
        vertical += abs(y)
        if axis == .undecided {
            if vertical >= 10, vertical >= abs(horizontal) {
                axis = .vertical
            } else if abs(horizontal) >= 12, abs(horizontal) > vertical * 1.6 {
                axis = .horizontal
            }
        }
        return axis == .horizontal ? .track(horizontal) : .passThrough
    }
}
