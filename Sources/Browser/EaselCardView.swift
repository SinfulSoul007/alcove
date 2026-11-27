import AppKit
import BrowserCore

@MainActor final class EaselNoteTextView: NSTextView {
    private let textUndo = UndoManager()
    var didFocus: (() -> Void)?
    override var undoManager: UndoManager? { textUndo }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { didFocus?() }
        return accepted
    }
    override func mouseDown(with event: NSEvent) { didFocus?(); super.mouseDown(with: event) }
    private func accepts(_ input: Any, replacing range: NSRange) -> Bool {
        let replacement = (input as? NSAttributedString)?.string ?? (input as? String) ?? ""
        let target = range.location == NSNotFound ? (hasMarkedText() ? markedRange() : selectedRange()) : range
        guard let swiftRange = Range(target, in: string) else { return false }
        return string.replacingCharacters(in: swiftRange, with: replacement).utf8.count <= 16384
    }
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard accepts(insertString, replacing: replacementRange) else { NSSound.beep(); return }
        super.insertText(insertString, replacementRange: replacementRange)
    }
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard accepts(string, replacing: replacementRange) else { NSSound.beep(); return }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }
}

@MainActor final class EaselCardView: NSView, NSTextViewDelegate, EaselDraftEditing {
    let itemID: UUID
    var layerIndex = 0
    private(set) var noteView: EaselNoteTextView?
    private(set) var imageContent: EaselImageCardContent?
    private var imageSource: NSButton?
    private weak var owner: EaselCanvasView?
    private let textScroll = NSScrollView()
    private let dragHandle = EaselGestureHandle(resizing: false)
    private let resizeHandle = EaselGestureHandle(resizing: true)
    private var linkButton: NSButton?
    private var linkURL: String?
    private var savedItem: EaselItem
    private var lastSubmittedText: String?
    var accent: NSColor = .controlAccentColor { didSet { needsDisplay = true } }
    var isSelected = false { didSet { needsDisplay = true } }
    private var draftKey: EaselDraftKey?
    override var isFlipped: Bool { true }
    init(item: EaselItem, owner: EaselCanvasView) {
        itemID = item.id; self.owner = owner; savedItem = item
        super.init(frame: item.frame.rect)
        setAccessibilityRole(.group)
        dragHandle.card = self; resizeHandle.card = self
        addSubview(dragHandle); addSubview(resizeHandle)
        switch item.content {
        case .note:
            let text = EaselNoteTextView(frame: NSRect(x: 0, y: 0, width: max(1, frame.width - 28), height: 1))
            text.isRichText = false; text.isAutomaticQuoteSubstitutionEnabled = false
            text.isAutomaticDashSubstitutionEnabled = false; text.allowsUndo = true
            text.font = .systemFont(ofSize: 14); text.textColor = .labelColor; text.drawsBackground = false
            text.isVerticallyResizable = true; text.isHorizontallyResizable = false
            text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
            text.textContainerInset = NSSize(width: 2, height: 5); text.delegate = self
            text.didFocus = { [weak self] in
                guard let self, self.isCurrentScope else { return }
                self.owner?.activate(); self.owner?.select(self.itemID)
            }
            text.setAccessibilityLabel("Canvas note")
            textScroll.documentView = text; textScroll.drawsBackground = false
            textScroll.hasVerticalScroller = true; textScroll.autohidesScrollers = true; textScroll.borderType = .noBorder
            noteView = text; addSubview(textScroll)
        case .link:
            let button = NSButton(title: "", target: self, action: #selector(openLink))
            button.bezelStyle = .inline; button.isBordered = false; button.alignment = .left; button.lineBreakMode = .byTruncatingTail
            button.font = .systemFont(ofSize: 15, weight: .medium); linkButton = button; addSubview(button)
        case .image:
            let content = EaselImageCardContent(frame: .zero); imageContent = content; addSubview(content)
            let source = NSButton(title: "", target: self, action: #selector(openImageSource))
            source.isBordered = false; source.alignment = .left; source.lineBreakMode = .byTruncatingTail
            source.font = .systemFont(ofSize: 11); imageSource = source; addSubview(source)
        }
        update(item, updateFrame: true)
    }
    required init?(coder: NSCoder) { nil }
    func matches(_ item: EaselItem) -> Bool {
        switch item.content {
        case .note: return noteView != nil
        case .link: return linkButton != nil
        case .image: return imageContent != nil
        }
    }
    private var isCurrentScope: Bool {
        guard let draftKey, let context = owner?.context,
              context.profileID == draftKey.profileID, context.easel.id == draftKey.easelID else { return false }
        return true
    }
    private var isCurrent: Bool {
        guard isCurrentScope, let item = owner?.context?.easel.items.first(where: { $0.id == itemID }) else { return false }
        return matches(item)
    }
    func update(_ item: EaselItem, updateFrame: Bool) {
        if updateFrame { frame = item.frame.rect }
        guard let owner, let store = owner.store, let context = owner.context else { return }
        draftKey = EaselDraftKey(profileID: context.profileID, easelID: context.easel.id, tabID: owner.tabID, itemID: itemID)
        switch item.content {
        case .note(let saved):
            let text = draftKey.flatMap { store.easelDrafts.state(for: $0)?.text } ?? saved
            if let noteView, noteView.string != text, !noteView.hasMarkedText() {
                let range = noteView.selectedRange(); noteView.string = text
                noteView.undoManager?.removeAllActions()
                let start = min(range.location, (text as NSString).length)
                noteView.setSelectedRange(NSRange(location: start, length: min(range.length, (text as NSString).length - start)))
            }
            if noteView?.string == text { savedItem = item }
            if let draftKey { store.easelDrafts.attach(self, for: draftKey) }
            setAccessibilityLabel("Note card")
        case .link(let title, let url): linkButton?.title = "↗  " + title; linkURL = url; linkButton?.toolTip = url; setAccessibilityLabel(title)
        case .image(let asset, _, _, let url, let title):
            savedItem = item
            imageContent?.configure(store: store, profile: context.profileID, asset: asset, isCurrent: { [weak self] in
                guard let self, self.isCurrent, let actual = self.owner?.context?.easel.items.first(where: { $0.id == self.itemID }),
                      case .image(let currentAsset, _, _, _, _) = actual.content else { return false }
                return currentAsset == asset
            })
            imageSource?.title = "↗  " + (title ?? url ?? "")
            imageSource?.toolTip = url; imageSource?.isHidden = url == nil
            imageSource?.setAccessibilityLabel(title ?? "Open image source")
            setAccessibilityLabel(title.map { "Image from " + $0 } ?? "Image card")
        }
        needsLayout = true; needsDisplay = true
    }
    override func layout() {
        super.layout()
        dragHandle.frame = NSRect(x: 8, y: 3, width: max(0, bounds.width - 28), height: 25)
        resizeHandle.frame = NSRect(x: bounds.width - 20, y: bounds.height - 20, width: 20, height: 20)
        textScroll.frame = NSRect(x: 12, y: 30, width: max(1, bounds.width - 24), height: max(1, bounds.height - 42))
        linkButton?.frame = NSRect(x: 16, y: 38, width: max(1, bounds.width - 32), height: max(1, bounds.height - 54))
        imageContent?.frame = NSRect(x: 12, y: 30, width: max(1, bounds.width - 24), height: max(1, bounds.height - (imageSource?.isHidden == false ? 60 : 42)))
        imageSource?.frame = NSRect(x: 12, y: bounds.height - 27, width: max(1, bounds.width - 36), height: 18)
        if let noteView { noteView.setFrameSize(NSSize(width: max(1, textScroll.contentSize.width), height: max(noteView.frame.height, textScroll.contentSize.height))) }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.withAlphaComponent(0.96).setFill()
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 12, yRadius: 12); shape.fill()
        (isSelected ? accent : NSColor.separatorColor).setStroke(); shape.lineWidth = isSelected ? 2 : 1; shape.stroke()
    }
    override func mouseDown(with event: NSEvent) { owner?.activate(); owner?.select(itemID, extending: event.modifierFlags.contains(.shift)); window?.makeFirstResponder(owner?.canvas) }
    func textDidBeginEditing(_ notification: Notification) { if isCurrent { owner?.select(itemID) } }
    func textDidChange(_ notification: Notification) {
        guard isCurrentScope, let owner, let store = owner.store, let noteView else { return }
        do {
            var original = savedItem
            if let current = owner.context?.easel.items.first(where: { $0.id == itemID }),
               case .note(let text) = current.content, text == lastSubmittedText { original = current }
            try store.easelDrafts.update(noteView.string, tabID: owner.tabID, itemID: itemID, from: store, original: original)
            lastSubmittedText = noteView.string
            if let draftKey { store.easelDrafts.attach(self, for: draftKey) }
        } catch { store.message = error.localizedDescription }
    }
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard let replacementString, let range = Range(affectedCharRange, in: textView.string) else { return replacementString == nil }
        return textView.string.replacingCharacters(in: range, with: replacementString).utf8.count <= 16384
    }
    func finishEaselDraftEditing() { noteView?.unmarkText() }
    @objc private func openLink() { if isCurrent, owner?.activate() == true, let linkURL, let url = URL(string: linkURL) { _ = owner?.store?.newTab(url: url) } }
    @objc private func openImageSource() {
        guard isCurrent, owner?.activate() == true, case .image(_, _, _, let source, _) = savedItem.content,
              let source, let url = URL(string: source) else { return }
        _ = owner?.store?.newTab(url: url)
    }
    func beginDrag(resizing: Bool) -> Bool { isCurrent && (owner?.beginGesture(itemID: itemID, resizing: resizing) ?? false) }
    func previewDrag(dx: Double, dy: Double) { owner?.previewGesture(dx: dx, dy: dy) }
    func endDrag() { _ = owner?.endGesture() }
}

@MainActor private final class EaselGestureHandle: NSView {
    weak var card: EaselCardView?
    private let resizing: Bool
    private var start: NSPoint?
    init(resizing: Bool) {
        self.resizing = resizing; super.init(frame: .zero)
        setAccessibilityRole(.button); setAccessibilityLabel(resizing ? "Resize card using the Size menu or drag" : "Move card using arrow keys or drag")
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        if resizing {
            NSColor.tertiaryLabelColor.setStroke()
            let grip = NSBezierPath(); grip.lineWidth = 1
            grip.move(to: NSPoint(x: 7, y: 16)); grip.line(to: NSPoint(x: 16, y: 7))
            grip.move(to: NSPoint(x: 11, y: 16)); grip.line(to: NSPoint(x: 16, y: 11)); grip.stroke()
        } else {
            ("⠿" as NSString).draw(at: NSPoint(x: 2, y: 5), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])
        }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: resizing ? .crosshair : .openHand) }
    override func mouseDown(with event: NSEvent) {
        if card?.beginDrag(resizing: resizing) == true { start = card?.superview?.convert(event.locationInWindow, from: nil) }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start, let canvas = card?.superview else { return }
        let point = canvas.convert(event.locationInWindow, from: nil)
        card?.previewDrag(dx: point.x - start.x, dy: point.y - start.y)
    }
    override func mouseUp(with event: NSEvent) { if start != nil { card?.endDrag() }; start = nil }
    override func accessibilityPerformPress() -> Bool { card?.beginDrag(resizing: resizing) ?? false }
}
