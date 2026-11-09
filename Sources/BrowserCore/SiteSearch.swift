import Foundation

public enum SiteSearchError: LocalizedError {
    case invalidName, invalidKeyword, invalidTemplate, emptyQuery, disabled, duplicateKeyword, tooManySites, configurationChanged
    public var errorDescription: String? {
        switch self {
        case .invalidName: return "Enter a site name using 1–80 characters."
        case .invalidKeyword: return "Use 1–32 shortcut characters without spaces or URL delimiters."
        case .invalidTemplate: return "Use an HTTP or HTTPS search URL with one %s after the hostname and no sign-in credentials."
        case .emptyQuery: return "Enter a query to search this site."
        case .disabled: return "This search shortcut is disabled. Choose a site again."
        case .duplicateKeyword: return "Another search shortcut uses this keyword."
        case .tooManySites: return "Remove a shortcut before adding another. You can keep up to 128."
        case .configurationChanged: return "This search shortcut changed. Choose a site again before searching."
        }
    }
}

public struct SiteSearch: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var keyword: String
    public var template: String
    public var enabled: Bool
    public init(id: UUID = UUID(), name: String, keyword: String, template: String, enabled: Bool = true) {
        self.id = id; self.name = name; self.keyword = keyword; self.template = template; self.enabled = enabled
    }
    static func normalizedKeyword(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().precomposedStringWithCanonicalMapping
    }
    static func validKeyword(_ text: String) -> Bool {
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters).union(CharacterSet(charactersIn: ":/?#@%"))
        return (1...32).contains(text.count) && !text.unicodeScalars.contains(where: forbidden.contains)
    }
    public func validated() throws -> SiteSearch {
        var value = self
        value.name = name.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        value.keyword = Self.normalizedKeyword(keyword)
        value.template = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...80).contains(value.name.count), !value.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw SiteSearchError.invalidName }
        guard Self.validKeyword(value.keyword) else { throw SiteSearchError.invalidKeyword }
        let text = value.template
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard text.utf8.count <= 8192, !text.unicodeScalars.contains(where: forbidden.contains),
              text.components(separatedBy: "%s").count == 2, let placeholder = text.range(of: "%s"),
              let separator = text.range(of: "://") else { throw SiteSearchError.invalidTemplate }
        let authorityEnd = text[separator.upperBound...].firstIndex(where: { "/?#".contains($0) }) ?? text.endIndex
        guard placeholder.lowerBound >= authorityEnd,
              let parts = URLComponents(string: text.replacingOccurrences(of: "%s", with: "alcove-query-token")),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              let url = parts.url, url.host != nil else { throw SiteSearchError.invalidTemplate }
        return value
    }
    private static let queryCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
    public func url(for query: String) throws -> URL {
        let site = try validated()
        guard site.enabled else { throw SiteSearchError.disabled }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SiteSearchError.emptyQuery }
        guard let escaped = text.addingPercentEncoding(withAllowedCharacters: Self.queryCharacters),
              let result = URL(string: site.template.replacingOccurrences(of: "%s", with: escaped)),
              let origin = URL(string: site.template.replacingOccurrences(of: "%s", with: "alcove-query-token")),
              result.scheme?.lowercased() == origin.scheme?.lowercased(), result.host?.lowercased() == origin.host?.lowercased(), result.port == origin.port,
              result.user == nil, result.password == nil else { throw SiteSearchError.invalidTemplate }
        return result
    }
    public static let defaults: [SiteSearch] = [
        SiteSearch(id: UUID(uuidString: "A1C0E000-0000-0000-0000-000000000001")!, name: "YouTube", keyword: "yt", template: "https://www.youtube.com/results?search_query=%s"),
        SiteSearch(id: UUID(uuidString: "A1C0E000-0000-0000-0000-000000000002")!, name: "Wikipedia", keyword: "wiki", template: "https://en.wikipedia.org/w/index.php?search=%s"),
        SiteSearch(id: UUID(uuidString: "A1C0E000-0000-0000-0000-000000000003")!, name: "GitHub", keyword: "gh", template: "https://github.com/search?q=%s")
    ]
}

/// Validated once per preference revision; matching never parses URLs or contacts a site.
public struct SiteSearchCatalog: Sendable {
    public let entries: [SiteSearch]
    public init(_ saved: [SiteSearch]?) {
        var valid: [SiteSearch] = [], ids = Set<UUID>(), keywords = Set<String>()
        for raw in saved ?? SiteSearch.defaults {
            guard valid.count < 128 else { break }
            guard let site = try? raw.validated(), !ids.contains(site.id), !keywords.contains(site.keyword) else { continue }
            ids.insert(site.id); keywords.insert(site.keyword); valid.append(site)
        }
        entries = valid
    }
    public func matches(_ input: String) -> [SiteSearch] {
        let keyword = SiteSearch.normalizedKeyword(input)
        guard SiteSearch.validKeyword(keyword) else { return [] }
        return entries.filter { $0.enabled && $0.keyword.hasPrefix(keyword) }
    }
    public func preferredMatch(_ input: String) -> SiteSearch? {
        let options = matches(input), keyword = SiteSearch.normalizedKeyword(input)
        return options.first(where: { $0.keyword == keyword }) ?? (options.count == 1 ? options[0] : nil)
    }
    public func upserting(_ site: SiteSearch) throws -> [SiteSearch] {
        let value = try site.validated()
        guard !entries.contains(where: { $0.id != value.id && $0.keyword == value.keyword }) else { throw SiteSearchError.duplicateKeyword }
        var result = entries
        if let index = result.firstIndex(where: { $0.id == value.id }) { result[index] = value }
        else {
            guard result.count < 128 else { throw SiteSearchError.tooManySites }
            result.append(value)
        }
        return result
    }
    public func removing(_ id: UUID) -> [SiteSearch] { entries.filter { $0.id != id } }
}
