import AppKit
import SwiftUI
import BrowserCore
import CryptoKit

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
        let retained = BrowserSheetQuitPolicy.Host(preventsTermination: false); container.addSubview(retained)
        _ = await until { !sheet.preventsApplicationTerminationWhenModal }
        window.endSheet(sheet); sheet.orderOut(nil)
        _ = await until { sheet.sheetParent == nil && sheet.preventsApplicationTerminationWhenModal }
        check(sheet.sheetParent == nil && sheet.preventsApplicationTerminationWhenModal, "Ending a native sheet restores its original policy while the bridge remains installed")
        window.beginSheet(sheet, completionHandler: { _ in })
        _ = await until { sheet.sheetParent === window && !sheet.preventsApplicationTerminationWhenModal }
        check(sheet.sheetParent === window && !sheet.preventsApplicationTerminationWhenModal, "Re-presenting the same native sheet reacquires its informational policy")
        retained.removeFromSuperview()
        check(sheet.preventsApplicationTerminationWhenModal, "A re-presented native sheet still restores the true original policy")
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
        // Editable normal-window forms catch draft loss that a disabled private form cannot expose.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Alcove.SheetDrafts.\(UUID().uuidString)")
        let key = SymmetricKey(size: .bits256)
        let normal = BrowserStore(dataRoot: root, keyProvider: { _ in key })
        normal.onboardingVisible = false
        var normalAppearance = normal.appearance; normalAppearance.animationsEnabled = false; normal.appearance = normalAppearance
        defer { normal.shutdown(); try? FileManager.default.removeItem(at: root) }
        check(normal.canEditLinkRules && normal.canEditSiteSearches, "Owned normal-window fixture enables the real route and shortcut editors")
        let normalWindow = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1000, height: 760), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        normalWindow.isReleasedWhenClosed = false
        let normalHost = NSHostingView(rootView: BrowserUI(store: normal, sidebarDefaults: defaults).environmentObject(UpdateController(installedTag: "draft-quit-fixture")))
        normalHost.sizingOptions = []; normalHost.safeAreaRegions = []; normalWindow.contentView = normalHost
        let normalDelegate = AppDelegate(); normalDelegate.windows[normalWindow] = normal
        defer {
            normalDelegate.windows.removeAll()
            if let sheet = normalWindow.attachedSheet { normalWindow.endSheet(sheet); sheet.orderOut(nil) }
            normalWindow.contentView = nil; normalWindow.close()
        }
        normalWindow.makeKeyAndOrderFront(nil)
        func fields(_ view: NSView) -> [NSTextField] { (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields) }
        func edit(_ sheet: NSWindow, placeholder: String, value: String) async -> Bool {
            guard let content = sheet.contentView,
                  let field = fields(content).first(where: { $0.placeholderString == placeholder && $0.isEditable && $0.isEnabled }),
                  sheet.makeFirstResponder(field), let editor = field.currentEditor() as? NSTextView else {
                print("FIXTURE_ERROR: Editable native field unavailable", placeholder, sheet.contentView.map { fields($0).map { $0.placeholderString ?? "" } } ?? [])
                return false
            }
            editor.insertText(value, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
            return await until { field.stringValue == value }
        }
        func submit(_ sheet: NSWindow, placeholder: String) async -> Bool {
            guard let content = sheet.contentView,
                  let field = fields(content).first(where: { $0.placeholderString == placeholder && $0.isEditable && $0.isEnabled }),
                  sheet.makeFirstResponder(field), let editor = field.currentEditor() as? NSTextView,
                  let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: sheet.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) else {
                print("FIXTURE_ERROR: Native submit field unavailable", placeholder); return false
            }
            // These three real fields already submit the same Save action on Return.
            editor.keyDown(with: event)
            try? await Task.sleep(for: .milliseconds(100))
            return true
        }
        for panel: BrowserPanel in [.links, .siteSearch, .appearance] {
            normal.presentedPanel = panel
            guard await until({ normalWindow.attachedSheet?.preventsApplicationTerminationWhenModal == false }), let sheet = normalWindow.attachedSheet else {
                check(false, "Clean normal \(panel.rawValue) editor allows Quit"); return 1
            }
            sheet.orderFront(nil)
            check(sheet.sheetParent === normalWindow && sheet.isVisible, "Actual editable \(panel.rawValue) sheet is presented before draft testing")
            let placeholder = panel == .links ? "example.com or part of a URL" : panel == .siteSearch ? "YouTube" : "Space name"
            let value = panel == .links ? "owned-link-quit.example" : panel == .siteSearch ? "Owned quit shortcut" : "Owned renamed Space"
            guard await edit(sheet, placeholder: placeholder, value: value) else { check(false, "Native \(panel.rawValue) draft editing works"); return 1 }
            _ = await until { sheet.preventsApplicationTerminationWhenModal }
            check(sheet.preventsApplicationTerminationWhenModal, "Unsaved \(panel.rawValue) native form protects its draft from Quit")
            let beforeDirty = audit.consultations; normalDelegate.quit()
            check(audit.consultations == beforeDirty, "Quit preserves the unsaved \(panel.rawValue) draft before termination is admitted")
            if panel == .links {
                guard await submit(sheet, placeholder: "example.com or part of a URL") else { return 1 }
                check(normal.linkRuleCatalog.entries.contains(where: { $0.pattern == value }), "Real route Save commits the text entered in the native editor")
            } else if panel == .siteSearch {
                guard await edit(sheet, placeholder: "yt", value: "qxowned"),
                      await edit(sheet, placeholder: "https://example.com/search?q=%s", value: "http://127.0.0.1:9/search?q=%s"),
                      await submit(sheet, placeholder: "https://example.com/search?q=%s") else { return 1 }
                check(normal.siteSearchCatalog.entries.contains(where: { $0.name == value && $0.keyword == "qxowned" }), "Real shortcut Save commits the native form draft")
            } else {
                guard await submit(sheet, placeholder: "Space name") else { return 1 }
                check(normal.space.name == value, "Real Space-name Save commits the native form draft")
            }
            _ = await until { !sheet.preventsApplicationTerminationWhenModal }
            check(!sheet.preventsApplicationTerminationWhenModal, "Saving \(panel.rawValue) clears draft protection")
            guard await edit(sheet, placeholder: placeholder, value: "Owned draft to discard") else { return 1 }
            _ = await until { sheet.preventsApplicationTerminationWhenModal }
            check(sheet.preventsApplicationTerminationWhenModal, "A new \(panel.rawValue) edit after Save protects its new draft")
            guard await edit(sheet, placeholder: placeholder, value: panel == .appearance ? normal.space.name : "") else { return 1 }
            // Returning to the saved/empty value is an explicit native edit that discards the local draft.
            _ = await until { !sheet.preventsApplicationTerminationWhenModal }
            check(!sheet.preventsApplicationTerminationWhenModal, "Discarding the \(panel.rawValue) draft leaves the panel nonblocking")
            let afterDiscard = audit.consultations; normalDelegate.quit()
            check(audit.consultations == afterDiscard + 1, "A clean editable \(panel.rawValue) panel restores the native Quit decision after save or discard")
            normal.presentedPanel = nil
            guard await until({ normalWindow.attachedSheet == nil }) else { check(false, "Normal editor dismisses"); return 1 }
        }
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
