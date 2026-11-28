import AppKit
import BrowserCore
import Combine

@MainActor final class EaselCanvasHistory: NSObject {
    weak var owner: EaselCanvasView?
    init(owner: EaselCanvasView) { self.owner = owner }
}

@MainActor final class EaselCanvasView: NSScrollView, ObservableObject {
    weak var store: BrowserStore?
    let tabID: UUID
    let canvas = EaselCanvasDocumentView()
    private(set) var cards: [UUID: EaselCardView] = [:]
    @Published private(set) var selection: Set<UUID> = []
    @Published private(set) var zoom: CGFloat = 1
    @Published private(set) var drawingTool: EaselCanvasTool = .select
    @Published private(set) var drawingStyle = try! EaselDrawingStyle(color: "#3466CC", lineWidth: 4, opacity: 1)
    lazy var drawing = EaselDrawingInteraction(owner: self)
    let drawingOverlay = EaselDrawingOverlay()
    var canUseDrawingControls: Bool {
        guard isCurrentPresentation, let store, let context else { return false }
        return !store.isShuttingDown && store.activeProfileID == context.profileID && store.visiblePaneIDs.contains(tabID)
    }
    @discardableResult func setDrawingTool(_ tool: EaselCanvasTool) -> Bool {
        guard canUseDrawingControls, activate(), let store else { return false }
        if tool != .select {
            guard store.canModifyLocalMetadata, store.flushEaselBoardDraftsIfPossible(in: tabID) else { return false }
        }
        drawing.cancel(); drawingTool = tool
        window?.makeFirstResponder(canvas); window?.invalidateCursorRects(for: drawingOverlay)
        drawingOverlay.needsDisplay = true
        return true
    }
    @discardableResult func setDrawingStyle(_ style: EaselDrawingStyle) -> Bool {
        guard canUseDrawingControls, activate(), let store, store.canModifyLocalMetadata,
              store.flushEaselBoardDraftsIfPossible(in: tabID) else { return false }
        drawing.cancel(); drawingStyle = style
        return true
    }
    func recordDrawingCommit(_ item: EaselItem, before: Easel, after: Easel, profileID: UUID) {
        guard let current = context, current.profileID == profileID, current.easel.id == after.id else { return }
        registerUndo(before, profileID: profileID, expected: after.revision, name: "Draw")
        reconcile(); select(item.id)
    }
    private let history = UndoManager()
    private var historyRevision: UUID?
    private var historyImageIDs: Set<UUID> = []
    func retainedImageIDs(profile: UUID) -> Set<UUID> {
        guard let context, context.profileID == profile, isCurrentPresentation else { return [] }
        return historyImageIDs
    }
    private lazy var historyTarget = EaselCanvasHistory(owner: self)
    override var undoManager: UndoManager? { history }
    private struct Gesture {
        let context: EaselTabContext, item: EaselItem, resizing: Bool
        var frame: EaselFrame
    }
    private var gesture: Gesture?
    private var renderedProfileID: UUID?
    private var renderedEaselID: UUID?
    var context: EaselTabContext? { store?.easelContext(for: tabID) }
    var isCurrentPresentation: Bool {
        guard let context else { return false }
        return renderedProfileID == context.profileID && renderedEaselID == context.easel.id
    }
    @discardableResult func activate() -> Bool {
        guard isCurrentPresentation, let store else { return false }
        if window != nil { store.focusPane(tabID) }
        return true
    }
    init(store: BrowserStore, tabID: UUID) {
        self.store = store; self.tabID = tabID
        super.init(frame: .zero)
        (store.isPrivate ? store : store.metadataWriter).easelCanvasViews.add(self)
        drawsBackground = false; borderType = .noBorder
        hasVerticalScroller = true; hasHorizontalScroller = true; autohidesScrollers = true
        allowsMagnification = true; minMagnification = 0.25; maxMagnification = 2
        automaticallyAdjustsContentInsets = false
        history.groupsByEvent = false
        canvas.owner = self; canvas.frame = NSRect(x: 0, y: 0, width: EaselFrame.canvasSize, height: EaselFrame.canvasSize)
        drawingOverlay.owner = self; drawingOverlay.frame = canvas.bounds
        drawingOverlay.autoresizingMask = [.width, .height]; canvas.addSubview(drawingOverlay)
        documentView = canvas
        setAccessibilityLabel("Easel canvas viewport")
        if let color = NSColor(store.activeTheme.accent).usingColorSpace(.sRGB),
           let style = try? EaselDrawingStyle(color: String(format: "#%02X%02X%02X", Int((color.redComponent * 255).rounded()), Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded())), lineWidth: 4, opacity: 1) { drawingStyle = style }
        applyTheme(store.activeTheme, reduceMotion: true)
        reconcile()
    }
    required init?(coder: NSCoder) { nil }
    func applyTheme(_ theme: AppearanceTheme, reduceMotion: Bool) {
        appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        canvas.background = NSColor(theme.background)
        canvas.accent = NSColor(theme.accent)
        for card in cards.values { card.accent = canvas.accent; card.needsDisplay = true }
        canvas.needsDisplay = true
        // Native editing and viewport changes use no decorative animations.
    }
    func reconcile() {
        guard let context else {
            drawing.cancel()
            for card in cards.values { card.removeFromSuperview() }
            cards.removeAll(); selection.removeAll(); renderedProfileID = nil; renderedEaselID = nil; historyRevision = nil
            if !history.isUndoing && !history.isRedoing { history.removeAllActions() }; historyImageIDs.removeAll(); return
        }
        let board = context.easel
        if renderedProfileID != context.profileID || renderedEaselID != board.id {
            drawing.cancel()
            selection.removeAll(); historyRevision = nil
            if !history.isUndoing && !history.isRedoing { history.removeAllActions() }; historyImageIDs.removeAll()
            for card in cards.values { card.removeFromSuperview() }
            cards.removeAll(); renderedProfileID = context.profileID; renderedEaselID = board.id
        }
        let ids = Set(board.items.map(\.id))
        selection.formIntersection(ids)
        for id in Set(cards.keys).subtracting(ids) {
            cards.removeValue(forKey: id)?.removeFromSuperview()
        }
        for (index, item) in board.items.enumerated() {
            if let previous = cards[item.id], !previous.matches(item) { previous.removeFromSuperview(); cards.removeValue(forKey: item.id) }
            let card = cards[item.id] ?? EaselCardView(item: item, owner: self)
            if cards[item.id] == nil { cards[item.id] = card; canvas.addSubview(card) }
            card.update(item, updateFrame: gesture?.item.id != item.id)
            card.isSelected = selection.contains(item.id); card.accent = canvas.accent
            card.layerIndex = index
        }
        canvas.sortSubviews({ first, second, _ in
            MainActor.assumeIsolated {
                guard let a = first as? EaselCardView, let b = second as? EaselCardView else { return .orderedSame }
                return a.layerIndex < b.layerIndex ? .orderedAscending : a.layerIndex == b.layerIndex ? .orderedSame : .orderedDescending
            }
        }, context: nil)
        canvas.addSubview(drawingOverlay, positioned: .above, relativeTo: nil)
        drawing.cancelIfUnavailable()
    }
    func select(_ id: UUID?, extending: Bool = false) {
        var next = extending ? selection : []
        if let id, cards[id] != nil { next.insert(id) }
        guard next != selection else { return }
        selection = next
        for (id, card) in cards { card.isSelected = next.contains(id) }
    }
    func setZoom(_ value: CGFloat) {
        guard value.isFinite, activate() else { return }
        let bounded = min(2, max(0.25, value))
        setMagnification(bounded, centeredAt: NSPoint(x: documentVisibleRect.midX, y: documentVisibleRect.midY))
        zoom = magnification
    }
    override func magnify(with event: NSEvent) { super.magnify(with: event); zoom = magnification }
    func fitContent() {
        guard let items = context?.easel.items, let first = items.first else { setZoom(1); contentView.scroll(to: .zero); reflectScrolledClipView(contentView); return }
        let union = items.dropFirst().reduce(first.frame.rect) { $0.union($1.frame.rect) }.insetBy(dx: -48, dy: -48)
        let scale = min(contentView.bounds.width * magnification / union.width, contentView.bounds.height * magnification / union.height)
        setZoom(scale)
        contentView.scroll(to: NSPoint(x: max(0, union.minX), y: max(0, union.minY))); reflectScrolledClipView(contentView)
    }
    @discardableResult func beginGesture(itemID: UUID, resizing: Bool) -> Bool {
        guard activate(), let store, store.flushEaselBoardDraftsIfPossible(in: tabID), let context, let item = context.easel.items.first(where: { $0.id == itemID }) else { return false }
        select(itemID); window?.makeFirstResponder(canvas)
        gesture = Gesture(context: context, item: item, resizing: resizing, frame: item.frame)
        return true
    }
    func previewGesture(dx: Double, dy: Double) {
        guard dx.isFinite, dy.isFinite, var pending = gesture else { return }
        let original = pending.item.frame
        let frame: EaselFrame?
        if pending.resizing {
            frame = try? EaselFrame(x: original.x, y: original.y, width: min(4096, EaselFrame.canvasSize - original.x, max(40, original.width + dx)), height: min(4096, EaselFrame.canvasSize - original.y, max(40, original.height + dy)))
        } else {
            frame = try? EaselFrame(x: min(EaselFrame.canvasSize - original.width, max(0, original.x + dx)), y: min(EaselFrame.canvasSize - original.height, max(0, original.y + dy)), width: original.width, height: original.height)
        }
        guard let frame else { return }
        pending.frame = frame; gesture = pending; cards[pending.item.id]?.frame = frame.rect
    }
    @discardableResult func endGesture() -> Bool {
        guard let pending = gesture else { return false }
        gesture = nil
        guard pending.frame != pending.item.frame else { reconcile(); return true }
        do {
            guard let current = context, current.profileID == pending.context.profileID,
                  current.easel.id == pending.context.easel.id else { throw SearchInputError.contextChanged }
            let item = try EaselItem(id: pending.item.id, frame: pending.frame, content: pending.item.content)
            return try commit([.replace(item)], expected: pending.context.easel.revision, name: pending.resizing ? "Resize Card" : "Move Card")
        } catch { store?.message = error.localizedDescription; reconcile(); return false }
    }
    @discardableResult func commit(_ edits: [EaselEdit], expected: UUID, name: String) throws -> Bool {
        guard isCurrentPresentation, let store, let current = context, current.easel.revision == expected else { throw EaselError.staleRevision }
        let before = current.easel
        let after = try store.editEasel(in: tabID, expectedRevision: expected, edits: edits)
        if before != after { registerUndo(before, profileID: current.profileID, expected: after.revision, name: name) }
        reconcile(); return true
    }
    private func registerUndo(_ snapshot: Easel, profileID: UUID, expected: UUID, name: String) {
        if !history.isUndoing && !history.isRedoing, let historyRevision, historyRevision != snapshot.revision {
            history.removeAllActions(); historyImageIDs.removeAll()
        }
        historyRevision = expected
        historyImageIDs.formUnion(snapshot.items.compactMap { item -> UUID? in
            if case .image(let id, _, _, _, _) = item.content { return id }; return nil
        })
        let grouped = !history.isUndoing && !history.isRedoing
        if grouped { history.beginUndoGrouping() }
        history.registerUndo(withTarget: historyTarget) { target in
            // This view owns the manager on the main actor. Keep AppKit's
            // synchronous undo/redo grouping across older SDK annotations.
            MainActor.assumeIsolated { target.owner?.restore(snapshot, profileID: profileID, name: name) }
        }
        history.setActionName(name)
        if grouped { history.endUndoGrouping() }
    }
    private func restore(_ snapshot: Easel, profileID: UUID, name: String) {
        do {
            guard let bound = context, bound.profileID == profileID else { throw SearchInputError.contextChanged }
            let current = bound.easel
            guard current.id == snapshot.id, current.revision == historyRevision else { throw EaselError.staleRevision }
            let changes: [EaselEdit] = [.remove(Set(current.items.map(\.id)))] + snapshot.items.map(EaselEdit.insert) + [.rename(snapshot.title)]
            _ = try commit(changes, expected: current.revision, name: name)
        } catch { store?.message = "Couldn’t undo this canvas edit. " + error.localizedDescription; reconcile() }
    }
    @discardableResult func addImage(_ raster: EaselRaster, to destination: EaselImageDestination) throws -> EaselItem {
        guard activate(), let store, destination.tabID == tabID, let context else { throw EaselActionError.missing }
        let item = try store.addEaselImage(raster, to: destination)
        guard let after = self.context else { throw EaselActionError.missing }
        registerUndo(context.easel, profileID: context.profileID, expected: after.easel.revision, name: "Add Image")
        reconcile(); select(item.id); window?.makeFirstResponder(canvas)
        return item
    }
    @discardableResult func addNote() -> UUID? { add(.note(text: ""), width: 320, height: 240, name: "Add Note") }
    @discardableResult func addLink(title: String, url: String) -> UUID? { add(.link(title: title, url: url), width: 300, height: 150, name: "Add Link") }
    private func add(_ content: EaselItemContent, width: Double, height: Double, name: String) -> UUID? {
        do {
            guard activate(), let store, store.flushEaselBoardDraftsIfPossible(in: tabID), let board = context?.easel else { throw EaselActionError.missing }
            let visible = documentVisibleRect
            let offset = Double(board.items.count % 8) * 20
            let item = try EaselItem(frame: EaselFrame(x: min(EaselFrame.canvasSize - width, max(0, visible.minX + 64 + offset)), y: min(EaselFrame.canvasSize - height, max(0, visible.minY + 64 + offset)), width: width, height: height), content: content)
            _ = try commit([.insert(item)], expected: board.revision, name: name)
            select(item.id)
            if let note = cards[item.id]?.noteView { window?.makeFirstResponder(note) }
            return item.id
        } catch { store?.message = error.localizedDescription; return nil }
    }
    @discardableResult func deleteSelected() -> Bool { performSelectionEdit(name: "Delete Cards") { _ in [.remove(self.selection)] } }
    @discardableResult func bringSelectedToFront() -> Bool {
        performSelectionEdit(name: "Bring to Front") { board in [.reorder(board.items.filter { !self.selection.contains($0.id) }.map(\.id) + board.items.filter { self.selection.contains($0.id) }.map(\.id))] }
    }
    @discardableResult func moveSelected(dx: Double, dy: Double, resize: Bool = false) -> Bool {
        performSelectionEdit(name: resize ? "Resize Cards" : "Move Cards") { board in
            try board.items.filter { self.selection.contains($0.id) }.map { item in
                let f = item.frame
                let frame = try EaselFrame(x: resize ? f.x : min(EaselFrame.canvasSize - f.width, max(0, f.x + dx)), y: resize ? f.y : min(EaselFrame.canvasSize - f.height, max(0, f.y + dy)), width: resize ? min(4096, EaselFrame.canvasSize - f.x, max(40, f.width + dx)) : f.width, height: resize ? min(4096, EaselFrame.canvasSize - f.y, max(40, f.height + dy)) : f.height)
                return .replace(try EaselItem(id: item.id, frame: frame, content: item.content))
            }
        }
    }
    private func performSelectionEdit(name: String, edits: (Easel) throws -> [EaselEdit]) -> Bool {
        do {
            guard !selection.isEmpty, activate(), let store, store.flushEaselBoardDraftsIfPossible(in: tabID), let board = context?.easel else { return false }
            let committed = try commit(edits(board), expected: board.revision, name: name)
            if committed { window?.makeFirstResponder(canvas) }
            return committed
        } catch { store?.message = error.localizedDescription; reconcile(); return false }
    }
}

extension EaselFrame { var rect: NSRect { NSRect(x: x, y: y, width: width, height: height) } }

@MainActor final class EaselCanvasDocumentView: NSView, NSUserInterfaceValidations {
    weak var owner: EaselCanvasView?
    var background: NSColor = .windowBackgroundColor
    var accent: NSColor = .controlAccentColor
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { owner?.isCurrentPresentation == true }
    override var undoManager: UndoManager? { owner?.undoManager }
    @objc func undo(_ sender: Any?) {
        guard owner?.isCurrentPresentation == true, let undoManager, undoManager.canUndo else { return }
        undoManager.undo()
    }
    @objc func redo(_ sender: Any?) {
        guard owner?.isCurrentPresentation == true, let undoManager, undoManager.canRedo else { return }
        undoManager.redo()
    }
    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        guard owner?.isCurrentPresentation == true else { return false }
        if item.action == #selector(undo(_:)) { return undoManager?.canUndo == true }
        if item.action == #selector(redo(_:)) { return undoManager?.canRedo == true }
        return true
    }
    override init(frame: NSRect) { super.init(frame: frame); setAccessibilityRole(.group); setAccessibilityLabel("Easel canvas") }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        background.setFill(); dirtyRect.fill()
        NSColor.labelColor.withAlphaComponent(0.1).setFill()
        let visible = dirtyRect.intersection(visibleRect)
        guard !visible.isEmpty else { return }
        for x in stride(from: floor(visible.minX / 24) * 24, through: visible.maxX, by: 24) {
            for y in stride(from: floor(visible.minY / 24) * 24, through: visible.maxY, by: 24) { NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 1.5, height: 1.5)).fill() }
        }
    }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { owner?.activate() }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { owner?.drawing.cancel() }
        return accepted
    }
    override func mouseDown(with event: NSEvent) { owner?.activate(); owner?.select(nil); window?.makeFirstResponder(self) }
    override func keyDown(with event: NSEvent) {
        guard window?.firstResponder === self, let owner else { return }
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { super.keyDown(with: event); return }
        if event.keyCode == 53, owner.drawingTool != .select {
            owner.drawing.cancel(); _ = owner.setDrawingTool(.select); return
        }
        if let tool = EaselCanvasTool.shortcut(event.charactersIgnoringModifiers) {
            _ = owner.setDrawingTool(tool); return
        }
        let amount = event.modifierFlags.contains(.shift) ? 10.0 : 1.0
        switch event.keyCode {
        case 51, 117: _ = owner.deleteSelected()
        case 123: _ = owner.moveSelected(dx: -amount, dy: 0)
        case 124: _ = owner.moveSelected(dx: amount, dy: 0)
        case 125: _ = owner.moveSelected(dx: 0, dy: amount)
        case 126: _ = owner.moveSelected(dx: 0, dy: -amount)
        default: super.keyDown(with: event)
        }
    }
}
