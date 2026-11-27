public enum BrowserCommand: String, CaseIterable, Identifiable {
    case pin, unpin, favorite, unfavorite, sidebar, split, library, downloads, settings, profiles, copyURL, siteSearch, linkRouting, boosts, spaces, newSpace, renameSpace, deleteSpace, restoreSpace, deletedSpaces, newFolder, extensions
    case splitLeft, splitRight, splitTop, splitBottom, flipSplit
    case collapsePinned, expandPinned, renameTab, duplicateTab
    case returnToPinnedURL, returnToPinnedURLKeepingPage
    case editPinnedURL, useCurrentPinnedURL, reader
    case newEasel, capturePage, exportEaselPNG, exportEaselHTML
    public func matches(_ query: String) -> Bool {
        let searchable = self == .linkRouting ? title + " Link Preferences Air Traffic Control" : self == .boosts ? title + " Create Boost This Site" : title
        let words = searchable.lowercased().split(whereSeparator: { $0.isWhitespace })
        let queryWords = query.lowercased().split(whereSeparator: { $0.isWhitespace })
        return !queryWords.isEmpty && queryWords.allSatisfy { term in words.contains(where: { $0.hasPrefix(term) }) }
    }
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .newEasel: return "New Easel"
        case .capturePage: return "Capture Page to Easel"
        case .exportEaselPNG: return "Export Easel as PNG"
        case .exportEaselHTML: return "Export Easel as HTML"
        case .reader: return "Toggle Reader Mode"
        case .pin: return "Pin Tab"
        case .unpin: return "Unpin Tab"
        case .favorite: return "Favorite Tab"
        case .unfavorite: return "Unfavorite Tab"
        case .sidebar: return "Toggle Sidebar"
        case .split: return "Toggle Split View"
        case .splitLeft: return "Add Left Split"
        case .splitRight: return "Add Right Split"
        case .splitTop: return "Add Top Split"
        case .splitBottom: return "Add Bottom Split"
        case .flipSplit: return "Flip Split Orientation"
        case .library: return "Open Library"
        case .downloads: return "Show Downloads"
        case .settings: return "Open Settings"
        case .profiles: return "Manage Profiles"
        case .spaces: return "Manage Spaces"
        case .newSpace: return "New Space"
        case .newFolder: return "New Folder"
        case .collapsePinned: return "Collapse Pinned"
        case .expandPinned: return "Expand Pinned"
        case .renameTab: return "Rename Tab"
        case .duplicateTab: return "Duplicate Tab"
        case .returnToPinnedURL: return "Back to Pinned URL"
        case .returnToPinnedURLKeepingPage: return "Back to Pinned URL and Keep Current Page"
        case .editPinnedURL: return "Edit Pinned URL"
        case .useCurrentPinnedURL: return "Use Current URL as Pinned URL"
        case .renameSpace: return "Rename Space"
        case .deleteSpace: return "Delete Space"
        case .restoreSpace: return "Restore Last Deleted Space"
        case .deletedSpaces: return "Recently Deleted Spaces"
        case .copyURL: return "Copy Current URL"
        case .siteSearch: return "Site Search Settings"
        case .linkRouting: return "Link Routing Settings"
        case .boosts: return "Customize Website with Boosts"
        case .extensions: return "Manage Extensions"
        }
    }
}
