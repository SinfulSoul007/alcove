import AppKit
import SwiftUI
import WebKit
import BrowserCore

@MainActor private final class ProcessRecoveryDocument: NSView {
    override var isFlipped: Bool { true }
}
@MainActor private final class ProcessRecoveryReload: NSButton {
    private weak var recovery: WebsiteProcessRecovery?
    init(recovery: WebsiteProcessRecovery) {
        self.recovery = recovery
        super.init(frame: .zero)
        title = "Reload"; bezelStyle = .rounded
        identifier = NSUserInterfaceItemIdentifier("AlcoveWebsiteProcessReload")
        target = self; action = #selector(reloadPage)
        setAccessibilityLabel("Reload this page")
    }
    required init?(coder: NSCoder) { nil }
    @objc private func reloadPage() { recovery?.reload() }
}

/// Recovery is native chrome, independent of the unavailable website process.
/// Keep the real WKWebView mounted beneath it at its original full viewport.
@MainActor final class WebsiteProcessRecoveryOverlay: NSView {
    private let scroll = NSScrollView(), content = ProcessRecoveryDocument()
    private let icon = NSImageView(), heading = NSTextField(wrappingLabelWithString: "This page stopped responding")
    private let address = NSTextField(wrappingLabelWithString: ""), detail = NSTextField(wrappingLabelWithString: "Reload this tab to try again.")
    private var reload: ProcessRecoveryReload?
    private var recovery: WebsiteProcessRecovery?
    private var backgroundColor = NSColor.windowBackgroundColor
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier("AlcoveWebsiteProcessRecovery")
        scroll.documentView = content; scroll.drawsBackground = false
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.wantsLayer = true; scroll.layer?.cornerRadius = 16; scroll.layer?.masksToBounds = true
        addSubview(scroll)
        icon.image = NSImage(systemSymbolName: "arrow.clockwise.circle", accessibilityDescription: nil)
        content.addSubview(icon)
        for label in [heading, address, detail] { label.alignment = .center; content.addSubview(label) }
    }
    required init?(coder: NSCoder) { nil }

    func bind(store: BrowserStore, recovery: WebsiteProcessRecovery) {
        if self.recovery !== recovery {
            reload?.removeFromSuperview()
            let button = ProcessRecoveryReload(recovery: recovery)
            reload = button; content.addSubview(button)
        }
        self.recovery = recovery
        let theme = store.activeTheme, scale = CGFloat(store.appearance.normalized.textScale)
        backgroundColor = NSColor(theme.background)
        scroll.layer?.backgroundColor = NSColor(theme.selected).cgColor
        for label in [heading, address, detail] { label.textColor = NSColor(theme.ink) }
        heading.font = .systemFont(ofSize: 21 * scale, weight: .semibold)
        address.font = .systemFont(ofSize: 12 * scale, weight: .medium)
        detail.font = .systemFont(ofSize: 13 * scale)
        address.stringValue = recovery.address?.host ?? "This tab"
        icon.contentTintColor = NSColor(theme.accent)
        icon.symbolConfiguration = .init(pointSize: 34 * scale, weight: .regular)
        reload?.font = .systemFont(ofSize: 13 * scale, weight: .medium)
        reload?.bezelColor = NSColor(theme.accent)
        let buttonInk = NSColor(ThemeColor.readableForeground(over: [theme.palette.resolvedForDisplay.accent]).color)
        if let reload, let font = reload.font {
            reload.attributedTitle = NSAttributedString(string: "Reload", attributes: [.font: font, .foregroundColor: buttonInk])
        }
        needsLayout = true; needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) { backgroundColor.setFill(); bounds.fill() }
    override func layout() {
        super.layout()
        let width = max(0, min(400, bounds.width - 24)), inner = max(1, width - 40)
        var y: CGFloat = 24
        let iconSize = max(40, (heading.font?.pointSize ?? 21) * 2)
        icon.frame = NSRect(x: (width - iconSize) / 2, y: y, width: iconSize, height: iconSize)
        y += iconSize + 16
        for label in [heading, address, detail] {
            let font = label.font ?? .systemFont(ofSize: 13)
            let height = ceil((label.stringValue as NSString).boundingRect(with: NSSize(width: inner, height: 10000), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).height) + 4
            label.frame = NSRect(x: 20, y: y, width: inner, height: height)
            y += height + 10
        }
        let buttonHeight = max(32, (reload?.font?.pointSize ?? 13) + 16)
        reload?.frame = NSRect(x: 20, y: y + 4, width: inner, height: buttonHeight)
        y += buttonHeight + 28
        content.frame = NSRect(x: 0, y: 0, width: width, height: y)
        let height = min(y, max(0, bounds.height - 24))
        scroll.frame = NSRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
    }
}
