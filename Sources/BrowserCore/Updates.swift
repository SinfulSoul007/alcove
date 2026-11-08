import Foundation
import CryptoKit

/// SemVer precedence, accepting the conventional `v` prefix used by Git tags.
/// Build metadata is retained for display but intentionally excluded from equality.
public struct SemanticVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: [String]
    public let buildMetadata: [String]

    public init?(_ tag: String) {
        guard !tag.isEmpty, tag.utf8.count <= 256 else { return nil }
        let text = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let buildParts = text.split(separator: "+", omittingEmptySubsequences: false)
        guard buildParts.count <= 2 else { return nil }
        let versionParts = buildParts[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = versionParts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard numbers.count == 3, numbers.allSatisfy({ Self.numeric(String($0), allowLeadingZero: false) }),
              let major = Int(numbers[0]), let minor = Int(numbers[1]), let patch = Int(numbers[2]) else { return nil }
        let prerelease = versionParts.count == 2 ? versionParts[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init) : []
        let metadata = buildParts.count == 2 ? buildParts[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init) : []
        guard prerelease.allSatisfy({ Self.identifier($0) && (!Self.numeric($0, allowLeadingZero: true) || Self.numeric($0, allowLeadingZero: false)) }),
              metadata.allSatisfy(Self.identifier) else { return nil }
        self.major = major; self.minor = minor; self.patch = patch
        self.prerelease = prerelease; self.buildMetadata = metadata
    }
    private static func identifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }
    }
    private static func numeric(_ value: String, allowLeadingZero: Bool) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) } && (allowLeadingZero || value.count == 1 || !value.hasPrefix("0"))
    }
    public var base: String { "\(major).\(minor).\(patch)" }
    public var description: String {
        base + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: ".")) + (buildMetadata.isEmpty ? "" : "+" + buildMetadata.joined(separator: "."))
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.major == rhs.major && lhs.minor == rhs.minor && lhs.patch == rhs.patch && lhs.prerelease == rhs.prerelease
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(major); hasher.combine(minor); hasher.combine(patch); hasher.combine(prerelease)
    }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            let leftNumeric = numeric(left, allowLeadingZero: true), rightNumeric = numeric(right, allowLeadingZero: true)
            if leftNumeric && rightNumeric { return left.count == right.count ? left < right : left.count < right.count }
            if leftNumeric != rightNumeric { return leftNumeric }
            return left < right
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

public enum UpdateChannel: String, Codable, CaseIterable, Identifiable, Sendable {
    case stable, preview
    public var id: String { rawValue }
    public var title: String { self == .stable ? "Stable" : "Preview" }
}

public enum UpdateCheckSchedule {
    public static func isDue(lastAttempt: Date?, now: Date) -> Bool {
        guard let lastAttempt else { return true }
        let elapsed = now.timeIntervalSince(lastAttempt)
        return elapsed < 0 || elapsed >= 86400
    }
}

/// Fields consumed from GitHub's public list-releases response.
public struct Release: Decodable, Sendable {
    public let tagName: String
    public let name: String?
    public let body: String?
    public let isDraft: Bool
    public let isPrerelease: Bool
    public let assets: [ReleaseAsset]
    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name", name, body, isDraft = "draft", isPrerelease = "prerelease", assets
    }
}

public struct ReleaseAsset: Decodable, Sendable {
    public let name: String
    public let browserDownloadURL: String
    public let state: String
    public let size: Int64
    public let digest: String?
    enum CodingKeys: String, CodingKey {
        case name, browserDownloadURL = "browser_download_url", state, size, digest
    }
}

public struct UpdateAsset: Equatable, Sendable {
    public let filename: String
    public let downloadURL: URL
    public let size: Int64
    /// Hex only, normalized to lowercase. A missing digest does not imply verification.
    public let sha256: String?
    public func verify(_ data: Data) -> Bool? {
        guard let sha256 else { return nil }
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return actual == sha256
    }
}

public struct UpdateOffer: Equatable, Sendable {
    public let version: SemanticVersion
    public let tag: String
    public let title: String
    public let notes: String
    public let releaseURL: URL
    public let asset: UpdateAsset
}

public enum UpdateCatalog {
    public static let releasesURL = URL(string: "https://github.com/SinfulSoul007/alcove/releases")!
    public static let apiURL = URL(string: "https://api.github.com/repos/SinfulSoul007/alcove/releases?per_page=100")!

    public static func latest<S: Sequence>(in releases: S, installedTag: String, channel: UpdateChannel) throws -> UpdateOffer? where S.Element == Release {
        guard let installed = SemanticVersion(installedTag) else { throw CatalogError.invalidInstalledVersion }
        return releases.compactMap { release -> UpdateOffer? in
            guard !release.isDraft, let version = SemanticVersion(release.tagName), version > installed,
                  channel == .preview || (!release.isPrerelease && version.prerelease.isEmpty),
                  let asset = installer(for: release, version: version),
                  let releaseURL = URL(string: releasesURL.absoluteString + "/tag/" + release.tagName) else { return nil }
            return UpdateOffer(version: version, tag: release.tagName, title: release.name ?? release.tagName, notes: release.body ?? "", releaseURL: releaseURL, asset: asset)
        }.max { $0.version < $1.version }
    }

    private static func installer(for release: Release, version: SemanticVersion) -> UpdateAsset? {
        for suffix in ["dmg", "zip"] {
            let filename = "Alcove-\(version.base)-universal-unsigned-preview.\(suffix)"
            let expected = "https://github.com/SinfulSoul007/alcove/releases/download/\(release.tagName)/\(filename)"
            for asset in release.assets where asset.name == filename && asset.state == "uploaded" && asset.size > 0 {
                // Exact comparison also rejects credentials, ports, query strings, encoded paths,
                // lookalike hosts, different tags and traversal before Foundation normalizes them.
                guard asset.browserDownloadURL == expected, let url = URL(string: expected) else { continue }
                var digest: String?
                if let published = asset.digest {
                    guard published.hasPrefix("sha256:") else { continue }
                    let hex = String(published.dropFirst(7))
                    guard hex.utf8.count == 64, hex.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { continue }
                    digest = hex.lowercased()
                }
                return UpdateAsset(filename: filename, downloadURL: url, size: asset.size, sha256: digest)
            }
            // ZIP is a fallback only when the DMG is absent. A present but invalid
            // installer fails closed instead of hiding its failed validation.
            if release.assets.contains(where: { $0.name == filename }) { return nil }
        }
        return nil
    }

    public enum CatalogError: LocalizedError {
        case invalidInstalledVersion
        public var errorDescription: String? { "This build has no valid release version. Open the releases page to check manually." }
    }
}
