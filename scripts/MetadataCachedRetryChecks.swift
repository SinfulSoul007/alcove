import AppKit
import BrowserCore
import CryptoKit

private final class OwnedRetryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@main struct MetadataCachedRetryChecks {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        setbuf(stdout, nil)
        var checks = 0, failures = 0
        func check(_ value: Bool, _ name: String) {
            checks += 1; print("\(value ? "PASS" : "FAIL"): \(name)")
            if !value { failures += 1 }
        }
        func waitForRetry(_ store: BrowserStore) async throws {
            for _ in 0..<500 {
                if !store.unlocking { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            check(false, "Owned save retry completes")
        }
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("Alcove.CachedRetry." + UUID().uuidString)
        defer { try? files.removeItem(at: root) }
        let key = SymmetricKey(data: Data(repeating: 17, count: 32)) // Owned fixture key only.
        let unexpected = OwnedRetryProbe()
        let access = MetadataKeyAccess { _, _ in unexpected.increment(); throw CocoaError(.userCancelled) }
        let store = BrowserStore(dataRoot: root, keyProvider: { _ in key }, metadataKeyAccess: access)
        defer { store.shutdown() }
        store.flush()
        let backup = root.appendingPathComponent("prior-ciphertext")
        try files.moveItem(at: store.sessionURL, to: backup)
        try files.createDirectory(at: store.sessionURL, withIntermediateDirectories: false)
        store.session.spaces[0].tabs[0].title = "Pending owned title"
        store.flush()
        check(!store.savingEnabled && store.vault != nil, "An actual filesystem failure pauses writes while retaining the unlocked vault")
        try files.removeItem(at: store.sessionURL)
        try files.moveItem(at: backup, to: store.sessionURL)
        check(store.unlockLocalData(), "The paused owner can start a save retry")
        try await waitForRetry(store)
        check(unexpected.value == 0 && store.savingEnabled, "Save retry reuses the unlocked key without consulting the key provider")
        let saved = try store.vault?.load(BrowserDocument.self)
        check(saved?.session.spaces[0].tabs[0].title == "Pending owned title", "The retried transaction preserves and persists the pending live session")
        let damaged = Data([0])
        try damaged.write(to: store.sessionURL)
        store.savingEnabled = false
        check(store.unlockLocalData(), "An unreadable saved file can be checked with the cached key")
        try await waitForRetry(store)
        let afterDamagedRetry = try Data(contentsOf: store.sessionURL)
        check(!store.savingEnabled && afterDamagedRetry == damaged, "Cached-key retry still authenticates the saved file and never overwrites damaged ciphertext")
        check(unexpected.value == 0, "Ciphertext failure does not restart a Keychain lookup")
        let explicit = OwnedRetryProbe()
        check(store.unlockLocalData(keyProvider: { explicit.increment(); return key }), "An explicit replacement key provider remains available")
        try await waitForRetry(store)
        check(explicit.value == 1 && !store.savingEnabled, "Explicit key refresh is honored while invalid saved data remains protected")
        let privateStore = BrowserStore(isPrivate: true, dataRoot: root.appendingPathComponent("private"), metadataKeyAccess: access)
        privateStore.savingEnabled = false
        let beforePrivateRetry = unexpected.value
        check(!privateStore.unlockLocalData() && unexpected.value == beforePrivateRetry, "Private mode cannot start a cached or external key lookup")
        privateStore.shutdown()
        print("Cached metadata retry checks: \(checks) checked, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
