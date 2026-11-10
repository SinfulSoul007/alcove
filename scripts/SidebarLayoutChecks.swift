import AppKit
import SwiftUI
import WebKit
import Combine
import BrowserCore

@MainActor final class SidebarViewportWindow: NSWindow {
    var fixtureKey = true
    var pointer = NSPoint(x: -1000, y: -1000)
    override var isKeyWindow: Bool { fixtureKey }
    override var mouseLocationOutsideOfEventStream: NSPoint { pointer }
}

/// Actual production root in an owned, never-shown window. No user profile or desktop control.
@main struct SidebarLayoutChecks {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        setbuf(stdout, nil)
        var failures = 0
        func check(_ ok: Bool, _ name: String) {
            print("\(ok ? "PASS" : "FAIL"): \(name)")
            if !ok { failures += 1 }
        }
        func settle() async { for _ in 0..<12 { try? await Task.sleep(for: .milliseconds(10)) } }
        func descendants<T: NSView>(_ root: NSView, _ type: T.Type) -> [T] {
            (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants($0, type) }
        }
        let store = BrowserStore(isPrivate: true)
        store.onboardingVisible = false
        var appearance = store.appearance; appearance.animationsEnabled = false; store.appearance = appearance
        let suite = "Alcove.SidebarLayoutChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(236.0, forKey: "sidebarWidth")
        let pageID = store.selectedID!
        store.update(pageID) { $0.url = "about:blank" }
        let web = store.view(for: pageID)
        let hosting = NSHostingView(rootView: BrowserUI(store: store, sidebarDefaults: defaults)
            .environmentObject(UpdateController(installedTag: "test")))
        hosting.safeAreaRegions = []; hosting.sizingOptions = []
        let window = SidebarViewportWindow(contentRect: NSRect(x: 0, y: 0, width: 1260, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.contentView = hosting
        await settle()
        web.loadHTMLString("<input id='owned' value='before'><div style='height:6000px'></div>", baseURL: nil)
        for _ in 0..<200 { if !web.isLoading { break }; try? await Task.sleep(for: .milliseconds(20)) }
        _ = try await web.evaluateJavaScript("document.getElementById('owned').value='kept'; window.scrollTo(0,600)")
        await settle()
        for crowded in [false, true] {
            var library = store.library
            library.favoriteTabs = crowded ? (0..<24).map { index in
                var tab = BrowserCore.Tab(title: "Favorite \(index)", url: "about:blank", pinned: true)
                tab.favorite = true; return tab
            } : []
            store.library = library
            if crowded {
                store.session.spaces[store.spaceIndex].tabs += (0..<40).map {
                    BrowserCore.Tab(title: "Owned row \($0)", url: "about:blank", pinned: $0 < 10)
                }
            }
            for scale in [1.0, 1.35] {
                appearance.textScale = scale; store.appearance = appearance
                for size in [NSSize(width: 1260, height: 820), NSSize(width: 960, height: 494), NSSize(width: 760, height: 400)] {
                    var publications = 0
                    let subscription = store.objectWillChange.sink { publications += 1 }
                    window.setContentSize(size); hosting.layoutSubtreeIfNeeded(); await settle()
                    let bounds = hosting.convert(hosting.bounds, to: nil)
                    let menus = descendants(hosting, NSPopUpButton.self)
                    let rects = menus.map { $0.convert($0.bounds, to: nil) }
                    let inside = rects.count >= 2 && rects.allSatisfy {
                        $0.width > 0 && $0.height > 0 && $0.minX >= bounds.minX - 0.5 && $0.maxX <= bounds.maxX + 0.5 &&
                        $0.minY >= bounds.minY - 0.5 && $0.maxY <= bounds.maxY + 0.5
                    }
                    if !inside { print("VIEWPORT", bounds, "MENUS", rects) }
                    let name = "\(Int(size.width))×\(Int(size.height)) text\(scale) \(crowded ? "crowded" : "empty")"
                    check(inside, "Sidebar Space and footer menus fit actual viewport at \(name)")
                    check(publications == 0 && store.views[pageID] === web && web.window === window && defaults.double(forKey: "sidebarWidth") == 236,
                          "Resizing \(name) retains website/default width without publishing store state")
                    subscription.cancel()
                }
            }
        }
        let pageState = try await web.evaluateJavaScript("document.getElementById('owned').value+'|'+window.scrollY") as? String
        check(pageState == "kept|600", "Short-window layout preserves the actual page form and scroll position")

        window.setContentSize(NSSize(width: 1260, height: 820)); await settle()
        guard let grip = descendants(hosting, SidebarResizeHandle.Handle.self).first else { fatalError("Missing production divider") }
        func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }
        func saved() -> Double { defaults.double(forKey: "sidebarWidth") }
        check(grip.isAccessibilityElement() && grip.accessibilityRole() == .splitter && grip.accessibilityOrientation() == .vertical,
              "Actual divider is an exposed vertical accessibility splitter")
        check(number(grip.accessibilityValue()) == 236 && number(grip.accessibilityMinValue()) == 196 && number(grip.accessibilityMaxValue()) == 360,
              "Accessible width and bounds match the actual sidebar")
        check(grip.accessibilityPerformIncrement() && saved() == 248, "AX increment persists a 12-point width change")
        check(grip.accessibilityPerformIncrement() && saved() == 260, "Synchronous AX increments accumulate before SwiftUI redraw")
        check(grip.accessibilityPerformDecrement() && saved() == 248, "AX decrement persists a 12-point width change")
        grip.setAccessibilityValue(999 as NSNumber)
        check(saved() == 360 && number(grip.accessibilityValue()) == 360, "AX numeric width clamps to maximum")
        grip.setAccessibilityValue(-100 as NSNumber)
        check(saved() == 196, "AX numeric width clamps to minimum")
        grip.setAccessibilityValue(280 as NSNumber)
        let beforeInvalid = saved()
        for invalid: Any in ["300", true, Double.nan, Double.infinity] { grip.setAccessibilityValue(invalid) }
        check(saved() == beforeInvalid, "AX setter rejects text, boolean and nonfinite widths")
        let reset = grip.accessibilityCustomActions()?.first { $0.name == "Reset Sidebar Width" }
        check(reset?.handler?() == true && saved() == 236, "Accessible reset restores the default width")
        window.setContentSize(NSSize(width: 500, height: 400))
        check(number(grip.accessibilityMaxValue()) == 225, "AX bounds read the native viewport before SwiftUI catches up")
        grip.setAccessibilityValue(999 as NSNumber)
        check(saved() == 225 && number(grip.accessibilityValue()) == 225, "AX setting clamps to the current native viewport")
        window.setContentSize(NSSize(width: 1260, height: 820)); await settle()
        grip.setAccessibilityValue(236 as NSNumber); await settle()
        grip.setAccessibilityFocused(true)
        check(window.firstResponder === grip && grip.isAccessibilityFocused(), "AX focus takes actual divider keyboard focus")
        check(grip.focusRingType == .exterior && !grip.focusRingMaskBounds.isEmpty, "Focused divider provides a native focus-ring mask")
        let right = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124)!
        grip.keyDown(with: right); grip.keyDown(with: right)
        check(saved() == 260, "Repeated idle arrow-key steps accumulate without redraw")
        store.commandVisible = true
        let beforeBlocked = saved()
        let blockedResult = grip.accessibilityPerformIncrement()
        grip.setAccessibilityValue(340 as NSNumber)
        check(!blockedResult && saved() == beforeBlocked, "Presented overlay immediately rejects stale AX actions")
        await settle()
        check(window.firstResponder !== grip && !grip.isAccessibilityFocused(), "Blocking an interaction releases divider focus")
        store.commandVisible = false; store.sidebarVisible = false; await settle()
        check(!grip.accessibilityPerformIncrement() && !grip.isAccessibilityEnabled(), "Hidden divider cannot resize through accessibility")

        window.pointer = NSPoint(x: 4, y: 100)
        descendants(hosting, SidebarTracking.Host.self).forEach { $0.updateTrackingAreas() }
        await settle(); await settle()
        check(grip.convert(grip.bounds, to: nil).midX > 0, "Owned root reveals its floating sidebar for focus checks")
        window.makeFirstResponder(grip)
        window.pointer = NSPoint(x: 600, y: 100)
        descendants(hosting, SidebarTracking.Host.self).forEach { $0.updateTrackingAreas() }
        await settle(); await settle(); await settle()
        check(window.firstResponder === grip && grip.convert(grip.bounds, to: nil).midX > 0,
              "Actual keyboard focus holds the floating sidebar open outside its bounds")
        for size in [NSSize(width: 960, height: 494), NSSize(width: 760, height: 400)] {
            window.setContentSize(size); await settle()
            let bounds = hosting.convert(hosting.bounds, to: nil)
            let menus = descendants(hosting, NSPopUpButton.self)
            check(menus.count >= 2 && menus.allSatisfy { bounds.contains($0.convert($0.bounds, to: nil)) },
                  "Focused floating sidebar retains footer in \(Int(size.width))×\(Int(size.height)) viewport")
        }
        grip.setAccessibilityFocused(false)
        await settle(); await settle(); await settle()
        check(window.firstResponder !== grip && grip.convert(grip.bounds, to: nil).midX < 0,
              "Releasing accessibility focus permits the floating sidebar to hide")
        store.sidebarVisible = true; await settle()
        let beforeClose = saved()
        window.close()
        check(!grip.accessibilityPerformIncrement() && saved() == beforeClose, "Closed-window divider rejects retained AX actions")
        grip.removeFromSuperview()
        check(!grip.accessibilityPerformIncrement() && saved() == beforeClose, "Detached divider rejects retained AX actions")
        window.contentView = nil; window.close(); store.shutdown()
        if failures > 0 { exit(1) }
    }
}
