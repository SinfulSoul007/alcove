import Foundation
import CryptoKit

public struct MetadataStore {
    public let url: URL
    public let key: SymmetricKey
    public let isPrivate: Bool
    public init(url: URL, key: SymmetricKey, isPrivate: Bool = false) { self.url = url; self.key = key; self.isPrivate = isPrivate }
    public func save<T: Encodable>(_ value: T) throws {
        guard !isPrivate else { return }
        let ownership = try MetadataOwnership.acquire(for:url); defer { ownership.release() }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let plaintext = try JSONEncoder().encode(value)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else { throw CocoaError(.fileWriteUnknown) }
        // A 0700 parent protects the temporary file used by Foundation's atomic write.
        try combined.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func load<T: Decodable>(_ type: T.Type) throws -> T? {
        guard !isPrivate, FileManager.default.fileExists(atPath: url.path) else { return nil }
        let ciphertext = try Data(contentsOf: url)
        let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext), using: key)
        return try JSONDecoder().decode(type, from: plaintext)
    }
}
