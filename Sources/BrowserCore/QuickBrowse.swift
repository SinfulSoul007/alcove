import Foundation

public struct QuickPage: Codable, Identifiable, Equatable {
    public var tab: Tab
    public var intendedSpaceID: UUID?
    public var openedAt: Date
    public var lastActiveAt: Date
    public var id: UUID { tab.id }
    public init(tab: Tab = Tab(), intendedSpaceID: UUID? = nil, openedAt: Date = Date(), lastActiveAt: Date? = nil) {
        self.tab = tab; self.intendedSpaceID = intendedSpaceID; self.openedAt = openedAt; self.lastActiveAt = lastActiveAt ?? openedAt
    }
}

public struct QuickDomainChoice: Codable, Identifiable, Equatable {
    public var host: String
    public var profileID: UUID
    public var id: String { host }
    public init(host: String, profileID: UUID) { self.host = host; self.profileID = profileID }
}

public enum QuickBrowseRouting {
    public static func normalizedHost(_ raw: String) -> String? {
        guard !raw.isEmpty, !raw.contains(where: { $0.isWhitespace }) else { return nil }
        var host = raw.lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return nil }
        if host.contains(":"), !host.hasPrefix("[") { host = "[" + host + "]" }
        if host.hasPrefix("[") && host.hasSuffix("]") {
            guard host.dropFirst().dropLast().allSatisfy({ "0123456789abcdef:.".contains($0) }), host.contains(":") else { return nil }
        } else {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
            let labels = host.split(separator: ".", omittingEmptySubsequences: false)
            guard host.utf8.count <= 253, labels.allSatisfy({ label in
                !label.isEmpty && label.utf8.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-") && label.unicodeScalars.allSatisfy { allowed.contains($0) }
            }) else { return nil }
        }
        var components = URLComponents(); components.scheme = "https"; components.host = host
        guard let canonical = components.url?.host?.lowercased(), !canonical.contains("%") else { return nil }
        return canonical.contains(":") && !canonical.hasPrefix("[") ? "[" + canonical + "]" : canonical
    }
    public static func host(for url: URL) -> String? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host else { return nil }
        return normalizedHost(host)
    }
    public static func profile(for url: URL, choices: [QuickDomainChoice], available: Set<UUID>, fallback: UUID) -> UUID? {
        guard let host = host(for: url) else { return nil }
        if let choice = choices.first(where: { normalizedHost($0.host) == host }) { return available.contains(choice.profileID) ? choice.profileID : nil }
        return available.contains(fallback) ? fallback : nil
    }
    public static func repairedChoices(_ choices: [QuickDomainChoice], knownProfiles: Set<UUID>) -> [QuickDomainChoice] {
        var hosts: Set<String> = []; var result: [QuickDomainChoice] = []
        for choice in choices {
            guard knownProfiles.contains(choice.profileID), let host = normalizedHost(choice.host), hosts.insert(host).inserted else { continue }
            result.append(QuickDomainChoice(host: host, profileID: choice.profileID))
        }
        return result
    }
}

public enum QuickBrowsePolicy {
    public static func archiveCutoff(hours: Int?, now: Date) -> Date? {
        guard hours != 0 else { return nil }
        let interval = [6, 12, 24].contains(hours ?? 6) ? (hours ?? 6) : 6
        return now.addingTimeInterval(-Double(interval) * 3600)
    }
}
