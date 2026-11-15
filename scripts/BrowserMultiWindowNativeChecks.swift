import AppKit
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
        print("Native window checks: \(passed) passed, \(failed) failed")
        return failed
    }
}
