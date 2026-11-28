import AppKit
import BrowserCore

enum EaselCanvasTool: String, CaseIterable, Identifiable {
    case select, pen, line, arrow, rectangle, ellipse
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .pen: return "pencil.tip"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        }
    }
    var kind: EaselDrawingKind? {
        switch self {
        case .select: return nil
        case .pen: return .pen
        case .line: return .line
        case .arrow: return .arrow
        case .rectangle: return .rectangle
        case .ellipse: return .ellipse
        }
    }
    static func shortcut(_ text: String?) -> Self? {
        switch text?.lowercased() {
        case "v": return .select
        case "p": return .pen
        case "l": return .line
        case "a": return .arrow
        case "r": return .rectangle
        case "e": return .ellipse
        default: return nil
        }
    }
}

@MainActor final class EaselDrawingInteraction {
    private weak var owner: EaselCanvasView?
    private var gesture: EaselDrawingGesture?
    private var captured: EaselTabContext?
    var isDrawing: Bool { gesture != nil }
    var preview: EaselItem? { guard available else { return nil }; return try? gesture?.makeItem() }
    init(owner: EaselCanvasView) { self.owner = owner }
    private var available: Bool {
        guard let owner, owner.isCurrentPresentation, let current = owner.context, let captured,
              let store = owner.store, !store.isShuttingDown, store.activeProfileID == captured.profileID,
              store.visiblePaneIDs.contains(owner.tabID) else { return false }
        return current.profileID == captured.profileID && current.easel.id == captured.easel.id
    }
    private func sample(_ point: NSPoint) throws -> EaselCanvasSample {
        guard point.x.isFinite, point.y.isFinite else { throw EaselError.invalidContent }
        return try .init(x: min(EaselFrame.canvasSize, max(0, point.x)), y: min(EaselFrame.canvasSize, max(0, point.y)))
    }
    @discardableResult func begin(at point: NSPoint) -> Bool {
        cancel()
        guard let owner, let kind = owner.drawingTool.kind, owner.activate(), let store = owner.store,
              store.canModifyLocalMetadata, store.flushEaselBoardDraftsIfPossible(in: owner.tabID), let context = owner.context,
              store.activeProfileID == context.profileID, store.visiblePaneIDs.contains(owner.tabID) else { return false }
        do {
            windowFocus(owner)
            gesture = try EaselDrawingGesture(kind: kind, style: owner.drawingStyle, start: sample(point))
            captured = context; owner.drawingOverlay.needsDisplay = true
            return true
        } catch { store.message = error.localizedDescription; return false }
    }
    private func windowFocus(_ owner: EaselCanvasView) { owner.window?.makeFirstResponder(owner.canvas) }
    func append(_ point: NSPoint) {
        guard available else { cancel(); return }
        do { try gesture?.append(sample(point)); owner?.drawingOverlay.needsDisplay = true }
        catch { owner?.store?.message = error.localizedDescription; cancel() }
    }
    @discardableResult func finish() -> Bool {
        guard available, let owner, let store = owner.store, let gesture, let captured else { cancel(); return false }
        defer { cancel() }
        do {
            let item = try gesture.makeItem()
            let saved = store.easelDrafts.commitDrawing(item, context: captured, from: store, history: owner)
            return saved
        } catch { store.message = "Couldn’t add this drawing. " + error.localizedDescription; return false }
    }
    func cancel() { gesture = nil; captured = nil; owner?.drawingOverlay.needsDisplay = true }
    func cancelIfUnavailable() { if isDrawing && !available { cancel() } }
}

extension EaselCanvasView: EaselDrawingHistoryRecording {
    func easelDrawingCommitted(_ item: EaselItem, before: Easel, after: Easel, profileID: UUID) {
        recordDrawingCommit(item, before: before, after: after, profileID: profileID)
    }
}

@MainActor final class EaselDrawingOverlay: NSView {
    weak var owner: EaselCanvasView?
    override var isFlipped: Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); setAccessibilityElement(false) }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard owner?.isCurrentPresentation == true, owner?.drawingTool.kind != nil else { return nil }
        return super.hitTest(point)
    }
    override func resetCursorRects() {
        if owner?.drawingTool.kind != nil { addCursorRect(bounds, cursor: .crosshair) }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let item = owner?.drawing.preview, case .drawing(let drawing) = item.content,
              let context = NSGraphicsContext.current?.cgContext else { return }
        EaselDrawingRenderer.draw(drawing, in: item.frame.rect, context: context)
    }
    override func mouseDown(with event: NSEvent) { owner?.drawing.begin(at: convert(event.locationInWindow, from: nil)) }
    override func mouseDragged(with event: NSEvent) { owner?.drawing.append(convert(event.locationInWindow, from: nil)) }
    override func mouseUp(with event: NSEvent) {
        guard owner?.drawing.isDrawing == true else { return }
        owner?.drawing.append(convert(event.locationInWindow, from: nil)); owner?.drawing.finish()
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { owner?.drawing.cancel() } }
}
