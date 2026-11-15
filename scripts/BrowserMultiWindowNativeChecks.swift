import AppKit
import BrowserCore
import CryptoKit

@MainActor
final class WindowCheckApplication: NSApplication {
    var fixtureKeyWindow: NSWindow?
    override var keyWindow: NSWindow? { fixtureKeyWindow ?? super.keyWindow }
}

@main
struct BrowserMultiWindowNativeChecks {
    @MainActor
    static func main() throws {
        if try run() > 0 { exit(1) }
    }

    @MainActor
    private static func run() throws -> Int {
        let application = WindowCheckApplication.shared as! WindowCheckApplication
        application.setActivationPolicy(.prohibited)
        let dataRoot = FileManager.default.temporaryDirectory.appendingPathComponent("alcove-native-windows-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dataRoot) }
        let key = SymmetricKey(size: .bits256)
        setbuf(stdout, nil)
        let root = BrowserStore(dataRoot: dataRoot, keyProvider: { _ in key })
        root.finishOnboarding()
        let delegate = AppDelegate()
        let owner = delegate.makeOwner(root)
        delegate.normalOwner = owner
        delegate.buildMenu()
        delegate.openPrimary(owner, activate: false)
        defer {
            application.fixtureKeyWindow = nil
            for window in Array(delegate.windows.keys) { window.close() }
        }
        var passed = 0
        var failed = 0
        func check(_ condition: Bool, _ description: String) {
            print("\(condition ? "PASS" : "FAIL"): \(description)")
            if condition { passed += 1 } else { failed += 1 }
        }
        guard let first = delegate.normalWindow,
              let file = application.mainMenu?.item(withTitle: "File")?.submenu,
              let newWindow = file.items.first(where: { $0.keyEquivalent == "n" && $0.keyEquivalentModifierMask == .command }),
              let newWindowAction = newWindow.action else {
            print("FAIL: The normal browser exposes Command-N through the native File menu")
            return 1
        }

        check(delegate.windows[first] === root && owner.leaseCount == 1, "A native first window uses the normal profile writer")
        application.fixtureKeyWindow = first
        let sent = application.sendAction(newWindowAction, to: newWindow.target, from: newWindow)
        let created = delegate.primaryOwners.keys.filter { $0 !== first }
        check(sent && created.count == 1, "Command-N creates a second normal native window")
        if let second = created.first, let store = delegate.windows[second] {
            check(store !== root && delegate.primaryOwners[second] === owner && owner.leaseCount == 2,
                  "Each native normal window has its own store and shares the same writer lease owner")
            application.fixtureKeyWindow = second
            delegate.sidebar()
            check(!store.sidebarVisible && root.sidebarVisible, "The native sidebar command affects the invoking window only")
            delegate.closeTab()
            check(delegate.windows[second] == nil && delegate.windows[first] === root && !owner.isClosed,
                  "Command-W on an empty normal window closes that window and preserves the other")
        }

        application.fixtureKeyWindow = first
        _ = application.sendAction(newWindowAction, to: newWindow.target, from: newWindow)
        if let target = delegate.primaryOwners.keys.first(where: { $0 !== first }), let store = delegate.windows[target] {
            let profile = try store.createProfile(name: "Focused link account")
            let original = root.selectedID
            try root.setDefaultLinkDestination(.mostRecentSpace)
            application.fixtureKeyWindow = target
            delegate.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: target))
            let url = URL(string: "http://127.0.0.1:9/focused-external-link")!
            delegate.application(application, open: [url])
            check(store.activeProfileID == profile && store.selectedTab?.url == url.absoluteString && root.selectedID == original,
                  "A macOS link opens in the focused normal window and keeps the other window's selection")
        }

        let recoveryRoot = dataRoot.appendingPathComponent("restore")
        let originalStore = BrowserStore(dataRoot: recoveryRoot, keyProvider: { _ in key })
        originalStore.finishOnboarding()
        let originalDelegate = AppDelegate()
        let originalOwner = originalDelegate.makeOwner(originalStore)
        originalDelegate.normalOwner = originalOwner
        originalDelegate.buildMenu()
        originalDelegate.openPrimary(originalOwner, activate: false)
        guard let originalLeft = originalDelegate.normalWindow, let screen = originalLeft.screen ?? NSScreen.main,
              let originalFile = application.mainMenu?.item(withTitle: "File")?.submenu,
              let nativeNew = originalFile.items.first(where: { $0.action == newWindowAction }) else {
            fatalError("Missing native restore fixture")
        }
        application.fixtureKeyWindow = originalLeft
        _ = application.sendAction(newWindowAction, to: nativeNew.target, from: nativeNew)
        guard let originalRight = originalDelegate.windows.keys.first(where: { $0 !== originalLeft }),
              let focusedStore = originalDelegate.windows[originalRight] else { fatalError("Missing second restore fixture window") }
        let visible = screen.visibleFrame
        let leftFrame = CGRect(x: visible.minX, y: visible.minY, width: 824, height: 560)
        let rightFrame = CGRect(x: visible.maxX - 890, y: visible.maxY - 610, width: 890, height: 610)
        originalLeft.setFrame(leftFrame, display: false)
        originalRight.setFrame(rightFrame, display: false)
        let leftID = originalStore.windowGroupID
        let focusedWindowID = focusedStore.windowGroupID
        application.fixtureKeyWindow = originalRight
        originalDelegate.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: originalRight))
        let focusedProfile = try focusedStore.createProfile(name: "Restored focused account")
        _ = focusedStore.newTab(url: URL(string: "http://127.0.0.1:9/existing-restored-tab"))
        try originalStore.setDefaultLinkDestination(.mostRecentSpace)
        let canQuit = originalDelegate.applicationShouldTerminate(application) == .terminateNow
        check(canQuit, "The production quit decision allows restored window records to be flushed")
        originalDelegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification, object: application))
        application.fixtureKeyWindow = nil
        originalLeft.close(); originalRight.close()

        let recoveringStore = BrowserStore(dataRoot: recoveryRoot, keyProvider: { _ in key })
        let recovering = AppDelegate()
        let recoveringOwner = recovering.makeOwner(recoveringStore)
        recovering.normalOwner = recoveringOwner
        defer { for window in Array(recovering.windows.keys) { window.close() } }
        recoveringStore.awaitingInitialMetadata = true
        application.fixtureKeyWindow = nil
        let queuedURL = URL(string: "http://127.0.0.1:9/queued-external-link")!
        recovering.application(application, open: [queuedURL])
        check(recoveringOwner.pendingExternalURLs == [queuedURL] && recovering.windows.count == 1,
              "A macOS link can wait while the normal workspace is being restored")
        recoveringStore.awaitingInitialMetadata = false
        recovering.metadataDidLoad(recoveringOwner)
        let restored = recovering.windows.values.first { $0.windowGroupID == focusedWindowID }
        check(recovering.windows.count == 2 && restored?.activeProfileID == focusedProfile &&
              restored?.selectedTab?.url == queuedURL.absoluteString && recoveringOwner.pendingExternalURLs.isEmpty,
              "A queued macOS link respects the restored focused window and its profile")
        let restoredLeft = recovering.windows.first { $0.value.windowGroupID == leftID }?.key
        let restoredRight = recovering.windows.first { $0.value.windowGroupID == focusedWindowID }?.key
        check(restoredLeft?.frame == leftFrame && restoredRight?.frame == rightFrame,
              "Real AppKit position and size survive native quit and workspace restoration")
        print("Native window checks: \(passed) passed, \(failed) failed")
        return failed
    }
}
