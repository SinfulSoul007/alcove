import Foundation
import CryptoKit
import BrowserCore

private final class SVGProbe: NSObject, XMLParserDelegate {
    var nodes: [(String, [String: String])] = []
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        nodes.append((elementName, attributeDict))
    }
}

@main struct EaselDrawingDocumentChecks {
    static func main() throws {
        var checked = 0, failed = 0
        func check(_ value: Bool, _ name: String) { checked += 1; if !value { failed += 1 }; print("\(value ? "PASS" : "FAIL"): \(name)") }
        func rejects(_ name: String, _ body: () throws -> Void) {
            do { try body(); check(false, name) }
            catch EaselError.invalidContent { check(true, name) }
            catch { check(false, name + " (unexpected \(error))") }
        }
        let style = try EaselDrawingStyle(color: "#FF0000", lineWidth: 4, opacity: 0.5)
        let points = try [EaselDrawingPoint(x: 10, y: 10), EaselDrawingPoint(x: 20, y: 30), EaselDrawingPoint(x: 30, y: 10)]
        let drawing = try EaselDrawing(kind: .pen, viewBoxWidth: 100, viewBoxHeight: 80, points: points, style: style)
        let frame = try EaselFrame(x: 40, y: 80, width: 200, height: 160)
        let item = try EaselItem(frame: frame, content: .drawing(drawing))
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        encoder.outputFormatting = [.sortedKeys]
        check(try decoder.decode(EaselItem.self, from: encoder.encode(item)) == item, "Canvas-item roundtrip retains the editable drawing and its frame")
        let canary = "Owned vector drawing privacy canary 2034"
        let board = try Easel(title: canary, items: [item])
        var document = BrowserDocument(); document.library.easels = [board]
        try document.repairProfiles()
        check(document.formatVersion.map { $0 >= 10 } == true && document.library.easels == [board], "Drawing documents declare a format newer than old readers can safely write")
        var old = BrowserDocument(); old.formatVersion = 9
        let oldBoard = try Easel(title: "Previous canvas", items: [EaselItem(frame: frame, content: .note(text: "Retained previous note"))])
        old.library.easels = [oldBoard]; try old.repairProfiles()
        check(old.library.easels == [oldBoard] && old.formatVersion.map { $0 >= 10 } == true, "Format9 canvases migrate without losing their earlier item content")
        var future = document; future.formatVersion = BrowserDocument.currentFormatVersion + 1
        let beforeFuture = try encoder.encode(future)
        do { try future.repairProfiles(); check(false, "Unsupported future metadata is refused") }
        catch MetadataFormatError.unsupportedVersion { check(true, "Unsupported future metadata is refused") }
        check(try encoder.encode(future) == beforeFuture, "Refusing a future document preserves the entire input value")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256), url = root.appendingPathComponent("document.enc")
        let vault = MetadataStore(url: url, key: key)
        try vault.save(document)
        let restored = try vault.load(BrowserDocument.self)
        check(restored?.library.easels == [board], "The real encrypted metadata writer restores the exact vector drawing")
        let ciphertext = try Data(contentsOf: url)
        check(ciphertext.range(of: Data(canary.utf8)) == nil, "The saved drawing document does not expose its owned plaintext marker")
        let privateURL = root.appendingPathComponent("private-never-created/document.enc")
        let privateVault = MetadataStore(url: privateURL, key: key, isPrivate: true)
        try privateVault.save(document)
        check(!FileManager.default.fileExists(atPath: privateURL.deletingLastPathComponent().path), "Private drawing persistence creates neither a plaintext nor an encrypted file")

        let dense = try EaselDrawing(kind: .pen, viewBoxWidth: 100, viewBoxHeight: 80,
                                    points: Array(repeating: EaselDrawingPoint(x: 20, y: 20), count: 4096), style: style)
        let denseItems = try (0..<16).map { _ in try EaselItem(frame: frame, content: .drawing(dense)) }
        var full = try Easel(title: "Point budget", items: denseItems)
        let dot = try EaselDrawing(kind: .pen, viewBoxWidth: 100, viewBoxHeight: 80, points: [EaselDrawingPoint(x: 20, y: 20)], style: style)
        let extra = try EaselItem(frame: frame, content: .drawing(dot))
        let beforeFull = try encoder.encode(full), fullRevision = full.revision
        rejects("A single excess sample cannot exceed the aggregate canvas point budget") { try full.apply(.insert(extra), expectedRevision: full.revision) }
        check(try encoder.encode(full) == beforeFull && full.revision == fullRevision, "Rejected oversized edits keep the entire canvas and revision unchanged")
        rejects("Oversized saved canvases are refused during construction") { _ = try Easel(title: "Too many samples", items: denseItems + [extra]) }
        var oversized = try JSONSerialization.jsonObject(with: beforeFull) as! [String: Any]
        var oversizedItems = oversized["items"] as! [Any]
        oversizedItems.append(try JSONSerialization.jsonObject(with: encoder.encode(extra)))
        oversizedItems.append("this later excess item must never be decoded")
        oversized["items"] = oversizedItems
        rejects("Saved canvas decoding stops at the point budget before processing a later malformed item") {
            _ = try decoder.decode(Easel.self, from: JSONSerialization.data(withJSONObject: oversized))
        }
        try full.apply(.remove([denseItems[0].id]), expectedRevision: full.revision)
        try full.apply(.insert(extra), expectedRevision: full.revision)
        check(full.items.count == 16 && full.items.last == extra, "Removing a dense stroke frees its point budget for a new mark")

        let markup = EaselDrawingSVG.markup(for: drawing)
        let probe = SVGProbe(), parser = XMLParser(data: Data(markup.utf8)); parser.delegate = probe
        check(parser.parse() && probe.nodes.map(\.0) == ["svg", "path"], "The standalone export is valid SVG containing only locally generated path geometry")
        let svg = probe.nodes.first?.1 ?? [:], path = probe.nodes.last?.1 ?? [:]
        check(svg["preserveAspectRatio"] == "none" && svg["viewBox"]?.split(separator: " ").compactMap { Double($0) } == [0, 0, 100, 80], "SVG uses the same logical box and complete item resize transform")
        check(path["stroke"] == "#FF0000" && path["fill"] == "none" && Double(path["stroke-width"] ?? "") == 4 && Double(path["opacity"] ?? "") == 0.5,
              "The portable path retains explicit ink color, thickness and opacity")
        check(path["stroke-linecap"] == "round" && path["stroke-linejoin"] == "round", "SVG strokes use the native renderer's rounded endpoint and join contract")
        let dotMarkup = EaselDrawingSVG.markup(for: dot)
        let dotProbe = SVGProbe(), dotParser = XMLParser(data: Data(dotMarkup.utf8)); dotParser.delegate = dotProbe
        check(dotParser.parse() && dotProbe.nodes.last?.1["fill"] == "#FF0000" && dotProbe.nodes.last?.1["stroke"] == "none", "A single-point mark exports as visible filled ink")
        let html = try EaselHTMLExport(easel: board, pngForAsset: { _ in throw CocoaError(.fileNoSuchFile) })
        let exported = String(decoding: html.data, as: UTF8.self)
        check(exported.contains(markup) && exported.contains("card drawing"), "Portable HTML includes the complete vector drawing in a transparent drawing layer")
        check(exported.contains("default-src 'none'") && exported.contains("script-src 'none'") && !exported.contains("<script") && !exported.contains("<iframe"), "Drawing export preserves the existing inert offline document policy")
        print("Easel drawing document checks: \(checked) checked, \(failed) failed")
        if failed != 0 { exit(1) }
    }
}
