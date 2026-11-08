import AppKit
import SwiftUI

/// AppKit owns the traffic lights. SwiftUI follows their measured layout.
@MainActor final class NativeWindowChrome: ObservableObject {
    private struct Layout: Equatable {
        var height: CGFloat = 40
        var leadingEdge: CGFloat = 81
    }
    @Published private var layout = Layout()
    var height: CGFloat { layout.height }
    /// Window-content x coordinate where the first custom control may start.
    var leadingEdge: CGFloat { layout.leadingEdge }
    private weak var window: NSWindow?
    private var observations: [NSObjectProtocol] = []
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
        content.superview?.layoutSubtreeIfNeeded()
        guard let close = window.standardWindowButton(.closeButton) else { return }
        let bounds = close.convert(close.bounds, to: content)
        let center = content.isFlipped ? bounds.midY - content.bounds.minY : content.bounds.maxY - bounds.midY
        // A fullscreen titlebar may temporarily be outside the content bounds.
        // Keep its last usable layout until AppKit finishes that transition.
        guard center.isFinite, (16...64).contains(center) else { return }
        let right = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap {
            window.standardWindowButton($0).map { $0.convert($0.bounds, to: content).maxX }
        }.max() ?? bounds.maxX
        let next = Layout(height: center * 2, leadingEdge: right + 16)
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
