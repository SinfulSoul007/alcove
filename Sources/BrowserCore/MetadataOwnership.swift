import Foundation
import Darwin

public enum MetadataOwnershipError: Error, LocalizedError, Equatable {
    case inUse, unsafeFile, system(Int32)
    public var errorDescription: String? {
        switch self {
        case .inUse: return "Another copy of Alcove is using this saved profile. Close that copy, then try again. Private browsing is available now."
        case .unsafeFile: return "Alcove couldn’t safely open its local data folder. Existing data was kept."
        case .system(let code): return "Alcove couldn’t access its saved profile. Existing data was kept. " + NSError(domain:NSPOSIXErrorDomain,code:Int(code)).localizedDescription
        }
    }
}
fileprivate final class OwnershipEntry {
    let descriptor: Int32
    let directoryDescriptor: Int32
    var count = 1
    init(_ descriptor: Int32, directoryDescriptor: Int32) { self.descriptor = descriptor; self.directoryDescriptor = directoryDescriptor }
}

/// Cooperating processes never share a live normal-profile writer. The lock file stays in place;
/// unlinking it could let another process lock a different inode while an old writer still runs.
public enum MetadataOwnership {
    private static let mutex = NSLock()
    private static let fileLock: (Int32, Int32) -> Int32 = flock
    private static var entries: [String: OwnershipEntry] = [:]
    public static func acquire(for metadataURL: URL) throws -> MetadataOwnershipLease {
        mutex.lock(); defer { mutex.unlock() }
        let directory = metadataURL.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let path = directory.appendingPathComponent("metadata-writer.lock").path
        if let entry = entries[path] {
            try validate(entry,path:path)
            entry.count += 1; return MetadataOwnershipLease(path:path,entry:entry)
        }
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:directory.path)
        let directoryDescriptor = Darwin.open(directory.path,O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directoryDescriptor >= 0 else { throw MetadataOwnershipError.unsafeFile }
        var retained = false
        defer { if !retained { Darwin.close(directoryDescriptor) } }
        let descriptor = Darwin.open(path,O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,mode_t(0o600))
        guard descriptor >= 0 else { throw errno == ELOOP ? MetadataOwnershipError.unsafeFile : .system(errno) }
        defer { if !retained { Darwin.close(descriptor) } }
        var attributes = stat()
        guard fstat(descriptor,&attributes) == 0 else { throw MetadataOwnershipError.system(errno) }
        guard attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), attributes.st_uid == geteuid(), attributes.st_nlink == 1 else { throw MetadataOwnershipError.unsafeFile }
        guard fileLock(descriptor,LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            throw code == EWOULDBLOCK || code == EAGAIN ? MetadataOwnershipError.inUse : .system(code)
        }
        guard fchmod(descriptor,mode_t(0o600)) == 0 else { throw MetadataOwnershipError.system(errno) }
        let entry = OwnershipEntry(descriptor,directoryDescriptor:directoryDescriptor)
        try validate(entry,path:path)
        entries[path] = entry; retained = true
        return MetadataOwnershipLease(path:path,entry:entry)
    }
    private static func validate(_ entry:OwnershipEntry,path:String) throws {
        var heldDirectory = stat(), currentDirectory = stat(), heldFile = stat(), currentFile = stat()
        let directory = URL(fileURLWithPath:path).deletingLastPathComponent().path
        guard fstat(entry.directoryDescriptor,&heldDirectory) == 0, lstat(directory,&currentDirectory) == 0,
              currentDirectory.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), currentDirectory.st_uid == geteuid(),
              currentDirectory.st_dev == heldDirectory.st_dev, currentDirectory.st_ino == heldDirectory.st_ino,
              fstat(entry.descriptor,&heldFile) == 0, lstat(path,&currentFile) == 0,
              currentFile.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), currentFile.st_uid == geteuid(),
              currentFile.st_nlink == 1, heldFile.st_nlink == 1,
              currentFile.st_dev == heldFile.st_dev, currentFile.st_ino == heldFile.st_ino else { throw MetadataOwnershipError.unsafeFile }
    }
    fileprivate static func validate(_ lease:MetadataOwnershipLease) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard !lease.released, entries[lease.path] === lease.entry else { throw MetadataOwnershipError.unsafeFile }
        try validate(lease.entry,path:lease.path)
    }
    fileprivate static func release(_ lease: MetadataOwnershipLease) {
        mutex.lock(); defer { mutex.unlock() }
        guard !lease.released else { return }; lease.released = true
        guard entries[lease.path] === lease.entry else { return }
        lease.entry.count -= 1
        if lease.entry.count == 0 {
            entries.removeValue(forKey:lease.path)
            _ = fileLock(lease.entry.descriptor,LOCK_UN); Darwin.close(lease.entry.descriptor); Darwin.close(lease.entry.directoryDescriptor)
        }
    }
}

public final class MetadataOwnershipLease: @unchecked Sendable {
    fileprivate let path: String
    fileprivate let entry: OwnershipEntry
    fileprivate var released = false
    fileprivate init(path:String,entry:OwnershipEntry) { self.path = path; self.entry = entry }
    public func release() { MetadataOwnership.release(self) }
    public func validate() throws { try MetadataOwnership.validate(self) }
    deinit { release() }
}
