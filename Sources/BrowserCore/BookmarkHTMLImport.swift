import Foundation

public struct BookmarkHTMLImport: Sendable {
    public struct Bookmark: Sendable {
        public let title: String
        public let url: String
        public let folder: String?
        public let addedAt: Date
    }

    public struct Folder: Sendable {
        public let name: String
        public let parent: String?
    }

    public let bookmarks: [Bookmark]
    public let folders: [Folder]
    public let skippedLinkCount: Int

    public static func read(from file: URL) throws -> Self {
        guard file.isFileURL else { throw BookmarkHTMLImportError.unreadable }
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw BookmarkHTMLImportError.unreadable
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let maximumBytes = 64 * 1024 * 1024
        var html = Data()
        while let chunk = try handle.read(upToCount: min(1024 * 1024, maximumBytes - html.count + 1)), !chunk.isEmpty {
            guard chunk.count <= maximumBytes - html.count else { throw BookmarkHTMLImportError.tooLarge }
            html.append(chunk)
        }

        let document: XMLDocument
        do { document = try XMLDocument(data: html, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]) }
        catch { throw BookmarkHTMLImportError.invalidDocument }
        guard let body = document.rootElement()?.children?.first(where: { $0.name?.lowercased() == "body" }) else {
            throw BookmarkHTMLImportError.invalidDocument
        }
        var parser = BookmarkHTMLParser()
        for list in body.children ?? [] where list.name?.lowercased() == "dl" {
            try parser.readList(list, in: nil, depth: 0)
        }
        guard !parser.bookmarks.isEmpty else { throw BookmarkHTMLImportError.noBookmarks }
        return Self(bookmarks: parser.bookmarks, folders: parser.folders, skippedLinkCount: parser.skippedLinkCount)
    }
}

private enum BookmarkHTMLImportError: LocalizedError {
    case unreadable, tooLarge, invalidDocument, tooDeep, noBookmarks

    var errorDescription: String? {
        switch self {
        case .unreadable: "Choose a bookmarks HTML file from your Mac."
        case .tooLarge: "This bookmarks HTML file exceeds 64 MB."
        case .invalidDocument: "Alcove couldn’t read this bookmarks HTML file."
        case .tooDeep: "This file contains too many nested bookmark folders."
        case .noBookmarks: "This file contains no importable website bookmarks."
        }
    }
}

private struct BookmarkHTMLParser {
    var bookmarks: [BookmarkHTMLImport.Bookmark] = []
    var folders: [BookmarkHTMLImport.Folder] = []
    var skippedLinkCount = 0
    private var usedFolderNames: Set<String> = []
    private let importedAt = Date()

    mutating func readList(_ list: XMLNode, in folder: String?, depth: Int) throws {
        var pendingFolder: String?
        try readEntries(list.children ?? [], in: folder, pendingFolder: &pendingFolder, depth: depth)
    }

    private mutating func readEntries(_ nodes: [XMLNode], in folder: String?, pendingFolder: inout String?, depth: Int) throws {
        guard depth <= 128 else { throw BookmarkHTMLImportError.tooDeep }
        for case let element as XMLElement in nodes {
            switch element.name?.lowercased() {
            case "dt", "dd":
                // Repairs may put the heading and its list in the same wrapper or in adjacent wrappers.
                try readEntries(element.children ?? [], in: folder, pendingFolder: &pendingFolder, depth: depth + 1)
            case "h3":
                pendingFolder = addFolder(title: Self.title(of: element), parent: folder)
            case "dl":
                let parent = pendingFolder ?? folder
                pendingFolder = nil
                try readList(element, in: parent, depth: depth + 1)
            case "a":
                pendingFolder = nil
                addBookmark(element, folder: folder)
            default:
                continue
            }
        }
    }

    private mutating func addFolder(title: String, parent: String?) -> String {
        let base = String((title.isEmpty ? "Folder" : title).prefix(80)).precomposedStringWithCanonicalMapping
        var name = base
        var occurrence = 1
        while !usedFolderNames.insert(name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)).inserted {
            occurrence += 1
            let suffix = " (\(occurrence))"
            name = String(base.prefix(80 - suffix.count)) + suffix
        }
        folders.append(.init(name: name, parent: parent))
        return name
    }

    private mutating func addBookmark(_ element: XMLElement, folder: String?) {
        guard let href = Self.attribute("href", of: element),
              let url = URL(string: href.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = QuickBrowseRouting.host(for: url), url.user == nil, url.password == nil else {
            skippedLinkCount += 1
            return
        }
        let title = Self.title(of: element)
        let seconds = Self.attribute("add_date", of: element).flatMap(TimeInterval.init)
        let date = seconds.flatMap { (0...253_402_300_799).contains($0) ? Date(timeIntervalSince1970: $0) : nil } ?? importedAt
        bookmarks.append(.init(title: title.isEmpty ? host : title, url: url.absoluteString, folder: folder, addedAt: date))
    }

    private static func attribute(_ name: String, of element: XMLElement) -> String? {
        element.attributes?.first(where: { $0.name?.lowercased() == name })?.stringValue
    }

    private static func title(of element: XMLElement) -> String {
        (element.stringValue ?? "").split { character in
            character.isWhitespace || character.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
        }.joined(separator: " ")
    }
}
