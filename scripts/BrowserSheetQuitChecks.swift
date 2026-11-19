import AppKit
import SwiftUI
import BrowserCore

@MainActor final class SheetQuitAudit: NSObject, NSApplicationDelegate {
    var consultations = 0
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        consultations += 1
        return .terminateCancel
    }
}

/// Actual BrowserUI sheets and Quit action; only the final decision cancels to keep this fixture alive.
@main struct BrowserSheetQuitChecks {
    @MainActor static func run(_ audit: SheetQuitAudit) async -> Int32 {
        var failures = 0
        func check(_ ok: Bool, _ name: String) {
            print("\(ok ? "PASS" : "FAIL"): \(name)")
            if !ok { failures += 1 }
        }
        func until(_ condition: () -> Bool) async -> Bool {
            let end = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < end {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return condition()
        }
        let store = BrowserStore(isPrivate: true)
        store.onboardingVisible = false
        var appearance = store.appearance; appearance.animationsEnabled = false; store.appearance = appearance
        let suite = "Alcove.BrowserSheetQuitChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); store.shutdown() }
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1000, height: 700), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: BrowserUI(store: store, sidebarDefaults: defaults).environmentObject(UpdateController(installedTag: "sheet-quit-fixture")))
        host.sizingOptions = []; host.safeAreaRegions = []
        window.contentView = host
        let delegate = AppDelegate(); delegate.windows[window] = store
        defer {
            delegate.windows.removeAll()
            if let sheet = window.attachedSheet { window.endSheet(sheet); sheet.orderOut(nil) }
            window.contentView = nil; window.close()
        }
        window.orderFront(nil)
        for panel: BrowserPanel in [.library, .settings, .siteSearch, .links, .appearance, .profiles, .updates] {
            store.presentedPanel = panel
            guard await until({ window.attachedSheet != nil }), let sheet = window.attachedSheet else {
                check(false, "Actual \(panel.rawValue) native sheet attaches"); return 1
            }
            _ = await until { !sheet.preventsApplicationTerminationWhenModal }
            check(!sheet.preventsApplicationTerminationWhenModal, "Actual \(panel.rawValue) sheet allows ordinary app termination")
            let before = audit.consultations
            delegate.quit()
            check(audit.consultations == before + 1, "Quit from \(panel.rawValue) reaches the native termination decision")
            check(window.attachedSheet === sheet && sheet.sheetParent === window, "A cancelled quit preserves the open \(panel.rawValue) sheet")
            store.presentedPanel = nil
            guard await until({ window.attachedSheet == nil }) else { check(false, "Owned sheet dismisses after \(panel.rawValue)"); return 1 }
        }
        let parentPolicy = window.preventsApplicationTerminationWhenModal
        store.presentedPanel = .boosts
        guard await until({ window.attachedSheet != nil }), let boosts = window.attachedSheet else { check(false, "Boosts sheet attaches"); return 1 }
        check(boosts.preventsApplicationTerminationWhenModal, "An open Boosts editor retains draft-protecting termination policy")
        var before = audit.consultations
        delegate.quit()
        check(audit.consultations == before, "Quit cannot bypass the Boosts editor's native protection")
        store.presentedPanel = .library
        guard await until({ window.attachedSheet?.preventsApplicationTerminationWhenModal == false }), let library = window.attachedSheet else { check(false, "Switching from Boosts to Library updates native policy"); return 1 }
        before = audit.consultations; delegate.quit()
        check(audit.consultations == before + 1, "Changing the panel restores ordinary Quit behavior")
        let confirmation = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        confirmation.isReleasedWhenClosed = false
        confirmation.preventsApplicationTerminationWhenModal = true
        library.beginCriticalSheet(confirmation, completionHandler: { _ in })
        guard await until({ confirmation.sheetParent === library }) else { check(false, "Owned nested confirmation attaches"); return 1 }
        before = audit.consultations; delegate.quit()
        check(audit.consultations == before && confirmation.preventsApplicationTerminationWhenModal, "An actual nested confirmation still blocks termination above an informational panel")
        library.endSheet(confirmation); confirmation.orderOut(nil)
        _ = await until { confirmation.sheetParent == nil }
        confirmation.close()
        store.presentedPanel = nil
        guard await until({ window.attachedSheet == nil }) else { check(false, "Library dismisses after nested confirmation"); return 1 }
        check(window.preventsApplicationTerminationWhenModal == parentPolicy, "Browser panel policies never alter their parent window")

        let sheet = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 180)); sheet.contentView = container
        let first = BrowserSheetQuitPolicy.Host(preventsTermination: false)
        container.addSubview(first)
        try? await Task.sleep(for: .milliseconds(80))
        check(sheet.preventsApplicationTerminationWhenModal, "A bridge attached before presentation does not change a non-sheet window")
        window.beginSheet(sheet, completionHandler: { _ in })
        guard await until({ !sheet.preventsApplicationTerminationWhenModal }) else { check(false, "Late native sheet attachment acquires the intended policy"); return 1 }
        check(true, "A native parent assigned after bridge attachment enables Quit")
        let second = BrowserSheetQuitPolicy.Host(preventsTermination: false); container.addSubview(second)
        _ = await until { !sheet.preventsApplicationTerminationWhenModal }
        first.removeFromSuperview()
        try? await Task.sleep(for: .milliseconds(50))
        check(!sheet.preventsApplicationTerminationWhenModal, "An old bridge leaving cannot restore a blocker over its successor")
        let blocker = BrowserSheetQuitPolicy.Host(preventsTermination: true); container.addSubview(blocker)
        _ = await until { sheet.preventsApplicationTerminationWhenModal }
        check(sheet.preventsApplicationTerminationWhenModal, "A draft-protecting bridge wins during overlapping ownership")
        blocker.removeFromSuperview()
        _ = await until { !sheet.preventsApplicationTerminationWhenModal }
        check(!sheet.preventsApplicationTerminationWhenModal, "Removing the protecting owner returns the surviving informational policy")
        second.setPolicy(true)
        check(sheet.preventsApplicationTerminationWhenModal, "A reused sheet bridge updates a newly protected panel immediately")
        second.setPolicy(false)
        check(!sheet.preventsApplicationTerminationWhenModal, "A reused sheet bridge updates back to an informational panel")
        second.removeFromSuperview()
        check(sheet.preventsApplicationTerminationWhenModal, "Removing the last bridge restores the native original policy")
        let stopped = BrowserSheetQuitPolicy.Host(preventsTermination: false); container.addSubview(stopped)
        stopped.shutdown()
        try? await Task.sleep(for: .milliseconds(80))
        check(sheet.preventsApplicationTerminationWhenModal, "A dismantled bridge cannot reacquire policy from its delayed attachment callback")
        stopped.removeFromSuperview()
        let moved = BrowserSheetQuitPolicy.Host(preventsTermination: false); container.addSubview(moved)
        _ = await until { !sheet.preventsApplicationTerminationWhenModal }
        host.addSubview(moved)
        try? await Task.sleep(for: .milliseconds(50))
        check(sheet.preventsApplicationTerminationWhenModal && window.preventsApplicationTerminationWhenModal == parentPolicy, "Reparenting restores the old sheet and leaves the regular window unchanged")
        moved.removeFromSuperview()
        check(first.hitTest(.zero) == nil, "Policy bridge remains transparent to pointer input")
        window.endSheet(sheet); sheet.orderOut(nil)
        _ = await until { sheet.sheetParent == nil }
        sheet.close()

        let originallyAllowed = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        originallyAllowed.isReleasedWhenClosed = false; originallyAllowed.preventsApplicationTerminationWhenModal = false
        let protect = BrowserSheetQuitPolicy.Host(preventsTermination: true); originallyAllowed.contentView = protect
        window.beginSheet(originallyAllowed, completionHandler: { _ in })
        _ = await until { originallyAllowed.preventsApplicationTerminationWhenModal }
        check(originallyAllowed.preventsApplicationTerminationWhenModal, "An owned draft can protect a sheet that initially allowed termination")
        protect.shutdown()
        check(!originallyAllowed.preventsApplicationTerminationWhenModal, "Final owner restores an originally nonblocking native policy exactly")
        window.endSheet(originallyAllowed); originallyAllowed.orderOut(nil)
        _ = await until { originallyAllowed.sheetParent == nil }
        originallyAllowed.contentView = nil; originallyAllowed.close()
        print("BROWSER_SHEET_QUIT_FAILURES", failures)
        return failures == 0 ? 0 : 1
    }
    @MainActor static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        let audit = SheetQuitAudit(); app.delegate = audit
        Task { @MainActor in let result = await run(audit); app.delegate = nil; exit(result) }
        withExtendedLifetime(audit) { app.run() }
    }
}
