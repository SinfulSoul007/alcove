import AppKit
import SwiftUI
import WebKit
import Combine
import BrowserCore

@MainActor final class ChromeFixtureWindow: NSWindow {
    var fixtureKey = false
    var pointer = NSPoint(x: -1000, y: -1000)
    override var isKeyWindow: Bool { fixtureKey }
    override var mouseLocationOutsideOfEventStream: NSPoint { pointer }
}

/// Actual SwiftUI rows in owned, never-shown windows. No real profile or device access.
@main struct ChromeChecks {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        setbuf(stdout, nil)
        var failures = 0
        func check(_ ok: Bool, _ name: String) {
            print("\(ok ? "PASS" : "FAIL"): \(name)")
            if !ok { failures += 1 }
        }
        func settle() async {
            for _ in 0..<12 { try? await Task.sleep(for: .milliseconds(10)) }
        }
        func hosts(_ view: NSView) -> [NativeChromeReader.Host] {
            (view as? NativeChromeReader.Host).map { [$0] } ?? view.subviews.flatMap(hosts)
        }
        func aligned(_ w: NSWindow) -> Bool {
            guard let content = w.contentView, let close = w.standardWindowButton(.closeButton) else { return false }
            let native = close.convert(close.bounds, to: nil)
            let visible = hosts(content).filter {
                let rect = $0.convert($0.bounds, to: nil)
                return rect.height > 30 && rect.minX >= -0.5 && rect.intersects(content.convert(content.bounds, to: nil))
            }
            let result = visible.count == 1 && visible.allSatisfy { abs($0.convert($0.bounds, to: nil).midY - native.midY) <= 0.5 }
            if !result { print("Geometry:", "native", native, "rows", visible.map { $0.convert($0.bounds, to: nil) }) }
            return result
        }
        func newWindow(width: CGFloat = 1260, height: CGFloat = 820) -> ChromeFixtureWindow {
            let w = ChromeFixtureWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false; w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden
            return w
        }
        func toolbarFits(_ w: NSWindow) -> Bool {
            guard let content = w.contentView else { return false }
            func menus(_ view: NSView) -> [NSPopUpButton] {
                (view as? NSPopUpButton).map { [$0] } ?? view.subviews.flatMap(menus)
            }
            let bounds = content.convert(content.bounds, to: nil)
            let rows = hosts(content).filter { $0.bounds.height > 30 }
            let buttons = menus(content)
            return rows.count == 1 && rows.allSatisfy {
                let rect = $0.convert($0.bounds, to: nil)
                return rect.minX >= bounds.minX - 0.5 && rect.maxX <= bounds.maxX + 0.5
            } && !buttons.isEmpty && buttons.allSatisfy {
                let rect = $0.convert($0.bounds, to: nil)
                return rect.width >= 20 && rect.minX >= bounds.minX && rect.maxX <= bounds.maxX
            }
        }
        let store = BrowserStore(isPrivate: true)
        let suiteName = "Alcove.ChromeChecks.\(UUID().uuidString)"
        let sidebarDefaults = UserDefaults(suiteName: suiteName)!
        defer { sidebarDefaults.removePersistentDomain(forName: suiteName) }
        sidebarDefaults.set(236.0, forKey: "sidebarWidth")
        store.onboardingVisible = false
        var a = store.appearance; a.animationsEnabled = false; store.appearance = a
        let pageID = store.selectedID!
        store.update(pageID) { $0.url = "about:blank" }
        let web = store.view(for: pageID)
        let hosting = NSHostingView(rootView: BrowserUI(store: store, sidebarDefaults: sidebarDefaults).environmentObject(UpdateController(installedTag: "test")))
        hosting.safeAreaRegions = []; hosting.sizingOptions = []
        let main = newWindow(); main.contentView = hosting
        await settle()
        check(aligned(main), "Primary navigation shares the actual native traffic-light baseline")
        check(main.toolbarStyle == .unifiedCompact && main.toolbar?.allowsUserCustomization == false, "Chrome uses the native compact toolbar without a customization surface")
        let close = main.standardWindowButton(.closeButton)!
        check(close.superview !== hosting && close.window === main && close.target != nil, "Native window buttons retain their AppKit parent and action target")
        for density in SidebarDensity.allCases {
            for scale in [0.85, 1.35] {
                a.density = density; a.textScale = scale; store.appearance = a
                main.setContentSize(NSSize(width: scale == 1.35 ? 800 : 1260, height: scale == 1.35 ? 540 : 820))
                hosting.layoutSubtreeIfNeeded(); await settle()
                check(aligned(main), "Primary row stays aligned for \(density.rawValue) density at text \(scale)")
            }
        }
        store.sidebarVisible = false; await settle()
        check(aligned(main), "Collapsed-sidebar navigation aligns in root coordinates rather than the inset web surface")
        store.sidebarVisible = true; store.setTheme(.midnight); await settle()
        check(aligned(main) && store.views[pageID] === web && web.window === main, "Showing the sidebar and changing theme keeps the same mounted website")
        if let content = main.contentView, let root = content.superview {
            let webBounds = web.convert(web.bounds, to: nil)
            let sample = root.convert(NSPoint(x: webBounds.midX, y: webBounds.maxY - 3), from: nil)
            let hit = root.hitTest(sample)
            if !(hit === web || hit?.isDescendant(of: web) == true) {
                print("Web hit geometry:", webBounds, "hit", hit.map { String(describing: type(of: $0)) } ?? "nil")
            }
            check(hit === web || hit?.isDescendant(of: web) == true, "Transparent native toolbar preserves clicks at the top of the web surface")
        } else { check(false, "Top-of-page hit-test fixture is mounted") }
        check(hosts(hosting).allSatisfy { $0.hitTest(.zero) == nil }, "Native geometry readers never intercept input")
        var invalidations = 0
        let subscription = store.objectWillChange.sink { invalidations += 1 }
        main.setContentSize(NSSize(width: 1100, height: 720)); await settle()
        check(invalidations == 0 && aligned(main), "Native resize updates geometry without publishing browser-state changes")
        subscription.cancel()

        func tracking(_ view: NSView) -> [SidebarTracking.Host] {
            (view as? SidebarTracking.Host).map { [$0] } ?? view.subviews.flatMap(tracking)
        }
        func floatingVisible() -> Bool {
            tracking(hosting).contains {
                let rect = $0.convert($0.bounds, to: nil)
                return rect.width > 16 && rect.minX >= -0.5 && rect.intersects(hosting.convert(hosting.bounds, to: nil))
            }
        }
        store.sidebarVisible = false; main.fixtureKey = true; main.pointer = NSPoint(x: 4, y: 100)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: main)
        await settle(); await settle()
        check(floatingVisible() && store.views[pageID] === web && web.window === main,
              "The actual browser root reveals its floating sidebar while preserving the mounted website")
        if let root = hosting.superview {
            let frame = web.convert(web.bounds, to: nil)
            let hit = root.hitTest(root.convert(NSPoint(x: frame.midX, y: frame.maxY - 3), from: nil))
            check(hit === web || hit?.isDescendant(of: web) == true, "Floating-sidebar tracking preserves page clicks outside the panel")
        } else { check(false, "Floating page hit-test fixture is mounted") }
        store.commandVisible = true; await settle()
        check(!floatingVisible(), "The actual command overlay suppresses floating sidebar reveal")
        store.commandVisible = false; await settle(); await settle()
        check(floatingVisible(), "Closing the command overlay restores edge tracking for a stationary pointer")
        main.pointer = NSPoint(x: 600, y: 100)
        tracking(hosting).forEach { $0.updateTrackingAreas() }
        await settle(); await settle(); await settle()
        check(!floatingVisible() && store.views[pageID] === web, "Leaving the actual floating panel hides it without replacing its website")
        main.fixtureKey = false; store.sidebarVisible = true; await settle()

        func grips(_ view: NSView) -> [SidebarResizeHandle.Handle] {
            (view as? SidebarResizeHandle.Handle).map { [$0] } ?? view.subviews.flatMap(grips)
        }
        func mouse(_ kind: NSEvent.EventType, x: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: kind, location: NSPoint(x: x, y: 100), modifierFlags: [], timestamp: 0,
                               windowNumber: main.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        }
        for pinned in [true, false] {
            for overlay in ["Peek", "command", "onboarding"] {
                store.closePrimaryPeek(); store.commandVisible = false; store.onboardingVisible = false
                sidebarDefaults.set(236.0, forKey: "sidebarWidth"); store.sidebarVisible = pinned
                main.fixtureKey = true; main.pointer = NSPoint(x: 4, y: 100)
                NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: main)
                await settle(); await settle()
                guard let grip = grips(hosting).first else { check(false, "Actual browser resize grip exists"); continue }
                let origin = grip.convert(grip.bounds, to: nil).midX
                main.pointer = NSPoint(x: origin + 25, y: 100)
                grip.mouseDown(with: mouse(.leftMouseDown, x: origin))
                grip.mouseDragged(with: mouse(.leftMouseDragged, x: origin + 25)); await settle()
                check(grip.convert(grip.bounds, to: nil).midX > origin + 20 && sidebarDefaults.double(forKey: "sidebarWidth") == 236,
                      "Actual \(pinned ? "pinned" : "floating") resizing is available before the \(overlay) overlay and remains transient")
                switch overlay {
                case "Peek": store.openPeek(URL(string: "about:blank")!, from: web)
                case "command": store.commandVisible = true
                default: store.onboardingVisible = true
                }
                await settle()
                check(!grip.cancelResize(), "The \(overlay) overlay proactively cancels the native \(pinned ? "pinned" : "floating") gesture before late input")
                grip.mouseDragged(with: mouse(.leftMouseDragged, x: origin + 60))
                grip.mouseUp(with: mouse(.leftMouseUp, x: origin + 60)); await settle()
                check(sidebarDefaults.double(forKey: "sidebarWidth") == 236,
                      "The actual \(overlay) overlay revokes \(pinned ? "pinned" : "floating") resizing before late input can save a width")
                grip.cancelResize()
            }
        }
        store.closePrimaryPeek(); store.commandVisible = false; store.onboardingVisible = false
        store.sidebarVisible = true; main.fixtureKey = false; await settle()
        // Inspect the same production gate without presenting a native sheet from a hidden test window.
        let sheetStore = BrowserStore(isPrivate: true)
        let sheetView = BrowserUI(store: sheetStore, sidebarDefaults: sidebarDefaults)
        for pinned in [true, false] {
            sheetStore.sidebarVisible = pinned; sheetStore.presentedPanel = .library
            check(sheetView.sidebarInteractionBlocked, "A presented sheet blocks the production \(pinned ? "pinned" : "floating") sidebar-interaction gate")
        }
        sheetStore.shutdown()

        let owner = BrowserWindowOwner(store: store); let primaryLease = try owner.acquirePrimary()
        // Register a real nonpersistent native view before mounting the HTTP metadata;
        // view(for:) then reuses it without making any external request.
        let quickID = try store.openQuickPage(url: URL(string: "https://chrome.example.invalid"), configuration: WKWebViewConfiguration())
        let controller = try QuickBrowseWindowController(owner: owner, pageID: quickID, requestPrimary: {}, requestProfiles: {}, didClose: {})
        let quick = controller.window!; await settle()
        check(aligned(quick), "Quick Browse uses the same native baseline as the primary window")
        let quickWeb = store.views[quickID]
        for density in SidebarDensity.allCases {
            for scale in [0.85, 1.35] {
                a.density = density; a.textScale = scale; store.appearance = a
                quick.setContentSize(NSSize(width: scale == 1.35 ? 480 : 760, height: 420)); await settle()
                check(aligned(quick) && store.views[quickID] === quickWeb && quickWeb?.window === quick,
                      "Quick Browse preserves native alignment and its website for \(density.rawValue) density at text \(scale)")
                check(toolbarFits(quick), "Quick Browse keeps its action menus visible inside the window for \(density.rawValue) density at text \(scale)")
            }
        }
        let chrome = NativeWindowChrome()
        let nativeHost = NativeChromeReader.Host(chrome: chrome)
        var oldWindow: NSWindow? = newWindow()
        weak var releasedWindow: NSWindow?
        releasedWindow = oldWindow
        oldWindow?.contentView = nativeHost; await settle()
        let next = newWindow(width: 800, height: 540)
        oldWindow?.contentView = nil; next.contentView = nativeHost
        oldWindow?.close(); oldWindow = nil; await settle()
        check(releasedWindow == nil, "Moving a chrome reader detaches old observations and releases its previous window")
        let nativeRight = next.standardWindowButton(.zoomButton)!.convert(next.standardWindowButton(.zoomButton)!.bounds, to: next.contentView).maxX
        check(chrome.leadingEdge >= nativeRight + 16 && chrome.height >= 32, "Measured leading space clears the native controls and preserves a usable toolbar")
        var chromeChanges = 0
        let changes = chrome.objectWillChange.sink { chromeChanges += 1 }
        for _ in 0..<30 { chrome.scheduleMeasurement() }
        await settle()
        check(chromeChanges == 0, "Repeated unchanged native layout notifications do not invalidate SwiftUI")
        changes.cancel()
        next.contentView = nil; next.close()
        quick.close(); main.contentView = nil; main.close(); owner.release(primaryLease)
        if failures > 0 {
            // exit bypasses defer; remove only this test's unique preference domain.
            sidebarDefaults.removePersistentDomain(forName: suiteName)
            exit(1)
        }
    }
}
