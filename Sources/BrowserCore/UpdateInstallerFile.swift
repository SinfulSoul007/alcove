import CryptoKit
import Darwin
import Foundation

public enum UpdateInstallerVerification: Equatable, Sendable {
    case matches, sizeMismatch, checksumMismatch
}

extension UpdateAsset {
    public func verifyInstaller(at url: URL) throws -> UpdateInstallerVerification? {
        guard let sha256 else { return nil }
        let file = try UpdateInstallerFile(url)
        guard file.size == size else { return .sizeMismatch }
        return try file.digest() == sha256 ? .matches : .checksumMismatch
    }
}

extension UpdateReleaseManifest.Installer {
    public init(contentsOf url: URL) throws {
        let file = try UpdateInstallerFile(url)
        self.init(filename: url.lastPathComponent, size: file.size, sha256: try file.digest())
    }
}

/// Hash one open regular file, bounded by the size recorded when it was opened.
private struct UpdateInstallerFile {
    private let handle: FileHandle
    private let initial: stat
    var size: Int64 { initial.st_size }

    init(_ url: URL) throws {
        guard url.isFileURL else { throw ReadError.unreadable }
        let descriptor: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else { throw ReadError.unreadable }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else {
            close(descriptor)
            throw ReadError.unreadable
        }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        initial = info
    }

    func digest() throws -> String {
        var hash = SHA256()
        var remaining = size
        while remaining > 0 {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: Int(min(remaining, 1_048_576))), !chunk.isEmpty else {
                throw ReadError.modified
            }
            remaining -= Int64(chunk.count)
            hash.update(data: chunk)
        }
        try Task.checkCancellation()
        let trailingBytes = try handle.read(upToCount: 1) ?? Data()
        var latest = stat()
        guard trailingBytes.isEmpty,
              fstat(handle.fileDescriptor, &latest) == 0, latest.st_size == size,
              latest.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec,
              latest.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec,
              latest.st_ctimespec.tv_sec == initial.st_ctimespec.tv_sec,
              latest.st_ctimespec.tv_nsec == initial.st_ctimespec.tv_nsec else { throw ReadError.modified }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private enum ReadError: LocalizedError {
        case unreadable, modified
        var errorDescription: String? {
            switch self {
            case .unreadable: "Choose a readable installer file."
            case .modified: "The installer changed while it was being read."
            }
        }
    }
}
