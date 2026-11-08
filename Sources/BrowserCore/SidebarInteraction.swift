public struct SidebarResizeState {
    public private(set) var temporaryWidth: Double?
    private var startingWidth = 236.0
    public init() {}
    public mutating func begin(at width: Double) { startingWidth = width; temporaryWidth = width }
    public mutating func drag(by delta: Double, windowWidth: Double) { temporaryWidth = SidebarSizing.width(saved: startingWidth + delta, windowWidth: windowWidth) }
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
