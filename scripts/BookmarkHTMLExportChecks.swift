import Foundation
import BrowserCore

@main struct BookmarkHTMLExportChecks {
    static func main() throws {
        var failures = 0, checks = 0
        func check(_ result: Bool, _ name: String) {
            checks += 1
            print("\(result ? "PASS" : "FAIL"): \(name)")
            if !result { failures += 1 }
        }
        func document(_ export: BookmarkHTMLExport) throws -> XMLDocument {
            try XMLDocument(data: export.data, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever])
        }
        func values(_ document: XMLDocument, _ xpath: String) throws -> [String] {
            try document.nodes(forXPath: xpath).map { $0.stringValue ?? "" }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Alcove-export-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var favorite = Tab(title: "Live favorite", url: "https://example.com/current", pinned: true)
        favorite.favorite = true; favorite.homeURL = "https://example.com/home?a=1&b=2"
        favorite.customTitle = "Café <script>alert(1)</script> & \"friends\""
        var parentPin = Tab(title: "Live pin", url: "https://example.org/current", pinned: true)
        parentPin.homeURL = "https://example.org/saved"; parentPin.pinnedTitle = "Saved pin"
        parentPin.folder = "Research & notes"
        var childPin = Tab(title: "Child", url: "https://example.net/child", pinned: true)
        childPin.folder = "Nested"
        var space = Space(name: "Work <team>", tabs: [parentPin, childPin, Tab(title: "Do not export Today", url: "https://private.example/today")])
        space.folders = ["Research & notes", "Nested", "Empty"]
        space.folderParents = ["Nested": "Research & notes"]
        space.collapsedFolders = ["Research & notes"]; space.pinnedShelfCollapsed = true
        let bookmark = PageRecord(title: "Library only", url: "https://library.example/saved", date: Date(timeIntervalSince1970: 1_700_000_000))
        let duplicate = PageRecord(title: "Duplicate pin", url: "https://example.org/saved")
        let before = space
        let export = try BookmarkHTMLExport(spaces: [space], favorites: [favorite], bookmarks: [bookmark, duplicate])
        let xml = try document(export)
        check(export.bookmarkCount == 4 && export.skippedLinkCount == 0, "Export contains all saved pages and suppresses only redundant library copies")
        check(try values(xml, "//a/@href") == ["https://example.com/home?a=1&b=2", "https://example.org/saved", "https://example.net/child", "https://library.example/saved"], "Export uses saved home addresses in user group order and omits Today")
        check(try values(xml, "//a").first == favorite.customTitle, "UTF-8 custom titles and HTML metacharacters survive as text")
        check(try xml.nodes(forXPath: "//script | //iframe | //img").isEmpty, "Saved names cannot inject active HTML")
        // HTML Tidy includes the following formatting newline in heading text.
        // Compare the visible name, as bookmark importers do.
        let headings = try values(xml, "//h3").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        check(headings == ["Favorites", "Work <team>", "Research & notes", "Nested", "Empty", "Bookmarks"], "Favorites, Space and nested/empty folder order is portable")
        if headings != ["Favorites", "Work <team>", "Research & notes", "Nested", "Empty", "Bookmarks"] { print("Observed exported headings: \(headings)") }
        check(try values(xml, "//a/@add_date") == ["1700000000"], "Only a real bookmark's saved timestamp is exported, without tab visit times")
        check(space == before, "Export leaves live source tabs and folder state unchanged")
        let file = directory.appendingPathComponent("bookmarks.html")
        try export.data.write(to: file)
        let imported = try BookmarkHTMLImport.read(from: file)
        check(imported.bookmarks.count == 4 && imported.skippedLinkCount == 0, "Actual exported bytes round-trip through the browser's HTML importer")
        check(imported.bookmarks.first?.folder == "Favorites" && imported.bookmarks[1].folder == "Research & notes" && imported.bookmarks[2].folder == "Nested", "Round-trip retains each bookmark's actual folder")
        check(imported.folders.contains { $0.name == "Nested" && $0.parent == "Research & notes" } && imported.folders.contains { $0.name == "Empty" && $0.parent == "Work <team>" }, "Round-trip preserves nested and empty folders even when collapsed")

        let bad = ["javascript:alert(1)", "data:text/html,hello", "file:///private/test", "https://user:password@example.com/a", "https:///", "webkit-extension://example/a"]
            .map { PageRecord(title: "Bad", url: $0) }
        let safe = PageRecord(title: "Quote \" onmouseover=\"alert(1)", url: "https://example.com/a?x=%22&y=%3Ctag%3E")
        let filtered = try BookmarkHTMLExport(spaces: [], favorites: [], bookmarks: bad + [safe])
        let filteredXML = try document(filtered)
        check(filtered.bookmarkCount == 1 && filtered.skippedLinkCount == 6, "Unsupported and credential-bearing addresses are skipped with an exact count")
        check(try values(filteredXML, "//a/@href") == [safe.url] && filteredXML.nodes(forXPath: "//@onmouseover").isEmpty, "Quoted title and escaped URL remain a single inert bookmark")

        var repeated = parentPin; repeated.folder = "Second"
        let repeatSpace = Space(name: "Two places", tabs: [parentPin, repeated])
        let repeats = try BookmarkHTMLExport(spaces: [repeatSpace], favorites: [], bookmarks: [duplicate])
        check(repeats.bookmarkCount == 2, "Explicitly saved copies in two folders are retained")
        var cycle = repeatSpace; cycle.folders = ["Research & notes", "Second"]
        cycle.folderParents = ["Research & notes": "Second", "Second": "Research & notes"]
        let repaired = try BookmarkHTMLExport(spaces: [cycle], favorites: [], bookmarks: [])
        let repairedHeadings = try values(document(repaired), "//h3")
        check(repaired.bookmarkCount == 2 && repairedHeadings.count == 3, "Malformed folder cycles are repaired without losing saved pages or looping")

        var deep = Space(name: "Deep", tabs: [Tab(title: "Bottom", url: "https://example.com/bottom", pinned: true)])
        deep.folders = (0..<32).map { "Level \($0)" }
        deep.folderParents = Dictionary(uniqueKeysWithValues: (1..<32).map { ("Level \($0)", "Level \($0 - 1)") })
        deep.tabs[0].folder = "Level 31"
        let bounded = try BookmarkHTMLExport(spaces: [deep], favorites: [], bookmarks: [])
        try bounded.data.write(to: file)
        check((try BookmarkHTMLImport.read(from: file)).bookmarks.first?.url == "https://example.com/bottom", "Thirty-two nested folders remain importable")
        deep.folders?.append("Level 32"); deep.folderParents?["Level 32"] = "Level 31"
        var depthRejected = false
        do { _ = try BookmarkHTMLExport(spaces: [deep], favorites: [], bookmarks: []) } catch { depthRejected = true }
        check(depthRejected, "An excessive folder hierarchy fails without returning a partial export")
        let huge = PageRecord(title: String(repeating: "a", count: 64 * 1024 * 1024), url: "https://example.com/huge")
        var sizeRejected = false
        do { _ = try BookmarkHTMLExport(spaces: [], favorites: [], bookmarks: [huge]) } catch { sizeRejected = true }
        check(sizeRejected, "Output over 64 MiB fails without returning a partial export")
        let invalidDate = PageRecord(title: "No date", url: "https://example.com/no-date", date: Date(timeIntervalSince1970: .nan))
        let undated = try BookmarkHTMLExport(spaces: [], favorites: [], bookmarks: [invalidDate])
        check(try values(document(undated), "//a/@add_date").isEmpty, "Nonfinite dates cannot crash export or produce invalid timestamp attributes")
        let empty = try BookmarkHTMLExport(spaces: [], favorites: [], bookmarks: [])
        let emptyLinks = try document(empty).nodes(forXPath: "//a")
        check(empty.bookmarkCount == 0 && emptyLinks.isEmpty && !empty.data.isEmpty, "An empty profile exports an ordinary empty bookmarks document")
        print("Bookmark HTML export checks: \(checks), \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
