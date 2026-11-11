import AppKit
import SwiftUI
import WebKit
import CryptoKit
import BrowserCore

final class KeyGate: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    func pollStarted() -> Bool { started.wait(timeout: .now()) == .success }
    func key(_ key: SymmetricKey) -> SymmetricKey { started.signal(); release.wait(); return key }
}
@MainActor final class StartupApplication: NSApplication {
    var fixtureWindow: NSWindow?
    override var keyWindow: NSWindow? { fixtureWindow ?? super.keyWindow }
}
@MainActor final class WeakStore { weak var value: BrowserStore?; init(_ value: BrowserStore) { self.value = value } }
@main struct StartupChecks {
    @MainActor static func main() async throws {
        let application = StartupApplication.shared as! StartupApplication
        application.setActivationPolicy(.prohibited)
        setbuf(stdout, nil)
        var failures = 0
        func check(_ value: Bool, _ name: String) { print("\(value ? "PASS" : "FAIL"): \(name)"); if !value { failures += 1 } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256)
        let seed = BrowserStore(dataRoot: root, keyProvider: { _ in key }); seed.finishOnboarding(); try seed.setDefaultLinkDestination(.mostRecentSpace); seed.shutdown()
        let before = try Data(contentsOf: seed.sessionURL)
        let gate = KeyGate()
        var closed: BrowserStore? = BrowserStore(dataRoot: root, keyProvider: { _ in throw CocoaError(.fileReadNoPermission) })
        let weakClosed = WeakStore(closed!)
        check(closed!.unlockLocalData(keyProvider: { gate.key(key) }), "Retry starts once")
        for _ in 0..<100 where !gate.pollStarted() { try await Task.sleep(for: .milliseconds(10)) }
        closed!.shutdown(); closed = nil
        try await Task.sleep(for: .milliseconds(50))
        check(weakClosed.value == nil, "Closing during a blocked Keychain retry releases the store")
        gate.release.signal(); try await Task.sleep(for: .milliseconds(100))
        check(try Data(contentsOf: seed.sessionURL) == before, "Late Keychain completion cannot write a closed store")
        let startupGate = KeyGate()
        let access = MetadataKeyAccess { create, interactive in
            guard !Thread.isMainThread && !create && !interactive else { throw CocoaError(.coderInvalidValue) }
            return startupGate.key(key)
        }
        var initial: BrowserStore? = BrowserStore(dataRoot: root, metadataKeyAccess: access)
        check(initial!.awaitingInitialMetadata && initial!.unlocking && !initial!.savingEnabled && !initial!.onboardingVisible, "Initial window can render before a blocked key returns")
        initial!.showCommand(new: true)
        check(initial!.profileUnavailable(BrowserProfile.defaultID) && !initial!.commandVisible && initial!.namedDataStores.isEmpty, "Unknown saved identity blocks normal browsing and profile storage")
        let abandoned = WeakStore(initial!); initial!.shutdown(); initial = nil
        try await Task.sleep(for: .milliseconds(30))
        check(abandoned.value == nil, "Initial lookup does not retain an abandoned browser")
        let reopened = BrowserStore(dataRoot: root, metadataKeyAccess: access)
        let owner = BrowserWindowOwner(store: reopened); let lease = try owner.acquirePrimary()
        let link = URL(string: "https://example.com/queued")!
        check(try owner.dispatchExternal(link) == .pending && reopened.views.isEmpty, "OS link waits without opening a default-profile website")
        let hosting = NSHostingView(rootView: BrowserUI(store: reopened).environmentObject(UpdateController(installedTag: "test")))
        hosting.safeAreaRegions = []; hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x:0,y:0,width:800,height:540), styleMask:[.titled,.closable,.resizable], backing:.buffered, defer:false)
        window.isReleasedWhenClosed = false; window.contentView = hosting
        try await Task.sleep(for: .milliseconds(80)); hosting.layoutSubtreeIfNeeded()
        func descendants<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] { (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0,type) } }
        check(descendants(hosting, SidebarResizeHandle.Handle.self).isEmpty && descendants(hosting, WKWebView.self).isEmpty && reopened.views.isEmpty, "Mounted loading root creates no browsing chrome or website views")
        let delegate = AppDelegate(); delegate.windows[window] = reopened
        let savedDelegate = application.delegate; application.delegate = delegate
        let privateMenu = NSMenuItem(title:"Private",action:#selector(AppDelegate.privateWindow),keyEquivalent:"")
        let quitMenu = NSMenuItem(title:"Quit",action:#selector(AppDelegate.quit),keyEquivalent:"")
        application.fixtureWindow = window
        check(delegate.validateMenuItem(privateMenu) && delegate.validateMenuItem(quitMenu), "Private Window and Quit stay available during startup")
        let locationMenu = NSMenuItem(title:"Location",action:#selector(AppDelegate.location),keyEquivalent:"")
        let settingsMenu = NSMenuItem(title:"Settings",action:#selector(AppDelegate.settings),keyEquivalent:"")
        check(!delegate.validateMenuItem(locationMenu) && !delegate.validateMenuItem(settingsMenu), "Startup disables normal location and settings menu actions")
        application.fixtureWindow = nil
        application.delegate = savedDelegate; delegate.windows = [:]
        var callbacks = 0, readyAtCallback = false
        reopened.metadataDidLoad = { callbacks += 1; readyAtCallback = reopened.savingEnabled && !reopened.awaitingInitialMetadata && reopened.persistedProfileIDs.contains(BrowserProfile.defaultID) }
        let privateStore = BrowserStore(isPrivate: true, dataRoot: root.appendingPathComponent("private"), metadataKeyAccess: access)
        check(!privateStore.awaitingInitialMetadata && privateStore.privateDataStore?.isPersistent == false, "Private browsing is independent of a blocked normal key")
        for _ in 0..<100 where !startupGate.pollStarted() { try await Task.sleep(for: .milliseconds(10)) }
        let overflowOwner = BrowserWindowOwner(store: reopened); let overflowLease = try overflowOwner.acquirePrimary()
        for _ in 0..<64 { _ = try overflowOwner.dispatchExternal(link) }
        var overflowRejected = false
        do { _ = try overflowOwner.dispatchExternal(link) } catch { overflowRejected = true }
        check(overflowRejected && overflowOwner.pendingExternalURLs.count == 64, "Waiting link queue is bounded and rejects overflow")
        // This owner shares a fixture store only to check queue teardown; do not release its final lease yet.
        startupGate.release.signal()
        for _ in 0..<200 where reopened.unlocking { try await Task.sleep(for: .milliseconds(10)) }
        check(reopened.savingEnabled && !reopened.awaitingInitialMetadata && !reopened.onboardingVisible, "Background lookup restores saved state after close/reopen")
        check(try Data(contentsOf: reopened.sessionURL) == before, "Unchanged saved document is not rewritten during initial restore")
        check(callbacks == 1 && readyAtCallback, "Ready callback follows durable profile identity and enabled saving")
        try await Task.sleep(for: .milliseconds(100)); hosting.layoutSubtreeIfNeeded()
        check(descendants(hosting, SidebarResizeHandle.Handle.self).count == 1, "Successful restore mounts normal chrome in the same native host")
        reopened.metadataDidLoad = nil; window.contentView = nil; window.close()
        let routed = owner.drainExternalLinks()
        check(routed.count == 1 && owner.pendingExternalURLs.isEmpty && routed.first == .space(reopened.space.id) && reopened.space.tabs.contains { $0.url == link.absoluteString }, "Queued link uses recovered routing once")
        check(owner.drainExternalLinks().isEmpty, "Repeated readiness cannot duplicate queued links")
        overflowOwner.release(overflowLease)
        check(overflowOwner.pendingExternalURLs.isEmpty && overflowOwner.drainExternalLinks().isEmpty, "Closed owners discard queued links and reject late draining")
        owner.release(lease); privateStore.shutdown()
        let rejected = BrowserStore(dataRoot: root, metadataKeyAccess: MetadataKeyAccess { _, _ in throw CocoaError(.fileReadNoPermission) })
        for _ in 0..<100 where rejected.unlocking { try await Task.sleep(for: .milliseconds(10)) }
        check(rejected.awaitingInitialMetadata && !rejected.unlocking && !rejected.savingEnabled, "Rejected access leaves a responsive recovery state")
        check(rejected.unlockLocalData(keyProvider: { key }), "Explicit retry can recover an initially rejected key")
        for _ in 0..<200 where rejected.unlocking { try await Task.sleep(for: .milliseconds(10)) }
        check(rejected.savingEnabled && !rejected.awaitingInitialMetadata, "Successful retry exits startup recovery")
        rejected.shutdown()
        let rejectedBytes = try Data(contentsOf: rejected.sessionURL)
        let wrong = BrowserStore(dataRoot: root, metadataKeyAccess: MetadataKeyAccess { _, _ in SymmetricKey(size: .bits256) })
        for _ in 0..<100 where wrong.unlocking { try await Task.sleep(for: .milliseconds(10)) }
        wrong.flush()
        let afterWrong = try Data(contentsOf: wrong.sessionURL)
        check(!wrong.savingEnabled && wrong.awaitingInitialMetadata && afterWrong == rejectedBytes, "Wrong-key startup preserves unreadable ciphertext")
        wrong.shutdown()
        let fresh = BrowserStore(dataRoot: root.appendingPathComponent("fresh"), metadataKeyAccess: MetadataKeyAccess { create, interactive in
            guard create && !interactive && !Thread.isMainThread else { throw CocoaError(.coderInvalidValue) }; return key
        })
        for _ in 0..<100 where fresh.unlocking { try await Task.sleep(for: .milliseconds(10)) }
        check(fresh.savingEnabled && !fresh.awaitingInitialMetadata && fresh.onboardingVisible && FileManager.default.fileExists(atPath:fresh.sessionURL.path), "Fresh background startup durably creates its document before onboarding")
        fresh.shutdown()
        let legacyRoot = root.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at:legacyRoot,withIntermediateDirectories:true)
        var legacy = Session(); legacy.spaces[0].tabs[0].url = "https://example.com/legacy"
        let legacyURL = legacyRoot.appendingPathComponent("session.json")
        try JSONEncoder().encode(legacy).write(to:legacyURL)
        let migrated = BrowserStore(dataRoot:legacyRoot,metadataKeyAccess:MetadataKeyAccess { _,_ in key })
        for _ in 0..<100 where migrated.unlocking { try await Task.sleep(for: .milliseconds(10)) }
        check(migrated.savingEnabled && migrated.selectedTab?.url == "https://example.com/legacy" && !migrated.onboardingVisible && !FileManager.default.fileExists(atPath:legacyURL.path), "Background restore encrypts legacy tabs before removing the source")
        migrated.shutdown()
        exit(failures == 0 ? 0 : 1)
    }
}
