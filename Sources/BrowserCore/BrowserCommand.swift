public enum BrowserCommand: String, CaseIterable, Identifiable {
    case pin, unpin, favorite, unfavorite, sidebar, split, library, settings, profiles, copyURL
    public func matches(_ query: String) -> Bool {
        let words = title.lowercased().split(whereSeparator: { $0.isWhitespace })
        let queryWords = query.lowercased().split(whereSeparator: { $0.isWhitespace })
        return !queryWords.isEmpty && queryWords.allSatisfy { term in words.contains(where: { $0.hasPrefix(term) }) }
    }
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .pin: return "Pin Tab"
        case .unpin: return "Unpin Tab"
        case .favorite: return "Favorite Tab"
        case .unfavorite: return "Unfavorite Tab"
        case .sidebar: return "Toggle Sidebar"
        case .split: return "Toggle Split View"
        case .library: return "Open Library"
        case .settings: return "Open Settings"
        case .profiles: return "Manage Profiles"
        case .copyURL: return "Copy Current URL"
        }
    }
}
