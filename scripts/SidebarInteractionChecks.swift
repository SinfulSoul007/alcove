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
        // Task.sleep specifies a minimum suspension, not when another actor task starts.
        // Observe the transition with a finite deadline; retain pauses for negative/held-state checks.
        func waitUntil(_ condition: () -> Bool) async -> Bool {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !condition() && ContinuousClock.now < deadline { await pause(10) }
            return condition()
        }
        func requireVisible(_ controller: SidebarRevealController) async {
            guard await waitUntil({ controller.revealed }) else {
                check(false, "Sidebar fixture did not become visible before its bounded setup deadline")
                exit(1)
            }
        }
        func reveal(_ controller: SidebarRevealController) async {
            controller.edgeEntered(); await requireVisible(controller)
        }
        func window() -> SidebarFixtureWindow {
            let result = SidebarFixtureWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            result.isReleasedWhenClosed = false; return result
        }
        // Stall only this owned process's main queue before the scheduled task can start.
        // The former fixed130ms assertion fails here even though the controller later transitions.
        let congested = SidebarRevealController(enabled: true)
        DispatchQueue.main.async { Thread.sleep(forTimeInterval: 0.25) }
        congested.edgeEntered()
        check(await waitUntil({ congested.revealed }), "A queued main-executor stall does not make the reveal assertion premature")
        DispatchQueue.main.async { Thread.sleep(forTimeInterval: 0.35) }
        congested.edgeExited()
        check(await waitUntil({ !congested.revealed }), "A queued main-executor stall does not make the hide assertion premature")
        congested.reset()

        let hover = SidebarRevealController(enabled: true)
        hover.edgeEntered(); hover.edgeExited(); await pause(130)
        check(!hover.revealed, "Leaving before the reveal deadline cancels the pending sidebar")
        hover.edgeEntered()
        check(await waitUntil({ hover.revealed }), "Entering the edge reveals the floating sidebar after its delay")
        hover.edgeExited()
        check(await waitUntil({ !hover.revealed }), "Leaving the edge hides the sidebar even when no panel-enter event arrives")
        await reveal(hover); hover.panelEntered(); hover.edgeExited()
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
        hover.setKeyboardFocus(true); hover.endResize(); await pause()
        check(hover.revealed, "Keyboard focus retains the floating panel after a mouse resize ends")
        hover.setKeyboardFocus(false)
        hover.endResize()
        check(await waitUntil({ !hover.revealed }), "Ending resize reevaluates pointer presence and permits delayed hiding")
        hover.edgeEntered(); hover.setEnabled(false); await pause(130)
        check(!hover.revealed, "Pinning or an overlay revokes a pending reveal")
        hover.edgeEntered(); await pause(130)
        check(!hover.revealed, "Disabled floating chrome cannot reveal from a pointer event")
        hover.setEnabled(true)
        check(await waitUntil({ hover.revealed }), "Enabling a tracked edge preserves its current pointer presence")
        hover.reset(); await pause()
        check(!hover.revealed, "Reset cancels outstanding work and clears floating state")
        hover.setEnabled(false); hover.setKeyboardFocus(true); hover.setEnabled(true); hover.edgeEntered()
        check(await waitUntil({ hover.revealed }), "A late focus callback while disabled cannot block the next edge reveal")
        hover.reset()

        let menuOwner = window()
        let menuHover = SidebarRevealController(enabled: true); menuHover.attach(to: menuOwner)
        await reveal(menuHover)
        let menu = NSMenu(title: "Owned menu"), other = NSMenu(title: "Other menu")
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        menuHover.edgeExited(); await pause()
        check(menuHover.revealed, "A native menu holds its originating floating sidebar open")
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: other)
        await pause()
        check(menuHover.revealed, "An unrelated menu-end notification cannot release another menu's hold")
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        check(await waitUntil({ !menuHover.revealed }), "Native menu completion releases its hold even without an action")
        await reveal(menuHover)
        menuOwner.fixtureKey = false
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: other)
        menuOwner.fixtureKey = true; menuHover.edgeExited()
        check(await waitUntil({ !menuHover.revealed }), "A menu from another key window does not retain this sidebar")
        menuHover.edgeEntered()
        menuOwner.fixtureKey = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: menuOwner)
        await pause(130)
        check(!menuHover.revealed, "Window resignation revokes a delayed reveal")
        menuOwner.fixtureKey = true
        await reveal(menuHover)
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
        trackOwner.pointer = NSPoint(x: 4, y: 100); edge.updateTrackingAreas()
        check(await waitUntil({ trackingHover.revealed }), "Tracking-area geometry updates reconcile a pointer already inside the edge")
        trackOwner.pointer = NSPoint(x: 100, y: 100); edge.updateTrackingAreas()
        check(await waitUntil({ !trackingHover.revealed }), "Geometry changes reconcile an exited pointer without a missing-event gap")
        func trackingEvent(_ kind: NSEvent.EventType, x: Double) -> NSEvent {
            NSEvent.enterExitEvent(with: kind, location: NSPoint(x: x, y: 100), modifierFlags: [], timestamp: 0,
                                  windowNumber: trackOwner.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        }
        edge.mouseEntered(with: trackingEvent(.mouseEntered, x: 4)); await pause(130)
        check(!trackingHover.revealed, "A stale entered event cannot reopen the sidebar after the pointer has left")
        trackOwner.pointer = NSPoint(x: 4, y: 100); edge.updateTrackingAreas(); await requireVisible(trackingHover)
        edge.mouseExited(with: trackingEvent(.mouseExited, x: 100)); await pause()
        check(trackingHover.revealed, "A stale exited event cannot hide the sidebar beneath the current pointer")
        trackOwner.pointer = NSPoint(x: 4, y: 100); edge.updateTrackingAreas(); await requireVisible(trackingHover)
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
        await reveal(trackingHover)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: trackOwner)
        check(trackingHover.revealed, "Notifications from an old window cannot reset its replacement")
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: next)
        check(!trackingHover.revealed, "The replacement window owns floating-state teardown")
        for c in [hover, menuHover, trackingHover] { c.reset() }
        for w in [menuOwner, trackOwner, next] { w.contentView = nil; w.close() }

        var width = SidebarResizeState()
        width.begin(at: 236); width.cancel(); width.drag(by: 50, windowWidth: 1000)
        check(width.temporaryWidth == nil, "Cancelled width state rejects a late drag update")
        width.begin(at: 236); _ = width.finish(); width.drag(by: 50, windowWidth: 1000)
        check(width.temporaryWidth == nil, "Completed width state rejects a late drag update")
        let resizeWindow = window(), replacementWindow = window()
        resizeWindow.setContentSize(NSSize(width: 1000, height: 400)); replacementWindow.setContentSize(NSSize(width: 1000, height: 400))
        let resizeParent = NSView(); resizeWindow.contentView = resizeParent
        let replacementParent = NSView(); replacementWindow.contentView = replacementParent
        let handle = SidebarResizeHandle.Handle(frame: NSRect(x: 0, y: 0, width: 6, height: 300))
        resizeParent.addSubview(handle)
        var storedWidth = 236.0, begins = 0, ends = 0, cancels = 0, resets = 0, absoluteSets = 0
        handle.begin = { begins += 1; width.begin(at: storedWidth) }
        handle.drag = { width.drag(by: $0, windowWidth: 1000) }
        handle.end = { [weak handle] in ends += 1; if let value = width.finish() { storedWidth = value; handle?.width = value } }
        handle.cancel = { cancels += 1; width.cancel() }
        handle.reset = { resets += 1; width.cancel(); storedWidth = 236 }
        handle.setWidth = { absoluteSets += 1; storedWidth = $0 }
        func mouse(_ type: NSEvent.EventType, x: Double, clicks: Int = 1, owner: NSWindow) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 80), modifierFlags: [], timestamp: 0,
                               windowNumber: owner.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 0)!
        }
        func key(_ code: UInt16, owner: NSWindow) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: owner.windowNumber,
                             context: nil, characters: code == 53 ? "\u{1b}" : "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
        }
        handle.mouseDown(with: mouse(.leftMouseDown, x: 200, owner: resizeWindow))
        handle.mouseDragged(with: mouse(.leftMouseDragged, x: 250, owner: resizeWindow))
        check(width.temporaryWidth == 286 && storedWidth == 236, "Mouse resize changes only transient width before release")
        let heldAX = handle.accessibilityPerformIncrement()
        handle.setAccessibilityValue(320 as NSNumber)
        check(!heldAX && absoluteSets == 0 && storedWidth == 236, "AX actions cannot interrupt or commit an active mouse gesture")
        handle.mouseUp(with: mouse(.leftMouseUp, x: 250, owner: resizeWindow))
        handle.mouseUp(with: mouse(.leftMouseUp, x: 250, owner: resizeWindow))
        check(storedWidth == 286 && ends == 1 && width.temporaryWidth == nil, "Mouse release commits the width exactly once")
        handle.mouseDown(with: mouse(.leftMouseDown, x: 200, owner: resizeWindow))
        handle.mouseDragged(with: mouse(.leftMouseDragged, x: 250, owner: resizeWindow))
        handle.keyDown(with: key(53, owner: resizeWindow))
        handle.mouseDragged(with: mouse(.leftMouseDragged, x: 300, owner: resizeWindow))
        handle.mouseUp(with: mouse(.leftMouseUp, x: 300, owner: resizeWindow))
        check(cancels == 1 && ends == 1 && storedWidth == 286 && width.temporaryWidth == nil, "Escape cancels once and late drag/up events cannot persist the abandoned width")
        handle.mouseDown(with: mouse(.leftMouseDown, x: 200, owner: resizeWindow))
        handle.mouseDragged(with: mouse(.leftMouseDragged, x: 230, owner: resizeWindow))
        check(SidebarResizeHandle.cancelActiveResize(in: resizeWindow) && !SidebarResizeHandle.cancelActiveResize(in: resizeWindow),
              "The browser Escape router consumes only an active resize, once")
        check(cancels == 2 && storedWidth == 286 && width.temporaryWidth == nil, "Browser-level cancellation preserves the original saved width")
        handle.mouseDown(with: mouse(.leftMouseDown, x: 100, clicks: 2, owner: resizeWindow))
        let beforeDoubleBegin = begins, beforeDoubleEnd = ends
        handle.mouseDragged(with: mouse(.leftMouseDragged, x: 400, owner: resizeWindow))
        handle.mouseUp(with: mouse(.leftMouseUp, x: 400, owner: resizeWindow))
        check(resets == 1 && storedWidth == 236 && begins == beforeDoubleBegin && ends == beforeDoubleEnd && width.temporaryWidth == nil,
              "Double-click reset cannot reuse a prior drag origin or commit a phantom gesture")
        handle.keyDown(with: key(124, owner: resizeWindow))
        check(storedWidth == 248 && absoluteSets == 1 && ends == beforeDoubleEnd && width.temporaryWidth == nil, "An idle arrow-key step commits one bounded width change")
        handle.mouseDown(with: mouse(.leftMouseDown, x: 200, owner: resizeWindow))
        handle.mouseDragged(with: mouse(.leftMouseDragged, x: 220, owner: resizeWindow))
        let beforeHeldArrow = ends
        handle.keyDown(with: key(124, owner: resizeWindow))
        check(ends == beforeHeldArrow && storedWidth == 248 && width.temporaryWidth == 268, "Arrow keys cannot prematurely commit a held mouse gesture")
        resizeWindow.fixtureKey = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: resizeWindow)
        handle.mouseUp(with: mouse(.leftMouseUp, x: 220, owner: resizeWindow))
        check(cancels == 3 && storedWidth == 248 && ends == beforeHeldArrow && width.temporaryWidth == nil,
              "Key-window loss cancels the resize without saving its transient width")
        check(resizeWindow.firstResponder !== handle && !handle.isAccessibilityFocused(), "Key-window loss also releases actual divider focus")
        resizeWindow.fixtureKey = true
        handle.mouseDown(with: mouse(.leftMouseDown, x: 200, owner: resizeWindow))
        handle.mouseDragged(with: mouse(.leftMouseDragged, x: 300, owner: resizeWindow))
        handle.removeFromSuperview()
        check(cancels == 4 && storedWidth == 248 && width.temporaryWidth == nil, "Detaching an active resize handle cancels once")
        replacementParent.addSubview(handle)
        handle.mouseDown(with: mouse(.leftMouseDown, x: 100, owner: replacementWindow))
        handle.mouseDragged(with: mouse(.leftMouseDragged, x: 120, owner: replacementWindow))
        let beforeOldInputEnd = ends
        handle.mouseDragged(with: mouse(.leftMouseDragged, x: 350, owner: resizeWindow))
        handle.mouseUp(with: mouse(.leftMouseUp, x: 350, owner: resizeWindow))
        check(width.temporaryWidth == 268 && storedWidth == 248 && ends == beforeOldInputEnd,
              "Old-window mouse input cannot mutate or commit a replacement window's resize")
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: resizeWindow)
        check(cancels == 4 && width.temporaryWidth == 268, "An old window cannot cancel a handle after reattachment")
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: replacementWindow)
        handle.mouseUp(with: mouse(.leftMouseUp, x: 120, owner: replacementWindow))
        check(cancels == 5 && storedWidth == 248 && width.temporaryWidth == nil, "The current window closes and cancels its active resize without committing")
        let focusWindow = window(), focusParent = NSView(); focusWindow.contentView = focusParent; focusParent.addSubview(handle)
        focusWindow.setContentSize(NSSize(width: 1000, height: 400))
        handle.mouseDown(with: mouse(.leftMouseDown, x: 100, owner: focusWindow))
        handle.mouseDragged(with: mouse(.leftMouseDragged, x: 110, owner: focusWindow))
        let beforeFocusCancel = cancels
        focusWindow.makeFirstResponder(nil)
        handle.mouseUp(with: mouse(.leftMouseUp, x: 110, owner: focusWindow))
        check(cancels == beforeFocusCancel + 1 && storedWidth == 248 && width.temporaryWidth == nil,
              "Moving keyboard focus away from an active grip cancels its transient resize")
        for w in [resizeWindow, replacementWindow, focusWindow] { w.contentView = nil; w.close() }
        if failures > 0 { exit(1) }
    }
}
