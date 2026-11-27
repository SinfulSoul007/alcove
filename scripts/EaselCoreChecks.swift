import Foundation
import BrowserCore

@main struct EaselCoreChecks {
    static var failures = 0
    static var checks = 0
    static func check(_ value: Bool, _ name: String) {
        checks += 1
        print("\(value ? "PASS" : "FAIL"): \(name)")
        if !value { failures += 1 }
    }
    static func rejects(_ name: String, _ body: () throws -> Void) {
        do { try body(); check(false, name) }
        catch is EaselError { check(true, name) }
        catch { check(false, name + " (unexpected error: \(error))") }
    }
    static func main() throws {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let initial = BrowserDocument()
        var object = try JSONSerialization.jsonObject(with: encoder.encode(initial)) as! [String: Any]
        let emptyLibrary = object["library"] as! [String: Any]
        let boardID = "11111111-1111-4111-8111-111111111111"
        let itemID = "22222222-2222-4222-8222-222222222222"
        let fixture: [String: Any] = [
            "id": boardID, "title": "Trip planning", "createdAt": 0, "modifiedAt": 0,
            "revision": "33333333-3333-4333-8333-333333333333",
            "items": [["id": itemID, "frame": ["x": 40, "y": 80, "width": 300, "height": 180],
                       "content": ["note": ["text": "Owned canvas note"]]]]
        ]
        var firstLibrary = emptyLibrary
        firstLibrary["easels"] = [fixture]
        object["library"] = firstLibrary
        object["formatVersion"] = 8
        let loaded = try decoder.decode(BrowserDocument.self, from: JSONSerialization.data(withJSONObject: object))
        let roundtrip = try JSONSerialization.jsonObject(with: encoder.encode(loaded)) as! [String: Any]
        let savedBoards = (roundtrip["library"] as? [String: Any])?["easels"] as? [[String: Any]]
        check(savedBoards?.first?["title"] as? String == "Trip planning", "A saved Easel survives protected-document decoding and encoding")
        var secondFixture = fixture
        secondFixture["title"] = "Other saved draft"
        var secondLibrary = emptyLibrary
        secondLibrary["easels"] = [secondFixture]
        object["profileLibraries"] = [
            ["profileID": BrowserProfile.defaultID.uuidString, "library": firstLibrary],
            ["profileID": BrowserProfile.defaultID.uuidString, "library": secondLibrary]
        ]
        var duplicated = try decoder.decode(BrowserDocument.self, from: JSONSerialization.data(withJSONObject: object))
        try duplicated.repairProfiles()
        let repaired = try JSONSerialization.jsonObject(with: encoder.encode(duplicated.library(for: BrowserProfile.defaultID))) as! [String: Any]
        let recovered = repaired["easels"] as? [[String: Any]]
        check(recovered?.compactMap { $0["title"] as? String } == ["Trip planning", "Other saved draft"], "Duplicate profile repair preserves unequal saved canvases sharing an identity")
        let time = Date(timeIntervalSinceReferenceDate: 100)
        let frame = try EaselFrame(x: 40, y: 80, width: 300, height: 180)
        let first = try EaselItem(id: UUID(uuidString: itemID)!, frame: frame, content: .note(text: "Draft"))
        let second = try EaselItem(frame: frame, content: .link(title: "WebKit", url: "https://webkit.org/blog/"))
        var board = try Easel(title: "  Research  ", createdAt: time, items: [first, second])
        check(board.title == "Research", "Board titles normalize surrounding whitespace")
        let before = board
        let newFrame = try EaselFrame(x: 900, y: 200, width: 400, height: 240)
        let edited = try EaselItem(id: first.id, frame: newFrame, content: .note(text: "Edited draft"))
        try board.apply(.replace(edited), expectedRevision: board.revision, at: time.addingTimeInterval(10))
        check(board.items[0].frame.x == 900 && board.items[0].content == .note(text: "Edited draft") && board.items[1] == second, "Replacing a note updates its geometry and text without changing its neighbor")
        check(board.revision != before.revision && board.modifiedAt == Date(timeIntervalSinceReferenceDate: 110), "An effective edit advances revision and modification time")
        let after = board
        rejects("A stale editor cannot overwrite a newer draft") { try board.apply(.rename("Lost update"), expectedRevision: before.revision, at: time.addingTimeInterval(20)) }
        check(board == after, "A rejected stale edit preserves the entire document")
        rejects("Reorder rejects a partial selection") { try board.apply(.reorder([second.id]), expectedRevision: board.revision, at: time) }
        rejects("Reorder rejects repeated identities") { try board.apply(.reorder([first.id, first.id]), expectedRevision: board.revision, at: time) }
        rejects("A mixed known/unknown removal is atomic") { try board.apply(.remove([first.id, UUID()]), expectedRevision: board.revision, at: time) }
        rejects("Insertion rejects an already occupied identity") { try board.apply(.insert(first), expectedRevision: board.revision, at: time) }
        let missing = try EaselItem(frame: frame, content: .note(text: "Missing"))
        rejects("Replace cannot silently insert an unknown item") { try board.apply(.replace(missing), expectedRevision: board.revision, at: time) }
        check(board == after, "Invalid compound operations publish no partial document changes")
        try board.apply(.rename(" Research "), expectedRevision: board.revision, at: time)
        try board.apply(.replace(edited), expectedRevision: board.revision, at: time)
        try board.apply(.reorder([first.id, second.id]), expectedRevision: board.revision, at: time)
        try board.apply(.remove([]), expectedRevision: board.revision, at: time)
        check(board == after, "No-op edits preserve revision and timestamps")
        try board.apply(.reorder([second.id, first.id]), expectedRevision: board.revision, at: time)
        check(board.items.map(\.id) == [second.id, first.id] && board.modifiedAt == Date(timeIntervalSinceReferenceDate: 110), "Layer reordering uses the requested permutation and a backward clock never regresses modification time")
        try board.apply(.remove([first.id]), expectedRevision: board.revision, at: time)
        try board.apply(.insert(missing), expectedRevision: board.revision, at: time)
        check(board.items.map(\.id) == [second.id, missing.id], "Removal preserves neighbors and insertion places a new item in front")
        check(try decoder.decode(Easel.self, from: encoder.encode(board)) == board, "Ordered canvas content roundtrips without losing revision or frames")
        let merged = Easel.merged([before], [before, after])
        check(merged.count == 2 && merged.first == before && merged[1].id != before.id && merged[1].items == after.items, "Merge deduplicates equal boards and preserves a conflicting board under a fresh identity")
        let mergedAgain = Easel.merged(merged, [after])
        check(mergedAgain.count == 2, "Repeated recovery of the same conflicting draft does not create endless copies")
        let durableMerge = try decoder.decode([Easel].self, from: encoder.encode(merged))
        check(Easel.merged(durableMerge, [after]).count == 2, "Recovered draft lineage survives relaunch without creating another copy")
        var repeatedLibrary = BrowserLibrary(); repeatedLibrary.easels = [before, after]
        var repeatedDocument = BrowserDocument(library: repeatedLibrary)
        try repeatedDocument.repairProfiles()
        let normalized = repeatedDocument.library(for: BrowserProfile.defaultID).easels ?? []
        check(normalized.count == 2 && Set(normalized.map(\.id)).count == 2, "A single malformed library also repairs colliding board identities without losing either draft")
        let separatelySaved = try Easel(title: before.title, createdAt: before.createdAt, modifiedAt: before.modifiedAt, revision: before.revision, items: before.items)
        var independentLibrary = BrowserLibrary(); independentLibrary.easels = [before, separatelySaved]
        var independentDocument = BrowserDocument(library: independentLibrary)
        try independentDocument.repairProfiles()
        check(independentDocument.library.easels?.map(\.id) == [before.id, separatelySaved.id], "Separately addressable boards retain both identities even when every other field matches")
        let old = try decoder.decode(BrowserDocument.self, from: encoder.encode(initial))
        check(old.library.easels == nil && old.library.bookmarks.isEmpty, "A library without Easels retains its existing data")
        check(duplicated.library(for: UUID()).easels == nil, "A different profile does not inherit another profile's canvases")
        var future = initial; future.formatVersion = BrowserDocument.currentFormatVersion + 1
        do { try future.repairProfiles(); check(false, "A future document cannot be rewritten by an older format") }
        catch is MetadataFormatError { check(true, "A future document cannot be rewritten by an older format") }
        for (x, y, w, h) in [(-1.0, 0.0, 100.0, 100.0), (0, -1, 100, 100), (0, 0, 39, 100), (0, 0, 100, 4097), (16300, 0, 100, 100), (0, 16300, 100, 100), (.infinity, 0, 100, 100), (0, .nan, 100, 100)] {
            rejects("Nonfinite, undersized or off-canvas frames are rejected") { _ = try EaselFrame(x: x, y: y, width: w, height: h) }
        }
        _ = try EaselFrame(x: 12288, y: 12288, width: 4096, height: 4096)
        check(true, "The far canvas boundary remains usable")
        rejects("Whitespace-only board titles are rejected") { _ = try Easel(title: " \n ") }
        rejects("Title limits count UTF-8 bytes rather than graphemes") { _ = try Easel(title: String(repeating: "😀", count: 65)) }
        rejects("Note limits count UTF-8 bytes") { _ = try EaselItem(frame: frame, content: .note(text: String(repeating: "😀", count: 4097))) }
        let boundedNote = try EaselItem(frame: frame, content: .note(text: String(repeating: "😀", count: 4096)))
        check(boundedNote.content == .note(text: String(repeating: "😀", count: 4096)), "A note at the UTF-8 boundary is preserved")
        for address in ["javascript:alert(1)", "file:///etc/passwd", "https://name:secret@example.com/", "//example.com/", "https:///", "https://example.com:70000/", "https://example.com/\nsecret"] {
            rejects("Link cards reject executable, relative, credential-bearing or malformed addresses") { _ = try EaselItem(frame: frame, content: .link(title: "Link", url: address)) }
        }
        let assetID = UUID()
        let image = try EaselItem(frame: frame, content: .image(assetID: assetID, pixelWidth: 8000, pixelHeight: 5000, sourceURL: "https://example.com/source", sourceTitle: "Capture"))
        let imageBoard = try Easel(title: "Capture", items: [image])
        check(try decoder.decode(Easel.self, from: encoder.encode(imageBoard)) == imageBoard, "Image asset identity, dimensions and source attribution roundtrip")
        for (w, h) in [(0, 100), (100, -1), (16385, 1), (8000, 5001)] {
            rejects("Image dimensions are bounded before any renderer can consume them") { _ = try EaselItem(frame: frame, content: .image(assetID: assetID, pixelWidth: w, pixelHeight: h, sourceURL: nil, sourceTitle: nil)) }
        }
        rejects("Capture attribution cannot conceal a non-web destination") { _ = try EaselItem(frame: frame, content: .image(assetID: assetID, pixelWidth: 1, pixelHeight: 1, sourceURL: "data:text/plain,secret", sourceTitle: nil)) }
        rejects("Duplicate item IDs cannot decode into an ambiguous editor selection") {
            var invalid = fixture
            invalid["items"] = [(fixture["items"] as! [[String: Any]])[0], (fixture["items"] as! [[String: Any]])[0]]
            _ = try decoder.decode(Easel.self, from: JSONSerialization.data(withJSONObject: invalid))
        }
        rejects("Saved off-canvas geometry is validated during decoding") {
            var invalid = fixture; var item = (fixture["items"] as! [[String: Any]])[0]
            item["frame"] = ["x": 16380, "y": 0, "width": 300, "height": 180]; invalid["items"] = [item]
            _ = try decoder.decode(Easel.self, from: JSONSerialization.data(withJSONObject: invalid))
        }
        rejects("Invalid saved content is validated during decoding") {
            var invalid = fixture; var item = (fixture["items"] as! [[String: Any]])[0]
            item["content"] = ["link": ["title": "Unsafe", "url": "javascript:alert(1)"]]; invalid["items"] = [item]
            _ = try decoder.decode(Easel.self, from: JSONSerialization.data(withJSONObject: invalid))
        }
        rejects("Nonfinite creation dates cannot enter a saved canvas") { _ = try Easel(title: "Bad date", createdAt: Date(timeIntervalSinceReferenceDate: .infinity)) }
        rejects("A modification date cannot predate creation") { _ = try Easel(title: "Bad date", createdAt: time, modifiedAt: time.addingTimeInterval(-1)) }
        let many = try (0..<500).map { _ in try EaselItem(frame: frame, content: .note(text: "")) }
        var full = try Easel(title: "Full board", items: many)
        let fullBefore = full
        rejects("A full board rejects another item without deleting existing material") { try full.apply(.insert(missing), expectedRevision: full.revision, at: Date()) }
        check(full == fullBefore, "Capacity failure leaves every existing item and revision intact")
        print("Easel core checks: \(checks) checked, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
