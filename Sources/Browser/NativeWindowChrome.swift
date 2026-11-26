import AppKit
import SwiftUI

/// AppKit owns the traffic lights. SwiftUI follows their measured layout.
@MainActor final class NativeWindowChrome: ObservableObject {
    private struct Layout: Equatable {
        var height: CGFloat = 40
        var leadingEdge: CGFloat = 81
        var pageTopInset: CGFloat = 0
    }
    @Published private var layout = Layout()
    var height: CGFloat { layout.height }
    /// Window-content x coordinate where the first custom control may start.
    var leadingEdge: CGFloat { layout.leadingEdge }
    var pageTopInset: CGFloat { layout.pageTopInset }
    private weak var window: NSWindow?
    private let ownedToolbars = NSHashTable<NSToolbar>.weakObjects()
    private var observations: [NSObjectProtocol] = []
    private var contentLayoutObservation: NSKeyValueObservation?
    private var measurementScheduled = false

    func attach(to window: NSWindow) {
        guard self.window !== window else { scheduleMeasurement(); return }
        observations.forEach(NotificationCenter.default.removeObserver)
        observations.removeAll()
        self.window = window
        // Borderless owned render fixtures have no native titlebar to configure.
        if window.styleMask.contains(.titled) {
            if window.toolbar == nil {
                let toolbar = NSToolbar(identifier: "AlcoveNativeChrome")
                toolbar.allowsUserCustomization = false
                toolbar.autosavesConfiguration = false
                ownedToolbars.add(toolbar)
                window.toolbar = toolbar
            }
            window.toolbarStyle = .unifiedCompact
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.titlebarSeparatorStyle = .none
        }
        for name in [NSWindow.didResizeNotification, NSWindow.didChangeBackingPropertiesNotification,
                     NSWindow.didChangeScreenNotification, NSWindow.didEnterFullScreenNotification,
                     NSWindow.didExitFullScreenNotification] {
            observe(name, object: window)
        }
        contentLayoutObservation = window.observe(\.contentLayoutRect, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.scheduleMeasurement() }
        }
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            if let button = window.standardWindowButton(type) {
                button.postsFrameChangedNotifications = true
                observe(NSView.frameDidChangeNotification, object: button)
            }
        }
        scheduleMeasurement()
    }

    private func observe(_ name: Notification.Name, object: AnyObject) {
        observations.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleMeasurement() }
        })
    }

    func scheduleMeasurement() {
        guard !measurementScheduled else { return }
        measurementScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.measure()
            self.measurementScheduled = false
        }
    }

    private func measure() {
        guard let window, let content = window.contentView else { return }
        // The empty native toolbar supplies normal-window traffic-light
        // geometry, but becomes an opaque overlay in fullscreen. Only manage
        // toolbars created here; callers can supply their own visible/hidden UI.
        if let toolbar = window.toolbar, ownedToolbars.contains(toolbar) {
            let visible = !window.styleMask.contains(.fullScreen)
            if toolbar.isVisible != visible { toolbar.isVisible = visible }
        }
        content.superview?.layoutSubtreeIfNeeded()
        var next = layout
        let usable = content.convert(window.contentLayoutRect, from: nil)
        let inset = content.isFlipped ? usable.minY - content.bounds.minY : content.bounds.maxY - usable.maxY
        if inset.isFinite { next.pageTopInset = max(0, min(content.bounds.height, inset)) }
        if let close = window.standardWindowButton(.closeButton) {
            let bounds = close.convert(close.bounds, to: content)
            let center = content.isFlipped ? bounds.midY - content.bounds.minY : content.bounds.maxY - bounds.midY
            // Traffic lights can temporarily leave the content bounds in fullscreen.
            if center.isFinite, (16...64).contains(center) {
                let right = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap {
                    window.standardWindowButton($0).map { $0.convert($0.bounds, to: content).maxX }
                }.max() ?? bounds.maxX
                next.height = center * 2
                next.leadingEdge = right + 16
            }
        }
        if layout != next { layout = next }
    }

    deinit { observations.forEach(NotificationCenter.default.removeObserver) }
}

/// A transparent background in an actual navigation row, never an input overlay.
struct NativeChromeReader: NSViewRepresentable {
    let chrome: NativeWindowChrome
    final class Host: NSView {
        let chrome: NativeWindowChrome
        init(chrome: NativeWindowChrome) { self.chrome = chrome; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("Use init(chrome:)") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { chrome.attach(to: window) }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() { super.layout(); chrome.scheduleMeasurement() }
    }
    func makeNSView(context: Context) -> Host { Host(chrome: chrome) }
    func updateNSView(_ view: Host, context: Context) { if let window = view.window { chrome.attach(to: window) } }
}
