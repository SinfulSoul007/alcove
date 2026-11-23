import Foundation
import CryptoKit

public enum WebsiteThreatCatalogError: Error, Equatable {
    case tooLarge, invalidMetadata, checksumMismatch, invalidDomains
}

public struct WebsiteThreatMetadata: Codable, Equatable, Sendable {
    public let formatVersion: Int
    public let provider: String
    public let sourceRevision: String
    public let sourceUpdatedAt: Date
    public let retrievedAt: Date
    public let sha256: String
    public let licenseSHA256: String
    public let domainCount: Int
}

public struct WebsiteThreat: Equatable, Sendable {
    /// ASCII destination hostname, without a port or user information.
    public let host: String
    /// The exact catalog entry that classified this host or its subdomain.
    public let listedHost: String
}

/// Immutable local classification. No match means not listed, never safe.
/// Loading performs bounded validation and should run away from the main actor.
public struct WebsiteThreatCatalog: Sendable {
    public let metadata: WebsiteThreatMetadata
    private let domains: Set<String>
    public var domainCount: Int { domains.count }

    public init(domains data: Data, metadata encoded: Data) throws {
        guard data.count <= 8_388_608 else { throw WebsiteThreatCatalogError.tooLarge }
        guard !encoded.isEmpty, encoded.count <= 16_384 else { throw WebsiteThreatCatalogError.invalidMetadata }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata: WebsiteThreatMetadata
        do { metadata = try decoder.decode(WebsiteThreatMetadata.self, from: encoded) }
        catch { throw WebsiteThreatCatalogError.invalidMetadata }
        guard metadata.formatVersion == 1, metadata.provider == "PhishDestroy",
              Self.isHex(metadata.sourceRevision, length: 40),
              Self.isHex(metadata.sha256, length: 64), Self.isHex(metadata.licenseSHA256, length: 64),
              (1...1_000_000).contains(metadata.domainCount),
              metadata.sourceUpdatedAt.timeIntervalSince1970 >= 0,
              metadata.sourceUpdatedAt <= metadata.retrievedAt else { throw WebsiteThreatCatalogError.invalidMetadata }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == metadata.sha256 else { throw WebsiteThreatCatalogError.checksumMismatch }
        guard let text = String(data: data, encoding: .utf8) else { throw WebsiteThreatCatalogError.invalidDomains }
        var rows = text.utf8.split(separator: 10, omittingEmptySubsequences: false)
        if rows.last?.isEmpty == true { rows.removeLast() }
        guard rows.count == metadata.domainCount else { throw WebsiteThreatCatalogError.invalidDomains }
        var domains = Set<String>()
        domains.reserveCapacity(metadata.domainCount)
        for var row in rows {
            if row.last == 13 { row = row.dropLast() }
            let domain = String(decoding: row, as: UTF8.self)
            guard Self.isDNSName(domain[...]), domains.insert(domain).inserted else { throw WebsiteThreatCatalogError.invalidDomains }
        }
        self.metadata = metadata
        self.domains = domains
    }

    public func threat(for url: URL) -> WebsiteThreat? {
        guard let host = WebOrigin(url)?.host, Self.isDNSName(host[...]) else { return nil }
        var candidate = host[...]
        while true {
            if domains.contains(String(candidate)) { return WebsiteThreat(host: host, listedHost: String(candidate)) }
            guard let dot = candidate.firstIndex(of: ".") else { return nil }
            candidate = candidate[candidate.index(after: dot)...]
        }
    }

    public func isStale(at now: Date) -> Bool {
        now.timeIntervalSince(metadata.sourceUpdatedAt) > 30 * 86400
    }

    private static func isHex(_ text: String, length: Int) -> Bool {
        text.utf8.count == length && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func isDNSName(_ host: Substring) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253 else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, let last = labels.last,
              last.utf8.contains(where: { (97...122).contains($0) }) else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.utf8.first != 45 && label.utf8.last != 45 &&
                label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
    }
}
