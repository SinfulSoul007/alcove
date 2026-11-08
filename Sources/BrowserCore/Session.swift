import Foundation

public enum Address {
    public static func resolve(_ input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let lower = text.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            guard let url = URL(string: text), let host = url.host, !host.isEmpty else { return nil }
            return url
        }
        let isLocal = lower == "localhost" || lower.hasPrefix("localhost:") || lower.hasPrefix("localhost/") || lower.hasPrefix("127.0.0.1") || lower.hasPrefix("[::1]")
        if !text.contains(where: { $0.isWhitespace }), isLocal { return URL(string: "http://" + text) }
        // Only web URLs may be entered; other schemes never execute from the address bar.
        if let colon = text.firstIndex(of: ":"), !text[..<colon].contains("."), !text[..<colon].contains("/") { return nil }
        if !text.contains(where: { $0.isWhitespace }), text.split(separator: "/").first?.contains(".") == true,
           let url = URL(string: "https://" + text), url.host != nil { return url }
        var parts = URLComponents(string: "https://duckduckgo.com/")!
        parts.percentEncodedQuery = "q=" + (text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
        return parts.url
    }
}
public struct Tab: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var title: String
    public var url: String
    public var pinned: Bool
    public var favorite: Bool?
    public var homeURL: String?
    public var pinnedTitle: String?
    public var folder: String?
    public var lastAccessed: Date?
    public var archiveSource: String?
    public init(title: String = "New Tab", url: String = "", pinned: Bool = false) {
        self.title = title; self.url = url; self.pinned = pinned; self.lastAccessed = Date()
    }
}
public struct Space: Codable, Identifiable {
    public var id = UUID()
    public var name: String
    public var theme: String?
    public var customTheme: CustomTheme?
    public var icon: String?
    public var collapsedFolders: [String]?
    public var profileID: UUID?
    public var tabs: [Tab]
    public var selected: UUID?
    public init(name: String, tabs: [Tab] = [Tab()]) {
        self.name = name; self.tabs = tabs; self.selected = tabs.first?.id
    }
}
public struct Session: Codable {
    public var spaces: [Space]
    public var selectedSpace: UUID
    public init() { let first = Space(name: "Personal"); spaces = [first]; selectedSpace = first.id }
    public mutating func archiveInactive(before cutoff: Date, excluding protected: Set<UUID>) -> [Tab] {
        var archived: [Tab] = []
        for s in spaces.indices {
            let ids = spaces[s].tabs.filter { !$0.pinned && !protected.contains($0.id) && !$0.url.isEmpty && ($0.lastAccessed.map { $0 < cutoff } ?? false) }.map(\.id)
            for id in ids {
                if let tab = spaces[s].tabs.first(where: { $0.id == id }) { archived.append(tab) }
                close(id, in: spaces[s].id)
            }
        }
        return archived
    }
    public mutating func close(_ id: UUID, in spaceID: UUID) {
        guard let s = spaces.firstIndex(where: { $0.id == spaceID }),
              let t = spaces[s].tabs.firstIndex(where: { $0.id == id }) else { return }
        spaces[s].tabs.remove(at: t)
        if spaces[s].tabs.isEmpty { spaces[s].tabs = [Tab()] }
        if spaces[s].selected == id {
            spaces[s].selected = spaces[s].tabs[min(t, spaces[s].tabs.count - 1)].id
        }
    }
}
