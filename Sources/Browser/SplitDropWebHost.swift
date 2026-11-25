import AppKit
import WebKit

enum BrowserSplitDropGeometry {
    static func sidebarEdge(at x: CGFloat, width: CGFloat) -> BrowserSplitEdge? {
        guard width >= 72, x >= 0, x < width else { return nil }
        let edgeWidth = min(42, width * 0.22)
        if x < edgeWidth { return .left }
        if x >= width - edgeWidth { return .right }
        return nil
    }

    // Native host coordinates start at the bottom left.
    static func pageEdge(at point: CGPoint, in bounds: CGRect) -> BrowserSplitEdge? {
        guard bounds.width > 0, bounds.height > 0, bounds.contains(point) else { return nil }
        let horizontal = bounds.width / 4
        let vertical = bounds.height / 4
        let edges: [(edge: BrowserSplitEdge, distance: CGFloat, limit: CGFloat)] = [
            (.left, point.x - bounds.minX, horizontal), (.right, bounds.maxX - point.x, horizontal),
            (.top, bounds.maxY - point.y, vertical), (.bottom, point.y - bounds.minY, vertical),
        ]
        return edges.filter { $0.distance <= $0.limit }.min { $0.distance < $1.distance }?.edge
    }

    static func highlightFrame(for edge: BrowserSplitEdge, in bounds: CGRect) -> CGRect {
        let rect = bounds.insetBy(dx: 8, dy: 8)
        switch edge {
        case .left: return CGRect(x: rect.minX, y: rect.minY, width: rect.width / 3, height: rect.height)
        case .right: return CGRect(x: rect.maxX - rect.width / 3, y: rect.minY, width: rect.width / 3, height: rect.height)
        case .top: return CGRect(x: rect.minX, y: rect.maxY - rect.height / 3, width: rect.width, height: rect.height / 3)
        case .bottom: return CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height / 3)
        }
    }
}

/// WebKit registers drag types of its own. Route Alcove's type from the
/// actual hit view, which AppKit visits before its container.
final class SplitDropWebView: WKWebView {
    private(set) var websiteFullscreen: WebsiteFullscreen?
    private weak var splitDragHost: SplitDropWebHost?
    private var splitDragSequence: Int?

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        // This subclass is reserved for actual browser pages. Reader and other
        // inert/internal web views keep their separate restricted configurations.
        configuration.preferences.isElementFullscreenEnabled = true
        super.init(frame: frame, configuration: configuration)
        websiteFullscreen = WebsiteFullscreen(web: self)
        registerForDraggedTypes(registeredDraggedTypes + [SidebarTabDrag.pasteboardType])
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:configuration:)") }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        websiteFullscreen?.viewDidMove()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        websiteFullscreen?.viewDidMove()
    }

    private func isSidebarDrag(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.types?.contains(SidebarTabDrag.pasteboardType) == true
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        splitDragHost?.draggingExited(nil)
        splitDragHost = nil
        splitDragSequence = nil
        guard isSidebarDrag(sender) else { return super.draggingEntered(sender) }
        splitDragHost = superview as? SplitDropWebHost
        splitDragSequence = sender.draggingSequenceNumber
        return splitDragHost?.draggingEntered(sender) ?? []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if splitDragSequence == sender.draggingSequenceNumber {
            return splitDragHost?.draggingUpdated(sender) ?? []
        }
        return isSidebarDrag(sender) ? [] : super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        if let sequence = splitDragSequence, sender == nil || sender?.draggingSequenceNumber == sequence {
            splitDragHost?.draggingExited(sender)
            splitDragHost = nil
            splitDragSequence = nil
            return
        }
        if sender.map(isSidebarDrag) != true { super.draggingExited(sender) }
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        if splitDragSequence == sender.draggingSequenceNumber {
            splitDragHost?.draggingEnded(sender)
            splitDragHost = nil
            splitDragSequence = nil
        } else if !isSidebarDrag(sender) {
            super.draggingEnded(sender)
        }
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if splitDragSequence == sender.draggingSequenceNumber {
            return splitDragHost?.prepareForDragOperation(sender) ?? false
        }
        return !isSidebarDrag(sender) && super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if splitDragSequence == sender.draggingSequenceNumber {
            defer { splitDragHost = nil }
            return splitDragHost?.performDragOperation(sender) ?? false
        }
        return !isSidebarDrag(sender) && super.performDragOperation(sender)
    }
}

final class SplitDropWebHost: EdgeToEdgeWebHost {
    private final class Indicator: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    private weak var store: BrowserStore?
    private var destination: BrowserSplitDropTarget?
    private var color = NSColor.controlAccentColor
    private var hoveredEdge: BrowserSplitEdge?
    private var dragTarget: (sequence: Int, destination: BrowserSplitDropTarget)?
    private weak var dragPage: WKWebView?
    private let indicator = Indicator()

    func bindDrop(store: BrowserStore?, destination: BrowserSplitDropTarget?, color: NSColor) {
        let wasRegistered = self.destination != nil
        if self.destination != destination { showIndicator(nil) }
        self.store = store
        self.destination = destination
        self.color = color
        if !wasRegistered && destination != nil { registerForDraggedTypes([SidebarTabDrag.pasteboardType]) }
        if wasRegistered && destination == nil { unregisterDraggedTypes() }
    }

    private func splitCandidate(from sender: NSDraggingInfo) -> (SidebarTabDrag, BrowserSplitDropTarget, BrowserSplitEdge)? {
        guard let store, let destination, let page = store.views[destination.tab], page.superview === self else { return nil }
        if dragTarget?.sequence != sender.draggingSequenceNumber {
            dragTarget = (sender.draggingSequenceNumber, destination)
            dragPage = page
        }
        guard let start = dragTarget, start.destination == destination, dragPage === page,
              store.visiblePaneIDs.contains(start.destination.tab),
              let drag = SidebarTabDrag.decode(sender.draggingPasteboard.data(forType: SidebarTabDrag.pasteboardType)),
              let edge = BrowserSplitDropGeometry.pageEdge(at: convert(sender.draggingLocation, from: nil), in: bounds),
              store.canSplitDrop(drag, onto: start.destination) else { return nil }
        return (drag, start.destination, edge)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let (_, _, edge) = splitCandidate(from: sender) else { showIndicator(nil); return [] }
        let mask = sender.draggingSourceOperationMask
        let operation: NSDragOperation = mask.contains(.move) ? .move : (mask.contains(.copy) ? .copy : [])
        showIndicator(operation.isEmpty ? nil : edge)
        return operation
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dragTarget = nil
        dragPage = nil
        showIndicator(nil)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        guard dragTarget?.sequence == sender.draggingSequenceNumber else { return }
        if let drag = SidebarTabDrag.decode(sender.draggingPasteboard.data(forType: SidebarTabDrag.pasteboardType)),
           SidebarTabDrag.preview == drag { SidebarTabDrag.preview = nil }
        draggingExited(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !draggingUpdated(sender).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { draggingExited(sender) }
        guard !draggingUpdated(sender).isEmpty, let (drag, target, edge) = splitCandidate(from: sender), let store else { return false }
        if SidebarTabDrag.preview == drag { SidebarTabDrag.preview = nil }
        return store.performSplitDrop(drag, onto: target, edge: edge)
    }

    override func layout() {
        super.layout()
        if let hoveredEdge { indicator.frame = BrowserSplitDropGeometry.highlightFrame(for: hoveredEdge, in: bounds) }
    }

    private func showIndicator(_ edge: BrowserSplitEdge?) {
        guard let edge, bounds.width >= 20, bounds.height >= 20 else {
            hoveredEdge = nil
            indicator.removeFromSuperview()
            return
        }
        hoveredEdge = edge
        indicator.frame = BrowserSplitDropGeometry.highlightFrame(for: edge, in: bounds)
        if indicator.superview !== self {
            indicator.wantsLayer = true
            indicator.setAccessibilityElement(false)
            addSubview(indicator, positioned: .above, relativeTo: nil)
        }
        indicator.layer?.cornerRadius = 10
        indicator.layer?.backgroundColor = color.withAlphaComponent(0.24).cgColor
        indicator.layer?.borderColor = color.withAlphaComponent(0.85).cgColor
        indicator.layer?.borderWidth = 2
    }
}
