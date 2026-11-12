import Foundation
import Darwin
import CryptoKit

public final class PreparedExtensionPackage: @unchecked Sendable {
    fileprivate let stateLock = NSLock()
    public let manifest:ExtensionManifest
    public let digest:String
    public let source:ExtensionSourceKind
    public let stagingURL:URL
    public let signerID:String?
    public let storeID:String?
    public let publisherVerified:Bool
    fileprivate let parent:ExtensionDirectory
    fileprivate let name:String
    fileprivate let registration:String
    fileprivate var directory:ExtensionDirectory?
    fileprivate init(manifest:ExtensionManifest,digest:String,source:ExtensionSourceKind,parent:ExtensionDirectory,name:String,directory:ExtensionDirectory,signerID:String? = nil,storeID:String? = nil,publisherVerified:Bool = false) {
        self.manifest = manifest; self.digest = digest; self.source = source; self.parent = parent; self.name = name; self.directory = directory
        registration = parent.registryID + "/" + name; ExtensionStageActivity.shared.add(registration)
        stagingURL = directory.url; self.signerID = signerID; self.storeID = storeID; self.publisherVerified = publisherVerified
    }
    public func discard() throws {
        stateLock.lock(); defer {stateLock.unlock()}
        guard let directory else { return }
        try parent.remove(name,matching:directory)
        self.directory = nil; ExtensionStageActivity.shared.remove(registration)
    }
    deinit { try? discard(); ExtensionStageActivity.shared.remove(registration) }
}
public struct InstalledExtensionPackage:Sendable {
    public let url:URL
    public let created:Bool
    public let digest:String
    fileprivate let parent:ExtensionDirectory?
    fileprivate let directory:ExtensionDirectory?
    public func removeIfCreated() throws {
        guard created, let parent, let directory, try parent.existingChild(digest) != nil else { return }
        try parent.remove(digest,matching:directory)
    }
}

public enum ExtensionPackage {
    /// Revalidate installed code through owned directory descriptors; saved metadata supplies no path.
    public static func inspectInstalled(record:BrowserExtensionRecord,profileID:UUID,packagesRoot:URL) throws -> (url:URL,manifest:ExtensionManifest) {
        guard profileID != BrowserProfile.zeroID, record.hasValidIdentity else {throw ExtensionValidationError.invalidResourcePath}
        let root = try ExtensionDirectory(url:packagesRoot,create:false,owned:true)
        let owner = try root.child(profileID.uuidString,create:false), package = try owner.child((record.packageID ?? record.id).uuidString,create:false)
        let revision = try package.child(record.packageDigest,create:false)
        let contents = try snapshot(revision,limits:.default,totalLimit:ExtensionPackageLimits.default.expandedBytes,excludeMetadata:false)
        guard fingerprint(contents) == record.packageDigest else {throw ExtensionValidationError.invalidArchive("installed resources changed; review the original package again")}
        let manifest = try inspectedManifest(contents)
        guard manifest.name == record.name, manifest.version == record.version, manifest.manifestVersion == record.manifestVersion,
              Set(manifest.requestedPermissions) == Set(record.requestedPermissions), Set(manifest.optionalPermissions) == Set(record.optionalPermissions),
              Set(manifest.hostPermissions) == Set(record.hostPermissions), Set(manifest.optionalHostPermissions) == Set(record.optionalHostPermissions),
              manifest.incognito == (record.incognito ?? "spanning") else {throw ExtensionValidationError.invalidArchive("installed manifest does not match its reviewed catalog entry")}
        try root.verifyPath();try owner.verifyPath();try package.verifyPath();try revision.verifyPath()
        return (revision.url,manifest)
    }
    public static func prepare(at sourceURL:URL,stagingRoot:URL,expectedStoreID:String? = nil,requireStoreProof:Bool = false,limits:ExtensionPackageLimits = .default,progress:(Int)->Void = {_ in}) throws -> PreparedExtensionPackage {
        try Task.checkCancellation()
        if let expectedStoreID, !BrowserExtensionRecord.validExternalID(expectedStoreID) { throw ExtensionValidationError.invalidArchive("invalid expected extension identity") }
        let sourcePath = try ExtensionDirectory.path(sourceURL)
        var before = stat(); guard lstat(sourcePath,&before) == 0 else { throw ExtensionDirectory.error() }
        let entries:[ExtensionZIPEntry], source:ExtensionSourceKind, signerID:String?, storeID:String?, publisherVerified:Bool
        if before.st_mode & S_IFMT == S_IFDIR {
            guard expectedStoreID == nil, !requireStoreProof else { throw ExtensionValidationError.invalidArchive("unsigned resources cannot supply a store identity or publisher proof") }
            let directory = try ExtensionDirectory(url:sourceURL,create:false,owned:false)
            progress(0)
            entries = try snapshot(directory,limits:limits,totalLimit:limits.inputBytes,excludeMetadata:true,progress:progress)
            source = .folder; signerID = nil; storeID = nil; publisherVerified = false
        } else if before.st_mode & S_IFMT == S_IFREG {
            let descriptor = open(sourcePath,O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            guard descriptor >= 0 else { throw ExtensionDirectory.error() }; defer { close(descriptor) }
            progress(0)
            let bytes = try readFile(descriptor,expected:before,limit:limits.inputBytes,progress:progress)
            var after = stat(); guard lstat(sourcePath,&after) == 0, sameSnapshot(before,after) else { throw ExtensionDirectory.error() }
            if bytes.prefix(4) == Data("Cr24".utf8) {
                let verified = try ExtensionCRX.verify(bytes,expectedID:expectedStoreID,requireStoreProof:requireStoreProof,limits:limits)
                entries = try ExtensionZIP.read(verified.archive,limits:limits)
                source = requireStoreProof ? .webStore : .crx3; signerID = verified.extensionID
                storeID = requireStoreProof ? verified.extensionID : nil; publisherVerified = verified.publisherVerified
            } else {
                guard expectedStoreID == nil, !requireStoreProof else { throw ExtensionValidationError.invalidArchive("unsigned resources cannot supply a store identity or publisher proof") }
                entries = try ExtensionZIP.read(bytes,limits:limits); source = .zip; signerID = nil; storeID = nil; publisherVerified = false
            }
        } else { throw ExtensionValidationError.invalidResourcePath }
        let manifest = try inspectedManifest(entries)
        let digest = fingerprint(entries)
        let parent = try ExtensionDirectory(url:stagingRoot,create:true,owned:true), name = UUID().uuidString
        let stage = try parent.child(name,create:true,exclusive:true)
        let registration = parent.registryID + "/" + name; ExtensionStageActivity.shared.add(registration)
        do {
            try write(entries,to:stage)
            try parent.verifyPath(); try stage.verifyPath()
            return PreparedExtensionPackage(manifest:manifest,digest:digest,source:source,parent:parent,name:name,directory:stage,signerID:signerID,storeID:storeID,publisherVerified:publisherVerified)
        } catch {
            try? parent.remove(name,matching:stage); ExtensionStageActivity.shared.remove(registration); throw error
        }
    }
    public static func publish(_ package:PreparedExtensionPackage,profileID:UUID,extensionID:UUID,packagesRoot:URL) throws -> InstalledExtensionPackage {
        package.stateLock.lock(); defer {package.stateLock.unlock()}
        try Task.checkCancellation()
        guard profileID != BrowserProfile.zeroID, extensionID != BrowserProfile.zeroID, BrowserExtensionRecord.validDigest(package.digest), let stage = package.directory else { throw ExtensionValidationError.invalidResourcePath }
        try package.parent.verifyChild(package.name,matching:stage)
        let entries = try snapshot(stage,limits:.default,totalLimit:ExtensionPackageLimits.default.expandedBytes,excludeMetadata:false)
        guard fingerprint(entries) == package.digest, try inspectedManifest(entries) == package.manifest else { throw ExtensionValidationError.invalidArchive("prepared resources changed; inspect again") }
        let root = try ExtensionDirectory(url:packagesRoot,create:true,owned:true)
        let owner = try root.child(profileID.uuidString,create:true), record = try owner.child(extensionID.uuidString,create:true)
        try root.verifyPath(); try owner.verifyPath(); try record.verifyPath()
        if let existing = try record.existingChild(package.digest) {
            let contents = try snapshot(existing,limits:.default,totalLimit:ExtensionPackageLimits.default.expandedBytes,excludeMetadata:false)
            guard fingerprint(contents) == package.digest else { throw ExtensionValidationError.invalidArchive("installed resources changed; remove the damaged revision before retrying") }
            return InstalledExtensionPackage(url:existing.url,created:false,digest:package.digest,parent:nil,directory:nil)
        }
        guard renameatx_np(package.parent.fd,package.name,record.fd,package.digest,UInt32(RENAME_EXCL)) == 0 else {
            // Another install is never replaced or claimed as cleanup owned by this invocation.
            throw ExtensionDirectory.error()
        }
        package.directory = nil; ExtensionStageActivity.shared.remove(package.registration)
        do {
            guard fsync(record.fd) == 0, fsync(package.parent.fd) == 0 else { throw ExtensionDirectory.error() }
            try root.verifyPath(); try owner.verifyPath(); try record.verifyPath()
        } catch {
            try? record.remove(package.digest,matching:stage); throw error
        }
        return InstalledExtensionPackage(url:record.url.appendingPathComponent(package.digest,isDirectory:true),created:true,digest:package.digest,parent:record,directory:stage)
    }
    public static func removeRevision(profileID:UUID,extensionID:UUID,digest:String,packagesRoot:URL) throws {
        guard profileID != BrowserProfile.zeroID, extensionID != BrowserProfile.zeroID, BrowserExtensionRecord.validDigest(digest) else { throw ExtensionValidationError.invalidResourcePath }
        var info = stat()
        if lstat(try ExtensionDirectory.path(packagesRoot),&info) != 0 { if errno == ENOENT { return }; throw ExtensionDirectory.error() }
        let root = try ExtensionDirectory(url:packagesRoot,create:false,owned:true)
        guard let owner = try root.existingChild(profileID.uuidString), let record = try owner.existingChild(extensionID.uuidString), let revision = try record.existingChild(digest) else { return }
        try root.verifyPath(); try owner.verifyPath(); try record.remove(digest,matching:revision)
    }
    /// Call under the metadata owner's publication/maintenance gate, before loading native contexts.
    /// References are authoritative even if their resources need repair; active previews are retained.
    @discardableResult public static func reconcile(packagesRoot:URL,stagingRoot:URL,libraries:[ProfileLibrary]) throws -> Int {
        var retained = Set<String>(), protectedOwners = Set<UUID>(), removed = 0
        for library in libraries {
            for record in library.library.extensions ?? [] {
                guard BrowserExtensionRecord.validDigest(record.packageDigest), (record.packageID ?? record.id) != BrowserProfile.zeroID else { protectedOwners.insert(library.profileID); continue }
                retained.insert(library.profileID.uuidString + "/" + (record.packageID ?? record.id).uuidString + "/" + record.packageDigest)
            }
        }
        func existingRoot(_ url:URL) throws -> ExtensionDirectory? {
            var info = stat()
            if lstat(try ExtensionDirectory.path(url),&info) != 0 { if errno == ENOENT { return nil }; throw ExtensionDirectory.error() }
            return try ExtensionDirectory(url:url,create:false,owned:true)
        }
        if let root = try existingRoot(packagesRoot) {
            for ownerName in try root.names() {
                try Task.checkCancellation()
                guard let ownerID = UUID(uuidString:ownerName), !protectedOwners.contains(ownerID) else { continue }
                let owner = try root.child(ownerName,create:false)
                for recordName in try owner.names() {
                    try Task.checkCancellation()
                    guard let recordID = UUID(uuidString:recordName) else { continue }
                    let record = try owner.child(recordName,create:false)
                    for digest in try record.names() {
                        try Task.checkCancellation()
                        guard BrowserExtensionRecord.validDigest(digest), !retained.contains(ownerID.uuidString + "/" + recordID.uuidString + "/" + digest) else { continue }
                        let revision = try record.child(digest,create:false)
                        try record.remove(digest,matching:revision); removed += 1
                    }
                    if try record.names().isEmpty { try owner.remove(recordName,matching:record) }
                }
                if try owner.names().isEmpty { try root.remove(ownerName,matching:owner) }
            }
            try root.verifyPath()
        }
        if let root = try existingRoot(stagingRoot) {
            for name in try root.names() {
                try Task.checkCancellation()
                guard let id = UUID(uuidString:name), !ExtensionStageActivity.shared.contains(root.registryID + "/" + id.uuidString) else { continue }
                let stage = try root.child(name,create:false)
                try root.remove(name,matching:stage); removed += 1
            }
            try root.verifyPath()
        }
        return removed
    }
    static func inspectedManifest(_ entries:[ExtensionZIPEntry]) throws -> ExtensionManifest {
        let files = Dictionary(uniqueKeysWithValues:entries.filter{!$0.isDirectory}.map { ($0.path,$0.data) })
        guard let bytes = files["manifest.json"] else { throw ExtensionValidationError.invalidManifest("manifest.json is missing from the package root") }
        let manifest = try ExtensionManifest.parse(bytes,readResource:{files[$0]})
        guard manifest.resourcePaths.allSatisfy({files[$0] != nil}) else { throw ExtensionValidationError.invalidManifest("a declared entry resource is missing") }
        return manifest
    }
    static func fingerprint(_ entries:[ExtensionZIPEntry]) -> String {
        var hash = SHA256()
        // Directory records are structural; absent/explicit empty directories do not change executable resources.
        for entry in entries.filter({!$0.isDirectory}).sorted(by:{$0.path.utf8.lexicographicallyPrecedes($1.path.utf8)}) {
            let name = Data(entry.path.utf8)
            for value in [UInt64(name.count),UInt64(entry.data.count)] {
                var little = value.littleEndian; withUnsafeBytes(of:&little) { hash.update(data:Data($0)) }
            }
            hash.update(data:name); hash.update(data:entry.data)
        }
        return hash.finalize().map{String(format:"%02x",$0)}.joined()
    }
    private static func write(_ entries:[ExtensionZIPEntry],to root:ExtensionDirectory) throws {
        for entry in entries.sorted(by:{$0.path < $1.path}) {
            try Task.checkCancellation()
            let components = entry.path.split(separator:"/").map(String.init)
            var parent = root
            for name in components.dropLast() { parent = try parent.child(name,create:true) }
            let name = components.last!
            if entry.isDirectory { _ = try parent.child(name,create:true); continue }
            let file = openat(parent.fd,name,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,mode_t(0o600))
            guard file >= 0 else { throw ExtensionDirectory.error() }
            do {
                try entry.data.withUnsafeBytes { buffer in
                    var offset = 0
                    while offset < buffer.count {
                        try Task.checkCancellation()
                        let count = Darwin.write(file,buffer.baseAddress!.advanced(by:offset),min(65_536,buffer.count-offset))
                        if count < 0 && errno == EINTR { continue }
                        guard count > 0 else { throw ExtensionDirectory.error() }; offset += count
                    }
                }
                guard fsync(file) == 0, fsync(parent.fd) == 0 else { throw ExtensionDirectory.error() }; close(file)
            } catch { close(file); throw error }
        }
        guard fsync(root.fd) == 0 else { throw ExtensionDirectory.error() }
    }
    private static func snapshot(_ root:ExtensionDirectory,limits:ExtensionPackageLimits,totalLimit:Int,excludeMetadata:Bool,progress:(Int)->Void = {_ in}) throws -> [ExtensionZIPEntry] {
        var entries:[ExtensionZIPEntry] = [], names = Set<String>(), total = 0, visited = 0
        let ignored:Set<String> = [".git",".svn",".hg",".DS_Store","__MACOSX"]
        func walk(_ directory:ExtensionDirectory,_ prefix:String) throws {
            let original = try directory.status()
            for name in try directory.names() {
                try Task.checkCancellation()
                if excludeMetadata && ignored.contains(name) { continue }
                visited += 1; guard visited <= limits.entries else { throw ExtensionValidationError.packageTooLarge }
                let path = try ExtensionResourcePath.normalized(prefix + name)
                guard names.insert(ExtensionZIP.collisionKey(path)).inserted else { throw ExtensionValidationError.invalidResourcePath }
                var info = stat(); guard fstatat(directory.fd,name,&info,AT_SYMLINK_NOFOLLOW) == 0 else { throw ExtensionDirectory.error() }
                if info.st_mode & S_IFMT == S_IFDIR {
                    let child = try directory.child(name,create:false)
                    guard sameObject(info,try child.status()) else { throw ExtensionDirectory.error() }
                    entries.append(ExtensionZIPEntry(path:path,isDirectory:true,data:Data()))
                    try walk(child,path + "/"); try directory.verifyChild(name,matching:child)
                } else if info.st_mode & S_IFMT == S_IFREG {
                    let descriptor = openat(directory.fd,name,O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
                    guard descriptor >= 0 else { throw ExtensionDirectory.error() }
                    let contents:Data
                    do {
                        let perFile = path == "manifest.json" ? min(limits.fileBytes,1_048_576) : limits.fileBytes
                        contents = try readFile(descriptor,expected:info,limit:min(perFile,totalLimit - total),progress:{progress(total + $0)}); close(descriptor)
                    } catch { close(descriptor); throw error }
                    var after = stat(); guard fstatat(directory.fd,name,&after,AT_SYMLINK_NOFOLLOW) == 0, sameSnapshot(info,after) else { throw ExtensionDirectory.error() }
                    total += contents.count
                    entries.append(ExtensionZIPEntry(path:path,isDirectory:false,data:contents))
                } else { throw ExtensionValidationError.invalidResourcePath }
            }
            guard sameSnapshot(original,try directory.status()) else { throw ExtensionDirectory.error() }
            try directory.verifyPath()
        }
        try walk(root,""); return entries
    }
    private static func readFile(_ fd:Int32,expected:stat,limit:Int,progress:(Int)->Void = {_ in}) throws -> Data {
        var before = stat(); guard fstat(fd,&before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1, sameSnapshot(expected,before) else { throw ExtensionValidationError.invalidResourcePath }
        guard before.st_size >= 0, before.st_size <= limit else { throw ExtensionValidationError.packageTooLarge }
        var result = Data(), buffer = [UInt8](repeating:0,count:65_536)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd,$0.baseAddress,$0.count) }
            if count < 0 && errno == EINTR { continue }; guard count >= 0 else { throw ExtensionDirectory.error() }
            if count == 0 { break }
            guard count <= limit - result.count else { throw ExtensionValidationError.packageTooLarge }
            result.append(contentsOf:buffer.prefix(count)); progress(result.count)
        }
        var after = stat(); guard fstat(fd,&after) == 0, sameSnapshot(before,after), result.count == before.st_size else { throw ExtensionDirectory.error() }
        return result
    }
    fileprivate static func sameObject(_ left:stat,_ right:stat) -> Bool { left.st_dev == right.st_dev && left.st_ino == right.st_ino && left.st_mode & S_IFMT == right.st_mode & S_IFMT }
    private static func sameSnapshot(_ left:stat,_ right:stat) -> Bool {
        sameObject(left,right) && left.st_size == right.st_size && left.st_nlink == right.st_nlink
            && left.st_mtimespec.tv_sec == right.st_mtimespec.tv_sec && left.st_mtimespec.tv_nsec == right.st_mtimespec.tv_nsec
            && left.st_ctimespec.tv_sec == right.st_ctimespec.tv_sec && left.st_ctimespec.tv_nsec == right.st_ctimespec.tv_nsec
    }
}

fileprivate final class ExtensionStageActivity: @unchecked Sendable {
    static let shared = ExtensionStageActivity()
    private let lock = NSLock()
    private var registrations = Set<String>()
    func add(_ key:String) { lock.lock(); defer{lock.unlock()}; registrations.insert(key) }
    func remove(_ key:String) { lock.lock(); defer{lock.unlock()}; registrations.remove(key) }
    func contains(_ key:String) -> Bool { lock.lock(); defer{lock.unlock()}; return registrations.contains(key) }
}

fileprivate final class ExtensionRemovalBudget { var entries = 0 }

fileprivate final class ExtensionDirectory: @unchecked Sendable {
    let fd:Int32
    let url:URL
    let owned:Bool
    private let identity:stat
    var registryID:String { "\(identity.st_dev):\(identity.st_ino)" }
    static func error() -> ExtensionValidationError { .invalidArchive("package files changed or could not be accessed safely") }
    static func path(_ url:URL) throws -> String {
        guard url.isFileURL else { throw ExtensionValidationError.invalidResourcePath }
        var path = url.standardizedFileURL.path
        guard !path.utf8.contains(0) else { throw ExtensionValidationError.invalidResourcePath }
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }; return path
    }
    init(url:URL,create:Bool,owned:Bool) throws {
        let path = try Self.path(url); var before = stat()
        if lstat(path,&before) != 0 {
            guard errno == ENOENT, create else { throw Self.error() }
            let parent = try Self(url:url.deletingLastPathComponent(),create:false,owned:false)
            guard mkdirat(parent.fd,url.lastPathComponent,mode_t(0o700)) == 0 || errno == EEXIST else { throw Self.error() }
            guard fsync(parent.fd) == 0, fstatat(parent.fd,url.lastPathComponent,&before,AT_SYMLINK_NOFOLLOW) == 0 else { throw Self.error() }
        }
        guard before.st_mode & S_IFMT == S_IFDIR else { throw ExtensionValidationError.invalidResourcePath }
        let descriptor = open(path,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.error() }
        var info = stat()
        guard fstat(descriptor,&info) == 0, ExtensionPackage.sameObject(before,info), !owned || info.st_uid == getuid() else { close(descriptor); throw Self.error() }
        if owned && fchmod(descriptor,mode_t(0o700)) != 0 { close(descriptor); throw Self.error() }
        var current = stat()
        guard lstat(path,&current) == 0, ExtensionPackage.sameObject(info,current) else { close(descriptor); throw Self.error() }
        // All fallible initialization finishes before ownership transfers to deinit.
        fd = descriptor; self.url = URL(fileURLWithPath:path,isDirectory:true); self.owned = owned; identity = info
    }
    private init(fd:Int32,url:URL,owned:Bool,identity:stat) { self.fd = fd; self.url = url; self.owned = owned; self.identity = identity }
    deinit { close(fd) }
    func status() throws -> stat { var info = stat(); guard fstat(fd,&info) == 0, ExtensionPackage.sameObject(identity,info) else { throw Self.error() }; return info }
    func verifyPath() throws {
        var info = stat(); guard lstat(try Self.path(url),&info) == 0, ExtensionPackage.sameObject(identity,info) else { throw Self.error() }
    }
    func verifyChild(_ name:String,matching child:ExtensionDirectory) throws {
        var info = stat(); guard fstatat(fd,name,&info,AT_SYMLINK_NOFOLLOW) == 0, ExtensionPackage.sameObject(info,try child.status()) else { throw Self.error() }
    }
    func existingChild(_ name:String) throws -> ExtensionDirectory? {
        var info = stat()
        if fstatat(fd,name,&info,AT_SYMLINK_NOFOLLOW) != 0 { if errno == ENOENT { return nil }; throw Self.error() }
        return try child(name,create:false)
    }
    func child(_ name:String,create:Bool,exclusive:Bool = false) throws -> ExtensionDirectory {
        guard !name.contains("/"), try ExtensionResourcePath.normalized(name) == name else { throw ExtensionValidationError.invalidResourcePath }
        if create {
            let result = mkdirat(fd,name,mode_t(0o700))
            guard result == 0 || (!exclusive && errno == EEXIST) else { throw Self.error() }
            if result == 0 && fsync(fd) != 0 { throw Self.error() }
        }
        var before = stat(); guard fstatat(fd,name,&before,AT_SYMLINK_NOFOLLOW) == 0, before.st_mode & S_IFMT == S_IFDIR else { throw Self.error() }
        let descriptor = openat(fd,name,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.error() }
        var info = stat(); guard fstat(descriptor,&info) == 0, ExtensionPackage.sameObject(before,info), !owned || info.st_uid == getuid() else { close(descriptor); throw Self.error() }
        if owned && fchmod(descriptor,mode_t(0o700)) != 0 { close(descriptor); throw Self.error() }
        return ExtensionDirectory(fd:descriptor,url:url.appendingPathComponent(name,isDirectory:true),owned:owned,identity:info)
    }
    func names() throws -> [String] {
        let descriptor = openat(fd,".",O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.error() }
        guard let directory = fdopendir(descriptor) else { close(descriptor); throw Self.error() }; defer { closedir(directory) }
        var names:[String] = []
        while true {
            errno = 0; guard let item = readdir(directory) else { guard errno == 0 else { throw Self.error() }; break }
            let bytes = withUnsafeBytes(of:item.pointee.d_name) { Data($0.prefix(Int(item.pointee.d_namlen))) }
            guard let name = String(data:bytes,encoding:.utf8) else { throw ExtensionValidationError.invalidResourcePath }
            if name == "." || name == ".." { continue }
            guard names.count < 10_000 else { throw ExtensionValidationError.packageTooLarge }; names.append(name)
        }
        return names.sorted()
    }
    func remove(_ name:String,matching child:ExtensionDirectory,depth:Int = 0,budget:ExtensionRemovalBudget = ExtensionRemovalBudget()) throws {
        guard depth <= 64 else { throw ExtensionValidationError.packageTooLarge }
        guard owned, child.owned else { throw Self.error() }
        try verifyChild(name,matching:child)
        for entry in try child.names() {
            budget.entries += 1; guard budget.entries <= 10_000 else { throw ExtensionValidationError.packageTooLarge }
            var info = stat(); guard fstatat(child.fd,entry,&info,AT_SYMLINK_NOFOLLOW) == 0 else { throw Self.error() }
            if info.st_mode & S_IFMT == S_IFDIR { let nested = try child.child(entry,create:false); try child.remove(entry,matching:nested,depth:depth + 1,budget:budget) }
            else { guard unlinkat(child.fd,entry,0) == 0 else { throw Self.error() } }
        }
        try verifyChild(name,matching:child)
        guard unlinkat(fd,name,AT_REMOVEDIR) == 0 else { throw Self.error() }
    }
}
