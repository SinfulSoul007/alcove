import Foundation
import CryptoKit
import Darwin

public enum EaselAssetError: LocalizedError {
    case invalidSize, unsafeEntry, invalidCiphertext, system(Int32)
    public var errorDescription: String? {
        switch self {
        case .invalidSize: return "A capture must contain between one byte and 32 MiB."
        case .unsafeEntry: return "The capture storage location changed or is not protected. Existing files were kept."
        case .invalidCiphertext: return "This saved capture is incomplete or damaged."
        case .system: return "Alcove could not access its saved capture storage."
        }
    }
}

/// The caller publishes an asset UUID in metadata only after put succeeds.
/// Private instances have neither a disk location nor a key dependency.
public final class EaselAssetStore {
    public let profileID: UUID
    private let disk: EaselAssetDirectory?
    private var memory: [UUID: Data] = [:]
    private let mutex = NSLock()
    fileprivate static let maximumBytes = 33_554_432

    public init(root: URL, profileID: UUID, key: SymmetricKey, ownership: MetadataOwnershipLease? = nil) throws {
        self.profileID = profileID
        disk = try EaselAssetDirectory(root: root, profileID: profileID, key: key, ownership: ownership)
    }
    public init(privateProfileID: UUID) { profileID = privateProfileID; disk = nil }

    public func put(_ data: Data) throws -> UUID {
        mutex.lock(); defer { mutex.unlock() }
        guard !data.isEmpty, data.count <= Self.maximumBytes else { throw EaselAssetError.invalidSize }
        if let disk { return try disk.put(data) }
        let id = UUID(); memory[id] = data; return id
    }
    public func read(_ id: UUID) throws -> Data? {
        mutex.lock(); defer { mutex.unlock() }
        if let disk { return try disk.read(id) }
        return memory[id]
    }
    public func remove(_ id: UUID) throws {
        mutex.lock(); defer { mutex.unlock() }
        if let disk { try disk.remove(id) } else { memory.removeValue(forKey: id) }
    }
}

/// Every operation stays relative to held directory descriptors. No asset path
/// component comes from a document string, URL or image filename.
private final class EaselAssetDirectory {
    let root: URL, profileID: UUID, key: SymmetricKey, ownership: MetadataOwnershipLease?
    let rootFD: Int32, easelsFD: Int32, profileFD: Int32

    init(root: URL, profileID: UUID, key: SymmetricKey, ownership: MetadataOwnershipLease?) throws {
        try ownership?.validate()
        guard root.isFileURL else { throw EaselAssetError.unsafeEntry }
        let normalizedRoot = root.standardizedFileURL
        self.root = normalizedRoot; self.profileID = profileID; self.key = key; self.ownership = ownership
        let rootFD = Darwin.open(normalizedRoot.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw EaselAssetError.system(errno) }
        var retainedRoot = false
        defer { if !retainedRoot { Darwin.close(rootFD) } }
        try Self.protectDirectory(rootFD)
        let easelsFD = try Self.openDirectory("Easels", in: rootFD)
        var retainedEasels = false
        defer { if !retainedEasels { Darwin.close(easelsFD) } }
        let profileFD = try Self.openDirectory(profileID.uuidString, in: easelsFD)
        var retainedProfile = false
        defer { if !retainedProfile { Darwin.close(profileFD) } }
        // Transfer descriptor ownership only after the complete chain validates.
        try Self.validateChain(root: normalizedRoot, profileID: profileID, ownership: ownership,
                               rootFD: rootFD, easelsFD: easelsFD, profileFD: profileFD)
        self.rootFD = rootFD; self.easelsFD = easelsFD; self.profileFD = profileFD
        retainedRoot = true; retainedEasels = true; retainedProfile = true
    }
    deinit { Darwin.close(profileFD); Darwin.close(easelsFD); Darwin.close(rootFD) }

    private static func protectDirectory(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), info.st_uid == geteuid() else { throw EaselAssetError.unsafeEntry }
        guard fchmod(fd, 0o700) == 0 else { throw EaselAssetError.system(errno) }
    }
    private static func openDirectory(_ name: String, in parent: Int32) throws -> Int32 {
        guard mkdirat(parent, name, 0o700) == 0 || errno == EEXIST else { throw EaselAssetError.system(errno) }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw EaselAssetError.system(errno) }
        do { try protectDirectory(fd); return fd }
        catch { Darwin.close(fd); throw error }
    }
    private static func sameDirectory(_ held: stat, _ current: stat) -> Bool {
        held.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) && current.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
            && held.st_uid == geteuid() && current.st_uid == geteuid()
            && held.st_mode & 0o777 == 0o700 && current.st_mode & 0o777 == 0o700
            && held.st_dev == current.st_dev && held.st_ino == current.st_ino
    }
    private func validate() throws {
        try Self.validateChain(root: root, profileID: profileID, ownership: ownership,
                               rootFD: rootFD, easelsFD: easelsFD, profileFD: profileFD)
    }
    private static func validateChain(root: URL, profileID: UUID, ownership: MetadataOwnershipLease?,
                                      rootFD: Int32, easelsFD: Int32, profileFD: Int32) throws {
        try ownership?.validate()
        var heldRoot = stat(), namedRoot = stat(), heldEasels = stat(), namedEasels = stat(), heldProfile = stat(), namedProfile = stat()
        guard fstat(rootFD, &heldRoot) == 0, lstat(root.path, &namedRoot) == 0,
              fstat(easelsFD, &heldEasels) == 0, fstatat(rootFD, "Easels", &namedEasels, AT_SYMLINK_NOFOLLOW) == 0,
              fstat(profileFD, &heldProfile) == 0, fstatat(easelsFD, profileID.uuidString, &namedProfile, AT_SYMLINK_NOFOLLOW) == 0,
              Self.sameDirectory(heldRoot, namedRoot), Self.sameDirectory(heldEasels, namedEasels), Self.sameDirectory(heldProfile, namedProfile) else { throw EaselAssetError.unsafeEntry }
    }
    private func name(_ id: UUID) -> String { id.uuidString + ".sealed" }
    private func authenticatedData(_ id: UUID) -> Data {
        Data("Alcove.EaselAsset.v1\u{0}\(profileID.uuidString)\u{0}\(id.uuidString)".utf8)
    }
    private func checkedFile(_ fd: Int32) throws -> stat {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_uid == geteuid(), info.st_nlink == 1, info.st_mode & 0o777 == 0o600 else { throw EaselAssetError.unsafeEntry }
        return info
    }
    private func openAsset(_ id: UUID) throws -> Int32? {
        // NONBLOCK lets us reject FIFOs after fstat, without waiting for a writer.
        let fd = openat(profileFD, name(id), O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw EaselAssetError.system(errno)
        }
        do { _ = try checkedFile(fd); return fd }
        catch { Darwin.close(fd); throw error }
    }

    func put(_ data: Data) throws -> UUID {
        try validate()
        let id = UUID()
        guard let bytes = try AES.GCM.seal(data, using: key, authenticating: authenticatedData(id)).combined else { throw EaselAssetError.invalidCiphertext }
        try validate()
        let fd = openat(profileFD, name(id), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw EaselAssetError.system(errno) }
        var published = false
        defer {
            Darwin.close(fd)
            if !published { _ = unlinkat(profileFD, name(id), 0) }
        }
        guard fchmod(fd, 0o600) == 0 else { throw EaselAssetError.system(errno) }
        _ = try checkedFile(fd)
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw EaselAssetError.system(count == 0 ? EIO : errno) }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw EaselAssetError.system(errno) }
        _ = try checkedFile(fd)
        try validate()
        published = true
        return id
    }

    func read(_ id: UUID) throws -> Data? {
        try validate()
        guard let fd = try openAsset(id) else { return nil }
        defer { Darwin.close(fd) }
        let initial = try checkedFile(fd)
        guard initial.st_size >= 29 else { throw EaselAssetError.invalidCiphertext }
        guard initial.st_size <= EaselAssetStore.maximumBytes + 28 else { throw EaselAssetError.invalidSize }
        var bytes = Data(count: Int(initial.st_size))
        try bytes.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw EaselAssetError.invalidCiphertext }
                offset += count
            }
        }
        let final = try checkedFile(fd)
        guard final.st_size == initial.st_size else { throw EaselAssetError.invalidCiphertext }
        let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: key, authenticating: authenticatedData(id))
        try validate()
        return plaintext
    }

    func remove(_ id: UUID) throws {
        try validate()
        guard let fd = try openAsset(id) else { return }
        defer { Darwin.close(fd) }
        _ = try checkedFile(fd)
        try validate()
        guard unlinkat(profileFD, name(id), 0) == 0 || errno == ENOENT else { throw EaselAssetError.system(errno) }
    }
}
