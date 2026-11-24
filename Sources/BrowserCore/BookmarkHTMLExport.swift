import Foundation

/// Portable saved pages only. Callers supply one profile's collections.
public struct BookmarkHTMLExport: Sendable {
    public let data: Data
    public let bookmarkCount: Int
    public let skippedLinkCount: Int

    public init(spaces: [Space], favorites: [Tab], bookmarks: [PageRecord]) throws {
        var output = BookmarkHTMLWriter()
        try output.append("<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">\n<TITLE>Alcove Bookmarks</TITLE>\n<H1>Alcove Bookmarks</H1>\n<DL><p>\n")
        if !favorites.isEmpty {
            try output.openFolder("Favorites")
            for tab in favorites { try output.link(tab) }
            try output.closeFolder()
        }
        for space in spaces {
            let pins = space.tabs.filter { $0.pinned && $0.favorite != true }
            let tree = SidebarFolderTree(space: space)
            guard !pins.isEmpty || !tree.names.isEmpty else { continue }
            try output.openFolder(space.name)
            let known = Set(tree.names)
            for tab in pins where tab.folder == nil || !known.contains(tab.folder!) { try output.link(tab) }
            let grouped = Dictionary(grouping: pins.compactMap { tab in tab.folder.map { ($0, tab) } }, by: { $0.0 })
            var depth = 0
            for row in tree.visibleFolders(collapsed: []) {
                guard row.depth < 32 else { throw BookmarkHTMLExportError.tooDeep }
                while depth > row.depth { try output.closeFolder(); depth -= 1 }
                try output.openFolder(row.name); depth += 1
                for (_, tab) in grouped[row.name] ?? [] { try output.link(tab) }
            }
            while depth > 0 { try output.closeFolder(); depth -= 1 }
            try output.closeFolder()
        }
        // Keep explicitly saved copies in user folders, but do not add a second
        // flat library copy of an address already represented above.
        let remaining = bookmarks.filter { record in
            guard let url = BookmarkHTMLWriter.address(record.url) else { return true }
            return !output.addresses.contains(url.absoluteString)
        }
        if !remaining.isEmpty {
            try output.openFolder("Bookmarks")
            for record in remaining { try output.link(title: record.title, address: record.url, date: record.date) }
            try output.closeFolder()
        }
        try output.append("</DL><p>\n")
        data = output.data; bookmarkCount = output.bookmarkCount; skippedLinkCount = output.skippedLinkCount
    }
}

public enum BookmarkHTMLExportError: LocalizedError {
    case tooLarge, tooDeep
    public var errorDescription: String? {
        switch self {
        case .tooLarge: "The bookmarks export exceeds 64 MB. Export fewer saved pages at a time."
        case .tooDeep: "The bookmarks export contains more than 32 nested folders. Reduce the folder nesting before exporting."
        }
    }
}

private struct BookmarkHTMLWriter {
    private static let maximumBytes = 64 * 1024 * 1024
    var data = Data()
    var bookmarkCount = 0
    var skippedLinkCount = 0
    var addresses = Set<String>()

    mutating func append(_ value: String) throws {
        guard value.utf8.count <= Self.maximumBytes - data.count else { throw BookmarkHTMLExportError.tooLarge }
        data.append(contentsOf: value.utf8)
    }
    mutating func openFolder(_ title: String) throws {
        try append("<DT><H3>\(escape(title))</H3>\n<DL><p>\n")
    }
    mutating func closeFolder() throws { try append("</DL><p>\n") }
    mutating func link(_ tab: Tab) throws {
        try link(title: tab.sidebarTitle, address: tab.homeURL ?? tab.url, date: nil)
    }
    mutating func link(title: String, address: String, date: Date?) throws {
        guard let url = Self.address(address) else { skippedLinkCount += 1; return }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = try escape(name.isEmpty ? url.host! : name)
        let href = try escape(url.absoluteString)
        var added = ""
        if let seconds = date?.timeIntervalSince1970, seconds.isFinite, (0...253_402_300_799).contains(seconds) {
            added = " ADD_DATE=\"\(Int64(seconds))\""
        }
        try append("<DT><A HREF=\"\(href)\"\(added)>\(text)</A>\n")
        bookmarkCount += 1; addresses.insert(url.absoluteString)
    }
    static func address(_ text: String) -> URL? {
        guard !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let url = URL(string: text), QuickBrowseRouting.host(for: url) != nil,
              url.user == nil, url.password == nil else { return nil }
        return url
    }
    private func escape(_ value: String) throws -> String {
        let remaining = Self.maximumBytes - data.count
        guard value.utf8.count <= remaining else { throw BookmarkHTMLExportError.tooLarge }
        var escaped = "", count = 0
        for scalar in value.unicodeScalars {
            let part: String
            switch scalar.value {
            case 38: part = "&amp;"
            case 60: part = "&lt;"
            case 62: part = "&gt;"
            case 34: part = "&quot;"
            case 39: part = "&#39;"
            case 9, 10, 13: part = " "
            case 0..<32, 127: continue
            default: part = String(scalar)
            }
            count += part.utf8.count
            guard count <= remaining else { throw BookmarkHTMLExportError.tooLarge }
            escaped.append(part)
        }
        return escaped
    }
}
