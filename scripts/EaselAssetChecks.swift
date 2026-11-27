import Foundation
import CryptoKit
import Darwin
import BrowserCore

@main struct EaselAssetChecks {
    static var failures = 0, checks = 0
    static func check(_ value: Bool, _ name: String) {
        checks += 1
        print("\(value ? "PASS" : "FAIL"): \(name)")
        if !value { failures += 1 }
    }
    static func rejects(_ name: String, _ body: () throws -> Void) {
        do { try body(); check(false, name) } catch { check(true, name) }
    }
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("Alcove-Easel-Checks-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        func directory(_ name: String) throws -> URL {
            let value = root.appendingPathComponent(name)
            try fm.createDirectory(at: value, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            return value
        }
        func assetURL(_ base: URL, _ owner: UUID, _ id: UUID) -> URL {
            base.appendingPathComponent("Easels").appendingPathComponent(owner.uuidString).appendingPathComponent(id.uuidString + ".sealed")
        }
        let normalRoot = try directory("normal"), owner = UUID(), key = SymmetricKey(size: .bits256)
        let store = try EaselAssetStore(root: normalRoot, profileID: owner, key: key)
        let bytes = Data("OWNED_EASEL_CAPTURE_BYTES_743c0648".utf8)
        let id = try store.put(bytes)
        let path = assetURL(normalRoot, owner, id)
        check(try store.read(id) == bytes, "A capture's exact bytes roundtrip through protected storage")
        let reopened = try EaselAssetStore(root: normalRoot, profileID: owner, key: key)
        check(try reopened.read(id) == bytes, "Capture references survive closing and reopening the asset store")
        let ciphertext = try Data(contentsOf: path)
        check(ciphertext != bytes && ciphertext.range(of: bytes) == nil, "The asset file contains authenticated ciphertext, without the owned plaintext marker")
        let fileMode = try fm.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber
        let directoryMode = try fm.attributesOfItem(atPath: path.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
        let parentMode = try fm.attributesOfItem(atPath: normalRoot.appendingPathComponent("Easels").path)[.posixPermissions] as? NSNumber
        check(fileMode?.intValue == 0o600 && directoryMode?.intValue == 0o700 && parentMode?.intValue == 0o700, "Asset files and containing directories are accessible only to their owner")
        let otherOwner = UUID()
        let other = try EaselAssetStore(root: normalRoot, profileID: otherOwner, key: key)
        try fm.copyItem(at: path, to: assetURL(normalRoot, otherOwner, id))
        rejects("Copying valid ciphertext into another profile cannot reveal the capture") { _ = try other.read(id) }
        let renamedID = UUID()
        try fm.copyItem(at: path, to: assetURL(normalRoot, owner, renamedID))
        rejects("Renaming valid ciphertext to another asset UUID fails authentication") { _ = try store.read(renamedID) }
        let wrongKey = try EaselAssetStore(root: normalRoot, profileID: owner, key: SymmetricKey(size: .bits256))
        rejects("A different metadata key cannot decrypt a capture") { _ = try wrongKey.read(id) }
        var damaged = ciphertext; damaged[damaged.count - 1] ^= 1
        try damaged.write(to: path)
        rejects("Modified ciphertext is reported as an error rather than a successful blank capture") { _ = try store.read(id) }
        let absent = UUID()
        check(try store.read(absent) == nil, "A missing capture is distinguishable from corrupted data")
        try store.remove(absent)
        check(true, "Removing an already missing capture is harmless")
        rejects("Empty capture writes are refused") { _ = try store.put(Data()) }
        rejects("Oversized capture writes are refused before a file is created") { _ = try store.put(Data(repeating: 42, count: 33_554_433)) }
        let boundary = Data(repeating: 37, count: 33_554_432)
        let largeID = try store.put(boundary)
        check(try store.read(largeID) == boundary, "A capture exactly at the byte limit is retained intact")
        try store.remove(largeID)
        let oversizedID = UUID(), oversizedPath = assetURL(normalRoot, owner, oversizedID)
        let handle = open(oversizedPath.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard handle >= 0 else { throw POSIXError(.EIO) }
        let truncateResult = ftruncate(handle, 33_554_461); close(handle)
        guard truncateResult == 0 else { throw POSIXError(.EIO) }
        rejects("Oversized ciphertext is rejected before allocation or decryption") { _ = try store.read(oversizedID) }
        let outside = root.appendingPathComponent("unrelated-owned.txt")
        try bytes.write(to: outside)
        let symlinkID = UUID(), symlinkPath = assetURL(normalRoot, owner, symlinkID)
        try fm.createSymbolicLink(at: symlinkPath, withDestinationURL: outside)
        rejects("An asset symlink cannot read an unrelated file") { _ = try store.read(symlinkID) }
        rejects("Removing an unsafe symlink never follows its target") { try store.remove(symlinkID) }
        check(try Data(contentsOf: outside) == bytes, "A rejected symlink operation leaves the target unchanged")
        let hardID = UUID(), hardPath = assetURL(normalRoot, owner, hardID)
        try fm.linkItem(at: outside, to: hardPath)
        rejects("A hardlinked file cannot become a protected capture") { _ = try store.read(hardID) }
        rejects("A hardlinked entry is refused during removal") { try store.remove(hardID) }
        let fifoID = UUID(), fifoPath = assetURL(normalRoot, owner, fifoID)
        guard mkfifo(fifoPath.path, 0o600) == 0 else { throw POSIXError(.EIO) }
        rejects("A FIFO is rejected without blocking the browser") { _ = try store.read(fifoID) }
        let dirID = UUID()
        try fm.createDirectory(at: assetURL(normalRoot, owner, dirID), withIntermediateDirectories: false)
        rejects("A directory cannot be treated as capture bytes") { _ = try store.read(dirID) }
        let retainedID = try store.put(bytes)
        let unrelated = path.deletingLastPathComponent().appendingPathComponent("keep.txt")
        try bytes.write(to: unrelated)
        try store.remove(id)
        let retainedBytes = try store.read(retainedID)
        check(!fm.fileExists(atPath: path.path) && retainedBytes == bytes && fm.fileExists(atPath: unrelated.path), "Removing one UUID preserves other captures and unrelated files")

        let swappedRoot = try directory("swapped")
        let swapped = try EaselAssetStore(root: swappedRoot, profileID: owner, key: key)
        let swappedID = try swapped.put(bytes)
        let held = swappedRoot.appendingPathComponent("Easels").appendingPathComponent(owner.uuidString)
        try fm.moveItem(at: held, to: swappedRoot.appendingPathComponent("retired"))
        try fm.createDirectory(at: held, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        rejects("A replaced profile directory cannot redirect reads") { _ = try swapped.read(swappedID) }
        rejects("A replaced profile directory cannot receive stale writes") { _ = try swapped.put(bytes) }
        rejects("A replaced profile directory cannot receive stale removals") { try swapped.remove(swappedID) }
        let movedRoot = try directory("moved-root")
        let moved = try EaselAssetStore(root: movedRoot, profileID: owner, key: key)
        let movedID = try moved.put(bytes)
        try fm.moveItem(at: movedRoot, to: root.appendingPathComponent("retired-root"))
        try fm.createDirectory(at: movedRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        rejects("Replacing the metadata root invalidates an already-open asset store") { _ = try moved.read(movedID) }
        let linkRoot = root.appendingPathComponent("root-link")
        try fm.createSymbolicLink(at: linkRoot, withDestinationURL: normalRoot)
        rejects("A symlink cannot be supplied as the metadata root") { _ = try EaselAssetStore(root: linkRoot, profileID: owner, key: key) }
        let linkParent = try directory("linked-parent")
        try fm.createSymbolicLink(at: linkParent.appendingPathComponent("Easels"), withDestinationURL: normalRoot)
        rejects("An existing symlink cannot become the Easels directory") { _ = try EaselAssetStore(root: linkParent, profileID: owner, key: key) }
        let leaseRoot = try directory("leased")
        let lease = try MetadataOwnership.acquire(for: leaseRoot.appendingPathComponent("metadata.sealed"))
        let leased = try EaselAssetStore(root: leaseRoot, profileID: owner, key: key, ownership: lease)
        let leasedID = try leased.put(bytes)
        lease.release()
        rejects("A revoked metadata lease prevents capture reads") { _ = try leased.read(leasedID) }
        rejects("A revoked metadata lease prevents capture writes") { _ = try leased.put(bytes) }
        rejects("A revoked metadata lease prevents capture deletion") { try leased.remove(leasedID) }
        let snapshot = try fm.subpathsOfDirectory(atPath: root.path).sorted()
        let privateStore = EaselAssetStore(privateProfileID: owner)
        let privateID = try privateStore.put(bytes)
        check(try privateStore.read(privateID) == bytes, "Private capture storage works without a key or filesystem root")
        check(try privateStore.read(retainedID) == nil, "A private store cannot read normal profile assets")
        let secondPrivate = EaselAssetStore(privateProfileID: owner)
        check(try secondPrivate.read(privateID) == nil, "Independent private sessions cannot inherit one another's captures")
        try privateStore.remove(privateID)
        check(try privateStore.read(privateID) == nil, "Removing a private capture releases its in-memory reference")
        check(try fm.subpathsOfDirectory(atPath: root.path).sorted() == snapshot, "Private operations create, modify or delete no filesystem entries")
        print("Easel asset checks: \(checks) checked, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
