import AppKit
import BrowserCore
import WebKit

@main struct EaselDrawingReviewChecks {
    @MainActor static func run() async throws -> Int32 {
        var checked = 0, failed = 0
        func check(_ value: Bool, _ name: String) {
            checked += 1; if !value { failed += 1 }
            print("\(value ? "PASS" : "FAIL"): \(name)")
        }
        let store = BrowserStore(isPrivate: true); defer { store.shutdown() }
        let tab = try store.createEasel(title: "Before sibling edit")
        let canvas = EaselCanvasView(store: store, tabID: tab)
        _ = canvas.setDrawingTool(.pen)
        _ = canvas.drawing.begin(at: NSPoint(x: 100, y: 120))
        canvas.drawing.append(NSPoint(x: 170, y: 190))
        let pending = canvas.drawing.preview!
        _ = try store.editEasel(in: tab, expectedRevision: canvas.context!.easel.revision, edits: [.rename("Keep sibling title")])
        check(!canvas.drawing.finish(), "A conflicting complete drawing is retained for recovery")
        let state = store.easelDrafts.failures(in: store).first!
        let beforeRecovery = canvas.context!.easel
        let recovered = try store.easelDrafts.saveAsNewNote(state, from: store)
        let recoveredItem = canvas.context!.easel.items.first { $0.id == recovered }!
        check(recoveredItem.frame == pending.frame && recoveredItem.content == pending.content,
              "Recovering an annotation preserves its exact board placement and complete ink")
        check(store.message == nil, "Successful drawing recovery clears its resolved failure message")
        canvas.undoManager?.undo()
        check(canvas.context!.easel.items == beforeRecovery.items && canvas.context!.easel.title == "Keep sibling title",
              "One Undo removes the recovered mark while preserving the sibling edit")
        canvas.undoManager?.redo()
        check(canvas.context!.easel.items == [recoveredItem] && canvas.context!.easel.title == "Keep sibling title",
              "One Redo restores the recovered mark without reverting the sibling title")

        // Exercise the same public recovery action against both document limits.
        for pointBudget in [false, true] {
            let fullStore = BrowserStore(isPrivate: true); defer { fullStore.shutdown() }
            let fullTab = try fullStore.createEasel(title: pointBudget ? "Point budget" : "Item budget")
            let frame = try EaselFrame(x: 60, y: 60, width: 80, height: 80)
            let items: [EaselItem]
            if pointBudget {
                let points = try (0..<4096).map { try EaselDrawingPoint(x: $0 % 2 == 0 ? 10 : 70, y: 40) }
                let drawing = try EaselDrawing(kind: .pen, viewBoxWidth: 80, viewBoxHeight: 80, points: points,
                                              style: EaselDrawingStyle(color: "#123456", lineWidth: 2, opacity: 1))
                items = try (0..<16).map { _ in try EaselItem(frame: frame, content: .drawing(drawing)) }
            } else {
                items = try (0..<500).map { _ in try EaselItem(frame: frame, content: .note(text: "Keep saved card")) }
            }
            _ = try fullStore.editEasel(in: fullTab, expectedRevision: fullStore.easelContext(for: fullTab)!.easel.revision, edits: items.map(EaselEdit.insert))
            let fullCanvas = EaselCanvasView(store: fullStore, tabID: fullTab)
            _ = fullCanvas.setDrawingTool(.pen); _ = fullCanvas.drawing.begin(at: NSPoint(x: 200, y: 220))
            fullCanvas.drawing.append(NSPoint(x: 280, y: 260))
            let expected = fullCanvas.drawing.preview!
            let original = fullCanvas.context!.easel
            check(!fullCanvas.drawing.finish(), "A full \(pointBudget ? "sample" : "item") budget retains the complete failed mark")
            let retained = fullStore.easelDrafts.failures(in: fullStore).first!
            if pointBudget { fullStore.message = "Keep this unrelated status" }
            do {
                let id = try fullStore.easelDrafts.saveAsNewNote(retained, from: fullStore, recoveredTitle: "Recovered full canvas")
                let newBoard = fullStore.library.easels!.first { $0.id != original.id }
                check(newBoard?.title == "Recovered full canvas" && newBoard?.items.count == 1 && newBoard?.items.first?.id == id && newBoard?.items.first?.frame == expected.frame && newBoard?.items.first?.content == expected.content && fullStore.easelContext(for: fullTab)!.easel == original && fullStore.easelDrafts.failures(in: fullStore).isEmpty,
                      "Recovery escapes the \(pointBudget ? "sample" : "item") limit into a new same-profile canvas without changing the original")
                check(fullStore.message == (pointBudget ? "Keep this unrelated status" : nil),
                      "Recovery clears only its own obsolete warning and preserves unrelated status")
            } catch {
                print("RECOVERY_LIMIT_ERROR", error.localizedDescription)
                check(false, "Recovery escapes the \(pointBudget ? "sample" : "item") limit into a new same-profile canvas without changing the original")
                _ = fullStore.easelDrafts.discard(retained, from: fullStore)
            }
        }

        let focusedStore = BrowserStore(isPrivate: true); defer { focusedStore.shutdown() }
        let focusedTab = try focusedStore.createEasel(title: "Focus ownership")
        let focusedCanvas = EaselCanvasView(store: focusedStore, tabID: focusedTab)
        let first = NSWindow(contentRect: NSRect(x: 100, y: 140, width: 650, height: 450), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let second = NSWindow(contentRect: NSRect(x: 150, y: 180, width: 300, height: 200), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        first.isReleasedWhenClosed = false; second.isReleasedWhenClosed = false
        first.contentView = focusedCanvas
        defer { first.contentView = nil; first.close(); second.close() }
        first.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true)
        for _ in 0..<100 { if first.isKeyWindow && NSApp.isActive { break }; try await Task.sleep(for: .milliseconds(20)) }
        check(first.isKeyWindow && NSApp.isActive, "The focus test starts in an actually active key window")
        _ = focusedCanvas.setDrawingTool(.pen)
        let began = focusedCanvas.drawing.begin(at: NSPoint(x: 120, y: 120))
        focusedCanvas.drawing.append(NSPoint(x: 180, y: 160))
        second.makeKeyAndOrderFront(nil)
        for _ in 0..<100 { if second.isKeyWindow { break }; try await Task.sleep(for: .milliseconds(20)) }
        check(began && second.isKeyWindow && !first.isKeyWindow, "Another real native window takes key focus during the stroke")
        let mouseUp = NSEvent.mouseEvent(with: .leftMouseUp, location: focusedCanvas.drawingOverlay.convert(NSPoint(x: 200, y: 180), to: nil), modifierFlags: [], timestamp: 0, windowNumber: first.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        focusedCanvas.drawingOverlay.mouseUp(with: mouseUp)
        check(!focusedCanvas.drawing.isDrawing && focusedCanvas.context!.easel.items.isEmpty && focusedStore.easelDrafts.failures(in: focusedStore).isEmpty,
              "A late mouse-up after losing window focus cannot publish or retain an incomplete stroke")
        first.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true)
        for _ in 0..<100 { if first.isKeyWindow && NSApp.isActive { break }; try await Task.sleep(for: .milliseconds(20)) }
        let beganBeforeHide = focusedCanvas.drawing.begin(at: NSPoint(x: 120, y: 120))
        focusedCanvas.drawing.append(NSPoint(x: 180, y: 160))
        NSApplication.shared.hide(nil)
        for _ in 0..<100 { if !NSApp.isActive { break }; try await Task.sleep(for: .milliseconds(20)) }
        check(beganBeforeHide && !NSApp.isActive, "Hiding the owned application actually relinquishes application focus")
        focusedCanvas.drawingOverlay.mouseUp(with: mouseUp)
        check(!focusedCanvas.drawing.isDrawing && focusedCanvas.context!.easel.items.isEmpty && focusedStore.easelDrafts.failures(in: focusedStore).isEmpty,
              "A late mouse-up after application deactivation cannot publish or retain an incomplete stroke")

        let dot = try EaselDrawing(kind: .pen, viewBoxWidth: 40, viewBoxHeight: 40,
                                  points: [EaselDrawingPoint(x: 1, y: 1)], style: EaselDrawingStyle(color: "#FF0000", lineWidth: 2, opacity: 1))
        let dotItem = try EaselItem(frame: EaselFrame(x: 500, y: 100, width: 40, height: 40), content: .drawing(dot))
        let link = try EaselItem(frame: EaselFrame(x: 100, y: 100, width: 320, height: 180), content: .link(title: "Open saved source", url: "https://example.com/source"))
        let outline = try EaselDrawing(kind: .rectangle, viewBoxWidth: 320, viewBoxHeight: 180,
                                      points: [EaselDrawingPoint(x: 4, y: 4), EaselDrawingPoint(x: 316, y: 176)], style: dot.style)
        let outlineItem = try EaselItem(frame: link.frame, content: .drawing(outline))
        let export = try EaselHTMLExport(easel: Easel(title: "Corner and link", items: [link, dotItem, outlineItem]), pngForAsset: { _ in Data() })
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 600), configuration: configuration)
        defer { web.stopLoading(); web.loadHTMLString("", baseURL: nil) }
        web.load(export.data, mimeType: "text/html", characterEncodingName: "UTF-8", baseURL: URL(string: "about:blank")!)
        for _ in 0..<1000 {
            if (try? await web.evaluateJavaScript("document.readyState==='complete' && document.querySelectorAll('svg').length===2")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let hitLink = (try? await web.evaluateJavaScript("(()=>{const a=document.querySelector('a'),r=a.getBoundingClientRect();return document.elementFromPoint(r.x+r.width/2,r.y+r.height/2)===a})()")) as? Bool == true
        check(hitLink, "Transparent exported drawing layers let actual hit testing reach a saved source link")
        let rect = try await web.evaluateJavaScript("(()=>{const r=document.querySelectorAll('.drawing')[0].getBoundingClientRect();return [r.x,r.y,r.width,r.height]})()") as! [Double]
        let snapshot = WKSnapshotConfiguration(); snapshot.rect = NSRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3]); snapshot.snapshotWidth = 160
        let rendered: NSImage = try await withCheckedThrowingContinuation { continuation in web.takeSnapshot(with: snapshot) { image, error in if let image { continuation.resume(returning: image) } else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) } } }
        let pixels = NSBitmapImageRep(data: rendered.tiffRepresentation!)!
        let corner = pixels.colorAt(x: Int(4 * Double(pixels.pixelsWide) / 160), y: Int(4 * Double(pixels.pixelsHigh) / 160))!.usingColorSpace(.sRGB)!
        print("CORNER_PIXEL", corner.redComponent, corner.greenComponent, corner.blueComponent)
        check(corner.redComponent > 0.9 && corner.greenComponent < 0.15 && corner.blueComponent < 0.15,
              "Real WebKit keeps visible ink at a valid drawing's near-corner point")
        print("Easel drawing review checks: \(checked) checked, \(failed) failed")
        return failed == 0 ? 0 : 1
    }
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.regular); setbuf(stdout, nil)
        Task { @MainActor in
            do { exit(try await run()) }
            catch { print("FAIL: native drawing review fixture: \(error)"); exit(1) }
        }
        NSApplication.shared.run()
    }
}
