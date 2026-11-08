import AppKit
import SwiftUI
import WebKit
import Combine
import BrowserCore

@MainActor final class LayoutFixtureWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var mouseLocationOutsideOfEventStream: NSPoint { NSPoint(x: -1000, y: -1000) }
}

/// Own-process layout work only; no window is shown and no user app or input device is operated.
@main struct LayoutBench {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited); setbuf(stdout, nil)
        let destination = URL(fileURLWithPath: CommandLine.arguments[1])
        let suiteName = "Alcove.LayoutBench.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(236.0, forKey: "sidebarWidth")
        let store = BrowserStore(isPrivate: true)
        defer { store.shutdown() }
        store.onboardingVisible = false
        let pageID = store.selectedID!
        store.update(pageID) { $0.url = "about:blank"; $0.title = "Layout fixture" }
        store.session.spaces[0].tabs += (1...48).map { BrowserCore.Tab(title: "Reading and research tab \($0)", url: "about:blank") }
        let web = store.view(for: pageID)
        let host = NSHostingView(rootView: BrowserUI(store: store, sidebarDefaults: defaults).environmentObject(UpdateController(installedTag: "layout-fixture")))
        host.safeAreaRegions = []; host.sizingOptions = []
        let window = LayoutFixtureWindow(contentRect: NSRect(x: 0, y: 0, width: 1260, height: 820), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        func pump(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)); host.layoutSubtreeIfNeeded() }
        func grips(_ view: NSView) -> [SidebarResizeHandle.Handle] {
            (view as? SidebarResizeHandle.Handle).map { [$0] } ?? view.subviews.flatMap(grips)
        }
        func mouse(_ kind: NSEvent.EventType, x: Double) -> NSEvent {
            NSEvent.mouseEvent(with: kind, location: NSPoint(x: x, y: 100), modifierFlags: [], timestamp: 0,
                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        }
        var rows = ["action,text_scale,sample,synchronous_ms,settled_ms,web_width"]
        var samples: [String: [Double]] = [:]
        func measure(_ action: String, scale: Double, index: Int, operation: () -> Void) throws {
            let start = ProcessInfo.processInfo.systemUptime
            operation(); host.layoutSubtreeIfNeeded()
            let synchronous = ProcessInfo.processInfo.systemUptime - start
            pump(0.005)
            let settled = ProcessInfo.processInfo.systemUptime - start
            guard store.views[pageID] === web, web.window === window else { throw CocoaError(.coderInvalidValue) }
            let key = "\(action) / text\(scale)"
            samples[key, default: []].append(synchronous * 1000)
            rows.append("\(action),\(scale),\(index),\(synchronous*1000),\(settled*1000),\(web.bounds.width)")
        }
        for scale in [1.0, 1.35] {
            var appearance = store.appearance; appearance.textScale = scale; appearance.animationsEnabled = false
            store.appearance = appearance; store.sidebarVisible = true; defaults.set(236.0, forKey: "sidebarWidth")
            window.setContentSize(NSSize(width: 1260, height: 820)); pump(0.5)
            var publications = 0
            let subscription = store.objectWillChange.sink { publications += 1 }
            for index in 0..<40 {
                let phase = Double(index) * .pi / 20
                try measure("window_resize", scale: scale, index: index) {
                    window.setContentSize(NSSize(width: 1020 + 220 * sin(phase), height: 680 + 100 * cos(phase)))
                }
            }
            print("OBSERVED window-resize store publications / text\(scale):", publications)
            guard publications == 0 else { throw CocoaError(.coderInvalidValue) }
            guard let grip = grips(host).first else { throw CocoaError(.coderInvalidValue) }
            let origin = grip.convert(grip.bounds, to: nil).midX
            grip.mouseDown(with: mouse(.leftMouseDown, x: origin)); pump(0.02)
            for index in 1...30 {
                try measure("sidebar_drag", scale: scale, index: index) {
                    grip.mouseDragged(with: mouse(.leftMouseDragged, x: origin + Double(index) * 3))
                }
            }
            grip.mouseUp(with: mouse(.leftMouseUp, x: origin + 90)); pump(0.02)
            guard defaults.double(forKey: "sidebarWidth") == 326 else { throw CocoaError(.coderInvalidValue) }
            subscription.cancel()
        }
        try (rows.joined(separator: "\n") + "\n").write(to: destination, atomically: true, encoding: .utf8)
        print("SOURCE own hosted chrome,49 tabs,empty nonpersistent web page,animations off,5ms event-pump after synchronous measurement")
        print("OS", ProcessInfo.processInfo.operatingSystemVersionString)
        for key in samples.keys.sorted() {
            let values = samples[key]!.sorted()
            print(String(format: "%@ n=%d synchronous p50=%.3fms p95=%.3fms max=%.3fms", key, values.count, values[values.count/2], values[Int(Double(values.count-1)*0.95)], values.last!))
        }
        print("This does not measure compositor frames, live dragging, animation, loaded-page work, energy or Safari comparisons.")
    }
}
