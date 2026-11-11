public enum BrowserCommand: String, CaseIterable, Identifiable {
    case pin, unpin, favorite, unfavorite, sidebar, split, library, settings, profiles, copyURL, siteSearch, linkRouting, boosts, spaces, newSpace, renameSpace, deleteSpace, restoreSpace, deletedSpaces
    public func matches(_ query: String) -> Bool {
        let searchable = self == .linkRouting ? title + " Link Preferences Air Traffic Control" : self == .boosts ? title + " Create Boost This Site" : title
        let words = searchable.lowercased().split(whereSeparator: { $0.isWhitespace })
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
        case .spaces: return "Manage Spaces"
        case .newSpace: return "New Space"
        case .renameSpace: return "Rename Space"
        case .deleteSpace: return "Delete Space"
        case .restoreSpace: return "Restore Last Deleted Space"
        case .deletedSpaces: return "Recently Deleted Spaces"
        case .copyURL: return "Copy Current URL"
        case .siteSearch: return "Site Search Settings"
        case .linkRouting: return "Link Routing Settings"
        case .boosts: return "Customize Website with Boosts"
        }
    }
}
