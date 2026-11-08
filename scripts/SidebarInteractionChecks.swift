import AppKit
import SwiftUI
import Combine
import BrowserCore

@MainActor final class SidebarFixtureWindow: NSWindow {
    var fixtureKey = true
    var pointer = NSPoint(x: -1000, y: -1000)
    override var isKeyWindow: Bool { fixtureKey }
    override var mouseLocationOutsideOfEventStream: NSPoint { pointer }
}

/// Event handlers run only on owned, never-shown fixtures, never on user apps.
@main struct SidebarInteractionChecks {
    @MainActor static func main() async {
        NSApplication.shared.setActivationPolicy(.prohibited); setbuf(stdout, nil)
        var failures = 0
        func check(_ ok: Bool, _ name: String) {
            print("\(ok ? "PASS" : "FAIL"): \(name)"); if !ok { failures += 1 }
        }
        func pause(_ milliseconds: Int = 300) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }
        func window() -> SidebarFixtureWindow {
            let result = SidebarFixtureWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            result.isReleasedWhenClosed = false; return result
        }
        let hover = SidebarRevealController(enabled: true)
        hover.edgeEntered(); hover.edgeExited(); await pause(130)
        check(!hover.revealed, "Leaving before the reveal deadline cancels the pending sidebar")
        hover.edgeEntered(); await pause(130)
        check(hover.revealed, "Entering the edge reveals the floating sidebar after its delay")
        hover.edgeExited(); await pause()
        check(!hover.revealed, "Leaving the edge hides the sidebar even when no panel-enter event arrives")
        hover.edgeEntered(); await pause(130); hover.panelEntered(); hover.edgeExited()
        hover.panelExited(); hover.panelEntered(); await pause()
        check(hover.revealed, "Reentering the panel cancels a stale delayed hide")
        var publications = 0
        let subscription = hover.objectWillChange.sink { publications += 1 }
        for _ in 0..<20 { hover.panelEntered() }
        await pause(20)
        check(publications == 0, "Duplicate pointer bookkeeping does not invalidate the sidebar layout")
        subscription.cancel()
        hover.beginResize(); hover.panelExited(); await pause()
        check(hover.revealed, "A sidebar resize holds the floating panel open outside its bounds")
        hover.endResize(); await pause()
        check(!hover.revealed, "Ending resize reevaluates pointer presence and permits delayed hiding")
        hover.edgeEntered(); hover.setEnabled(false); await pause(130)
        check(!hover.revealed, "Pinning or an overlay revokes a pending reveal")
        hover.edgeEntered(); await pause(130)
        check(!hover.revealed, "Disabled floating chrome cannot reveal from a pointer event")
        hover.setEnabled(true); await pause(130)
        check(hover.revealed, "Enabling a tracked edge preserves its current pointer presence")
        hover.reset(); await pause()
        check(!hover.revealed, "Reset cancels outstanding work and clears floating state")

        let menuOwner = window()
        let menuHover = SidebarRevealController(enabled: true); menuHover.attach(to: menuOwner)
        menuHover.edgeEntered(); await pause(130)
        let menu = NSMenu(title: "Owned menu"), other = NSMenu(title: "Other menu")
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        menuHover.edgeExited(); await pause()
        check(menuHover.revealed, "A native menu holds its originating floating sidebar open")
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: other)
        await pause()
        check(menuHover.revealed, "An unrelated menu-end notification cannot release another menu's hold")
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        await pause()
        check(!menuHover.revealed, "Native menu completion releases its hold even without an action")
        menuHover.edgeEntered(); await pause(130)
        menuOwner.fixtureKey = false
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: other)
        menuOwner.fixtureKey = true; menuHover.edgeExited(); await pause()
        check(!menuHover.revealed, "A menu from another key window does not retain this sidebar")
        menuHover.edgeEntered()
        menuOwner.fixtureKey = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: menuOwner)
        await pause(130)
        check(!menuHover.revealed, "Window resignation revokes a delayed reveal")
        menuOwner.fixtureKey = true
        menuHover.edgeEntered(); await pause(130)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: menuOwner)
        check(!menuHover.revealed, "Closing a window immediately clears its floating sidebar")

        let trackOwner = window()
        let trackingHover = SidebarRevealController(enabled: true)
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400)); trackOwner.contentView = parent
        let edge = SidebarTracking.Host(controller: trackingHover, region: .edge)
        edge.frame = NSRect(x: 0, y: 0, width: 8, height: 400); parent.addSubview(edge)
        edge.configure(enabled: true); edge.updateTrackingAreas()
        check(edge.trackingAreas.count == 1 && edge.trackingAreas[0].options.contains([.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .enabledDuringMouseDrag]),
              "Native sidebar tracking follows visible geometry and continues during drags in its key window")
        check(edge.hitTest(NSPoint(x: 4, y: 100)) == nil && !edge.acceptsFirstResponder,
              "Sidebar tracking cannot intercept a click or take keyboard focus")
        trackOwner.pointer = NSPoint(x: 4, y: 100); edge.updateTrackingAreas(); await pause(130)
        check(trackingHover.revealed, "Tracking-area geometry updates reconcile a pointer already inside the edge")
        trackOwner.pointer = NSPoint(x: 100, y: 100); edge.updateTrackingAreas(); await pause()
        check(!trackingHover.revealed, "Geometry changes reconcile an exited pointer without a missing-event gap")
        trackOwner.pointer = NSPoint(x: 4, y: 100); edge.updateTrackingAreas(); await pause(130)
        let detachMenu = NSMenu(title: "Detach fixture")
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: detachMenu)
        edge.removeFromSuperview(); await pause(20)
        check(!trackingHover.revealed, "Detaching the last tracked region clears menu holds and floating visibility")
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: detachMenu)
        edge.configure(enabled: false)
        check(edge.trackingAreas.isEmpty, "Disabled edge tracking removes its native area")
        var old: SidebarFixtureWindow? = window()
        weak var oldReference: SidebarFixtureWindow?; oldReference = old
        let next = window(); trackingHover.attach(to: old!); trackingHover.attach(to: next)
        old?.close(); old = nil; await pause(20)
        check(oldReference == nil, "Rebinding sidebar observation releases the previous window")
        trackingHover.edgeEntered(); await pause(130)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: trackOwner)
        check(trackingHover.revealed, "Notifications from an old window cannot reset its replacement")
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: next)
        check(!trackingHover.revealed, "The replacement window owns floating-state teardown")
        for c in [hover, menuHover, trackingHover] { c.reset() }
        for w in [menuOwner, trackOwner, next] { w.contentView = nil; w.close() }
        if failures > 0 { exit(1) }
    }
}
