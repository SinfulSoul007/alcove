import AppKit
import SwiftUI
import BrowserCore

struct EaselDrawingToolbar: NSViewRepresentable {
    @ObservedObject var canvas: EaselCanvasView
    func makeNSView(context: Context) -> EaselDrawingControls { EaselDrawingControls(canvas: canvas) }
    func updateNSView(_ view: EaselDrawingControls, context: Context) { view.update() }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: EaselDrawingControls, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 320, height: 36)
    }
}

/// All actions remain in the overflow menu, including in very narrow split panes.
@MainActor final class EaselDrawingControls: NSView {
    private weak var canvas: EaselCanvasView?
    private(set) var toolButtons: [NSButton] = []
    let overflow = NSPopUpButton(frame: .zero, pullsDown: true)
    private let colorWell = NSColorWell()
    private let colors: [(String, String)] = [
        ("Black", "#161820"), ("White", "#FFFFFF"), ("Blue", "#3466CC"),
        ("Red", "#DB3945"), ("Orange", "#E7802C"), ("Yellow", "#D6AD15"),
        ("Green", "#278757"), ("Teal", "#16898D"), ("Purple", "#8653BC"), ("Pink", "#C94786")
    ]
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 36) }
    init(canvas: EaselCanvasView) {
        self.canvas = canvas
        super.init(frame: .zero)
        for (index, tool) in EaselCanvasTool.allCases.enumerated() {
            let button = NSButton(image: NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.title)!, target: self, action: #selector(chooseTool(_:)))
            button.tag = index; button.setButtonType(.toggle); button.bezelStyle = .texturedRounded
            button.controlSize = .small; button.imagePosition = .imageOnly
            button.toolTip = tool.title; button.setAccessibilityLabel(tool.title + " tool")
            toolButtons.append(button); addSubview(button)
        }
        colorWell.target = self; colorWell.action = #selector(chooseColor(_:))
        colorWell.setAccessibilityLabel("Drawing ink color"); colorWell.toolTip = "Ink color"
        addSubview(colorWell)
        overflow.bezelStyle = .texturedRounded; overflow.controlSize = .small
        overflow.setAccessibilityLabel("Drawing tools and style"); overflow.toolTip = "All drawing tools, colors, thickness and opacity"
        addSubview(overflow); update()
    }
    required init?(coder: NSCoder) { nil }
    func update() {
        guard let canvas else { return }
        let valid = canvas.canUseDrawingControls
        let writable = valid && canvas.store?.canModifyLocalMetadata == true
        for (index, button) in toolButtons.enumerated() {
            let tool = EaselCanvasTool.allCases[index]
            button.state = canvas.drawingTool == tool ? .on : .off
            button.isEnabled = tool == .select ? valid : writable
        }
        let value = canvas.drawingStyle
        colorWell.color = NSColor(srgbRed: Double(Int(value.color.dropFirst().prefix(2), radix: 16)!) / 255,
                                  green: Double(Int(value.color.dropFirst(3).prefix(2), radix: 16)!) / 255,
                                  blue: Double(Int(value.color.suffix(2), radix: 16)!) / 255, alpha: 1)
        colorWell.isEnabled = writable
        let menu = NSMenu(); menu.autoenablesItems = false
        menu.addItem(NSMenuItem(title: canvas.drawingTool.title, action: nil, keyEquivalent: ""))
        for (index, tool) in EaselCanvasTool.allCases.enumerated() {
            let item = NSMenuItem(title: tool.title, action: #selector(chooseTool(_:)), keyEquivalent: "")
            item.target = self; item.tag = index; item.state = canvas.drawingTool == tool ? .on : .off
            item.isEnabled = tool == .select ? valid : writable
            item.image = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.title)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let palette = NSMenu(); palette.autoenablesItems = false
        for (title, color) in colors {
            let item = NSMenuItem(title: title, action: #selector(choosePalette(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = color; item.state = color == value.color ? .on : .off
            item.isEnabled = writable; palette.addItem(item)
        }
        let custom = NSMenuItem(title: "Choose Ink Color…", action: #selector(openColorPanel(_:)), keyEquivalent: "")
        custom.target = self; custom.isEnabled = writable; palette.addItem(custom)
        let colorItem = NSMenuItem(title: "Ink Color", action: nil, keyEquivalent: ""); colorItem.submenu = palette; menu.addItem(colorItem)
        let widths = NSMenu(); widths.autoenablesItems = false
        for width in [1, 2, 4, 8, 16, 32] {
            let item = NSMenuItem(title: "\(width) pt", action: #selector(chooseWidth(_:)), keyEquivalent: "")
            item.target = self; item.tag = width; item.state = value.lineWidth == Double(width) ? .on : .off
            item.isEnabled = writable; widths.addItem(item)
        }
        let widthItem = NSMenuItem(title: "Thickness", action: nil, keyEquivalent: ""); widthItem.submenu = widths; menu.addItem(widthItem)
        let opacities = NSMenu(); opacities.autoenablesItems = false
        for opacity in [10, 25, 50, 75, 100] {
            let item = NSMenuItem(title: "\(opacity)%", action: #selector(chooseOpacity(_:)), keyEquivalent: "")
            item.target = self; item.tag = opacity; item.state = value.opacity == Double(opacity) / 100 ? .on : .off
            item.isEnabled = writable; opacities.addItem(item)
        }
        let opacityItem = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: ""); opacityItem.submenu = opacities; menu.addItem(opacityItem)
        overflow.menu = menu; overflow.isEnabled = valid
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let width = max(0, bounds.width), full = width >= 286
        for (i, button) in toolButtons.enumerated() {
            button.isHidden = !full; button.frame = NSRect(x: 8 + Double(i) * 32, y: 4, width: 28, height: 28)
        }
        let showColor = width >= 88
        colorWell.isHidden = !showColor
        let menuX = full ? 244.0 : 8.0
        let menuWidth = max(0, full ? 34 : min(140, width - 16 - (showColor ? 32 : 0)))
        overflow.frame = NSRect(x: min(8, width), y: 4, width: menuWidth, height: 28)
        if full { overflow.frame.origin.x = menuX }
        colorWell.frame = NSRect(x: full ? 208 : 8 + menuWidth + 6, y: 5, width: 26, height: 26)
        if let first = overflow.menu?.items.first, let canvas {
            first.title = full || width < 140 ? "" : canvas.drawingTool.title
            first.image = NSImage(systemSymbolName: full ? "slider.horizontal.3" : canvas.drawingTool.symbol, accessibilityDescription: "Drawing tools and style")
        }
    }
    @objc private func chooseTool(_ sender: Any) {
        let index = (sender as? NSButton)?.tag ?? (sender as? NSMenuItem)?.tag ?? -1
        guard EaselCanvasTool.allCases.indices.contains(index), let canvas else { return }
        _ = canvas.setDrawingTool(EaselCanvasTool.allCases[index]); update()
    }
    private func style(color: String? = nil, width: Double? = nil, opacity: Double? = nil) {
        guard let canvas else { return }
        if let style = try? EaselDrawingStyle(color: color ?? canvas.drawingStyle.color, lineWidth: width ?? canvas.drawingStyle.lineWidth, opacity: opacity ?? canvas.drawingStyle.opacity) {
            _ = canvas.setDrawingStyle(style)
        }
        update()
    }
    @objc private func chooseWidth(_ item: NSMenuItem) { style(width: Double(item.tag)) }
    @objc private func chooseOpacity(_ item: NSMenuItem) { style(opacity: Double(item.tag) / 100) }
    @objc private func choosePalette(_ item: NSMenuItem) { style(color: item.representedObject as? String) }
    @objc private func openColorPanel(_ sender: Any?) {
        guard canvas?.canUseDrawingControls == true, canvas?.store?.canModifyLocalMetadata == true else { return }
        colorWell.activate(true)
    }
    @objc private func chooseColor(_ sender: NSColorWell) {
        guard let color = sender.color.usingColorSpace(.sRGB) else { return }
        func byte(_ value: CGFloat) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }
        style(color: String(format: "#%02X%02X%02X", byte(color.redComponent), byte(color.greenComponent), byte(color.blueComponent)))
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { colorWell.deactivate() }
    }
}
