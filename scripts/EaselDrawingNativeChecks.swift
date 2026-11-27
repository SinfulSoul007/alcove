import AppKit
import BrowserCore
import ImageIO
import WebKit

@main struct EaselDrawingNativeChecks {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited); setbuf(stdout, nil)
        var checked = 0, failed = 0
        func check(_ value: Bool, _ name: String) { checked += 1; if !value { failed += 1 }; print("\(value ? "PASS" : "FAIL"): \(name)") }
        func bitmap(_ width: Int, _ height: Int) -> CGContext {
            let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.clear(CGRect(x: 0, y: 0, width: width, height: height)); return c
        }
        func pixel(_ c: CGContext, _ x: Int, _ y: Int) -> [UInt8] {
            let p = c.data!.assumingMemoryBound(to: UInt8.self).advanced(by: c.bytesPerRow * (c.height - 1 - y) + x * 4)
            return Array(UnsafeBufferPointer(start: p, count: 4))
        }
        let store = BrowserStore(isPrivate: true); defer { store.shutdown() }
        let tab = try store.createEasel(title: "Owned drawing canvas"), board = store.easelContext(for: tab)!.easel
        let frame = try EaselFrame(x: 80, y: 80, width: 320, height: 220)
        let note = try EaselItem(frame: frame, content: .note(text: "Keep the underlying note"))
        let drawing = try EaselDrawing(kind: .line, viewBoxWidth: 100, viewBoxHeight: 80,
                                      points: [EaselDrawingPoint(x: 10, y: 40), EaselDrawingPoint(x: 90, y: 40)],
                                      style: EaselDrawingStyle(color: "#FF0000", lineWidth: 4, opacity: 1))
        let mark = try EaselItem(frame: frame, content: .drawing(drawing))
        _ = try store.editEasel(in: tab, expectedRevision: board.revision, edits: [.insert(note), .insert(mark)])
        let canvas = EaselCanvasView(store: store, tabID: tab)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = canvas
        defer { window.contentView = nil; window.close() }
        canvas.reconcile(); canvas.layoutSubtreeIfNeeded()
        let card = canvas.cards[mark.id]!, noteCard = canvas.cards[note.id]!, noteEditor = noteCard.noteView
        let ink = bitmap(320, 220)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: ink, flipped: true)
        card.draw(card.bounds); NSGraphicsContext.restoreGraphicsState()
        check(pixel(ink, 160, 110) == [255, 0, 0, 255] && pixel(ink, 30, 30) == [0, 0, 0, 0], "The real drawing card paints only ink with a transparent empty area")
        check(card.hitTest(NSPoint(x: 240, y: 190)) === card, "Actual card hit testing selects the visible drawing path")
        check(card.hitTest(NSPoint(x: 240, y: 140)) == nil, "Actual card hit testing ignores empty parts of its bounding rectangle")
        let through = canvas.canvas.hitTest(NSPoint(x: 240, y: 140))
        check(through === noteCard || through?.isDescendant(of: noteCard) == true, "A drawing above a note lets empty-area clicks reach the underlying editor")
        check(card.accessibilityLabel()?.contains("drawing") == true, "The native drawing item exposes a descriptive accessibility label")
        canvas.select(mark.id)
        check(canvas.moveSelected(dx: 40, dy: 20), "Existing native selection movement edits a drawing")
        let moved = store.easelContext(for: tab)!.easel.items.first { $0.id == mark.id }!
        check(moved.frame.x == 120 && moved.frame.y == 100 && moved.content == .drawing(drawing), "Moving a drawing preserves all editable stroke content")
        canvas.undoManager?.undo()
        check(store.easelContext(for: tab)!.easel.items.last == mark, "Native canvas undo restores the exact drawing item")
        canvas.undoManager?.redo()
        check(store.easelContext(for: tab)!.easel.items.last == moved, "Native canvas redo restores the drawing movement")
        check(canvas.cards[note.id] === noteCard && noteCard.noteView === noteEditor, "Drawing changes preserve the mounted underlying note editor")

        let exportDrawing = try EaselDrawing(kind: .line, viewBoxWidth: 100, viewBoxHeight: 100,
                                            points: [EaselDrawingPoint(x: 10, y: 50), EaselDrawingPoint(x: 90, y: 50)], style: drawing.style)
        let exportItem = try EaselItem(frame: EaselFrame(x: 100, y: 100, width: 200, height: 200), content: .drawing(exportDrawing))
        let exportBoard = try Easel(title: "Offline vector canvas", items: [exportItem])
        let exporter = EaselCanvasExport(easel: exportBoard, assets: EaselAssetStore(privateProfileID: UUID()))
        let png = try exporter.png()
        guard let source = CGImageSourceCreateWithData(png as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw CocoaError(.fileReadCorruptFile) }
        let output = bitmap(image.width, image.height); output.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        check(pixel(output, image.width / 2, image.height / 2) == [255, 0, 0, 255], "Actual PNG export includes the vector ink at its transformed location")
        let paper = pixel(output, 136, 136)
        check((247...249).contains(paper[0]) && (248...250).contains(paper[1]) && (250...252).contains(paper[2]), "PNG drawing layers preserve canvas paper without a note-card fill")
        let white = try EaselDrawing(kind: .line, viewBoxWidth: 100, viewBoxHeight: 100, points: exportDrawing.points,
                                    style: EaselDrawingStyle(color: "#FFFFFF", lineWidth: 4, opacity: 1))
        let whiteItem = try EaselItem(frame: exportItem.frame, content: .drawing(white))
        let darkBoard = try Easel(title: "White ink", items: [whiteItem])
        let darkExporter = EaselCanvasExport(easel: darkBoard, assets: EaselAssetStore(privateProfileID: UUID()), background: .black)
        let darkPNG = try darkExporter.png()
        guard let darkSource = CGImageSourceCreateWithData(darkPNG as CFData, nil), let darkImage = CGImageSourceCreateImageAtIndex(darkSource, 0, nil) else { throw CocoaError(.fileReadCorruptFile) }
        let darkPixels = bitmap(darkImage.width, darkImage.height)
        darkPixels.draw(darkImage, in: CGRect(x: 0, y: 0, width: darkImage.width, height: darkImage.height))
        check(pixel(darkPixels, darkImage.width / 2, darkImage.height / 2) == [255, 255, 255, 255] && pixel(darkPixels, 136, 136) == [0, 0, 0, 255],
              "Light ink remains visible on its captured dark paper in the actual PNG")
        let html = try exporter.html(), configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700), configuration: configuration)
        defer { web.stopLoading(); web.loadHTMLString("", baseURL: nil) }
        web.load(html, mimeType: "text/html", characterEncodingName: "UTF-8", baseURL: URL(string: "about:blank")!)
        for _ in 0..<1000 {
            if (try? await web.evaluateJavaScript("document.readyState==='complete' && document.querySelectorAll('svg path').length===1")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        check((try? await web.evaluateJavaScript("document.querySelector('path').getTotalLength()")) as? Double == 80, "Real offline WebKit reconstructs the original SVG shaft geometry")
        check((try? await web.evaluateJavaScript("const s=document.querySelector('.drawing');getComputedStyle(s).backgroundColor==='rgba(0, 0, 0, 0)' && getComputedStyle(s).paddingTop==='0px' && getComputedStyle(s).borderTopWidth==='0px'")) as? Bool == true, "The offline drawing layer has no card background, border or layout padding")
        check((try? await web.evaluateJavaScript("const r=document.querySelector('svg').getBoundingClientRect();r.width===200 && r.height===200 && document.querySelectorAll('script,iframe,object').length===0")) as? Bool == true, "Real offline SVG preserves item dimensions inside the inert document")
        let darkHTML = try darkExporter.html()
        web.load(darkHTML, mimeType: "text/html", characterEncodingName: "UTF-8", baseURL: URL(string: "about:blank")!)
        for _ in 0..<1000 {
            if (try? await web.evaluateJavaScript("document.readyState==='complete' && document.title==='White ink'")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        check((try? await web.evaluateJavaScript("getComputedStyle(document.querySelector('main')).backgroundColor==='rgb(0, 0, 0)' && getComputedStyle(document.querySelector('path')).stroke==='rgb(255, 255, 255)'")) as? Bool == true,
              "Actual offline HTML preserves the requested dark paper behind light vector ink")
        check((try? await web.evaluateJavaScript("getComputedStyle(document.querySelector('header')).color==='rgb(255, 255, 255)'")) as? Bool == true,
              "A dark-paper export keeps its canvas title readable")
        print("Easel drawing native checks: \(checked) checked, \(failed) failed")
        if failed != 0 { exit(1) }
    }
}
