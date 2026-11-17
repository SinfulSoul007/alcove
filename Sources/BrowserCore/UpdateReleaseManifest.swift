import CryptoKit
import Foundation

public struct AuthenticatedUpdate: Equatable, Sendable {
    public let commit: String
    public let asset: UpdateAsset
}

public enum UpdateReleaseManifest {
    public static let payloadFilename = "Alcove-update-manifest-v1.json"
    public static let signatureFilename = "Alcove-update-manifest-v1.sig"
    public static let maximumPayloadBytes = 64 * 1024
    private static let product = "dev.openbrowser.mac"

    public struct Installer: Codable, Sendable {
        public let filename: String
        public let size: Int64
        public let sha256: String

        public init(filename: String, size: Int64, sha256: String) {
            self.filename = filename
            self.size = size
            self.sha256 = sha256
        }
    }

    private struct Payload: Codable {
        let version: Int
        let product: String
        let tag: String
        let commit: String
        let installers: [Installer]
    }

    public enum InvalidManifest: LocalizedError {
        case invalidSignature, malformed, mismatchedRelease, mismatchedInstaller

        public var errorDescription: String? {
            switch self {
            case .invalidSignature: "Alcove could not verify this release’s signature."
            case .malformed: "Alcove could not read this release’s signed manifest."
            case .mismatchedRelease: "The signed manifest is for a different product or release."
            case .mismatchedInstaller: "The installer disagrees with the signed release manifest."
            }
        }
    }

    /// The publisher signs these exact bytes and distributes the signature separately.
    public static func makePayload(tag: String, commit: String, installers: [Installer]) throws -> Data {
        let manifest = Payload(version: 1, product: product, tag: tag, commit: commit,
                               installers: installers.sorted { $0.filename < $1.filename })
        try validate(manifest)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(manifest)
    }

    public static func authenticate(
        _ offer: UpdateOffer, payload: Data, signature: Data, trustedKey: Curve25519.Signing.PublicKey
    ) throws -> AuthenticatedUpdate {
        guard !payload.isEmpty, payload.count <= maximumPayloadBytes else { throw InvalidManifest.malformed }
        guard signature.count == 64, trustedKey.isValidSignature(signature, for: payload) else {
            throw InvalidManifest.invalidSignature
        }
        guard let manifest = try? JSONDecoder().decode(Payload.self, from: payload) else {
            throw InvalidManifest.malformed
        }
        guard manifest.product == product, manifest.tag == offer.tag else { throw InvalidManifest.mismatchedRelease }
        try validate(manifest)

        let asset = offer.asset
        guard let signed = manifest.installers.first(where: { $0.filename == asset.filename }),
              signed.size == asset.size,
              let digest = UpdateCatalog.normalizedSHA256(signed.sha256),
              asset.sha256 == nil || asset.sha256 == digest else { throw InvalidManifest.mismatchedInstaller }
        return AuthenticatedUpdate(commit: manifest.commit, asset: UpdateAsset(
            filename: asset.filename, downloadURL: asset.downloadURL, size: asset.size, sha256: digest
        ))
    }

    private static func validate(_ manifest: Payload) throws {
        guard manifest.version == 1, manifest.tag.utf8.count <= 128, let version = SemanticVersion(manifest.tag),
              manifest.commit.utf8.count == 40,
              manifest.commit.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw InvalidManifest.malformed
        }
        let allowedFiles = Set(["dmg", "zip"].map { UpdateCatalog.installerFilename(version: version, suffix: $0) })
        let filenames = Set(manifest.installers.map(\.filename))
        guard !filenames.isEmpty, filenames.count == manifest.installers.count, filenames.isSubset(of: allowedFiles),
              manifest.installers.allSatisfy({ $0.size > 0 && UpdateCatalog.normalizedSHA256($0.sha256) != nil }) else {
            throw InvalidManifest.malformed
        }
    }
}
