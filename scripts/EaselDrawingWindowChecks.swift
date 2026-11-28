import AppKit
import SwiftUI
import BrowserCore
import CryptoKit
import ScreenCaptureKit
import ImageIO

private struct OwnedWindowCaptureError: Error, CustomStringConvertible {
    let description: String
}

@MainActor private enum NativeOwnedWindowCapture {
    static func capture(_ window: NSWindow, kind: String, directory: String) async throws {
        guard CGPreflightScreenCaptureAccess() else {
            print("OWNED_WINDOW_CAPTURE_ENVIRONMENT_UNAVAILABLE screenRecordingNotAlreadyGranted")
            throw OwnedWindowCaptureError(description: "Owned-window capture needs an existing Screen Recording grant; no permission was requested or changed")
        }
        guard window.isVisible, window.windowNumber > 0 else {
            throw OwnedWindowCaptureError(description: "The owned native window is not visible")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let pid = ProcessInfo.processInfo.processIdentifier
        guard let owned = content.windows.first(where: {
            $0.windowID == CGWindowID(window.windowNumber) && $0.owningApplication?.processID == pid
        }) else {
            throw OwnedWindowCaptureError(description: "The exact owned window is unavailable to the OS compositor")
        }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(owned.frame.width.rounded(.up))
        configuration.height = Int(owned.frame.height.rounded(.up))
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: owned), configuration: configuration)
        guard image.width >= 400, image.height >= 300,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw OwnedWindowCaptureError(description: "The OS compositor did not return a usable owned-window image")
        }
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let name = kind + "-window.png"
        try png.write(to: root.appendingPathComponent(name), options: .atomic)
        let record: [String: Any] = ["method": "SCScreenshotManager.desktopIndependentWindow",
            "case": kind, "ownedProcessID": pid, "ownedWindowID": owned.windowID,
            "width": image.width, "height": image.height,
            "sha256": SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined(),
            "screenRecordingAlreadyGranted": true]
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent(kind + "-window.json"), options: .atomic)
        print("OWNED_WINDOW_CAPTURE_COMPLETE", kind, image.width, image.height)
    }
}

@main struct EaselDrawingWindowChecks {
    @MainActor static func run() async throws -> Int32 {
        var checks = 0, failures = 0
        func check(_ ok: Bool, _ name: String) { checks += 1; if !ok { failures += 1 }; print("\(ok ? "PASS" : "FAIL"): \(name)") }
        func until(_ predicate: () -> Bool) async -> Bool {
            for _ in 0..<250 { if predicate() { return true }; try? await Task.sleep(for: .milliseconds(20)) }
            return predicate()
        }
        guard let directory = ProcessInfo.processInfo.environment["ALCOVE_DRAWING_SCREENSHOT_DIR"] else { throw CocoaError(.fileNoSuchFile) }
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = BrowserStore(isPrivate: true); defer { store.shutdown() }
        store.preferences.automaticUpdateChecks = false
        let tab = try store.createEasel(title: "A little room for ideas")
        let board = store.easelContext(for: tab)!.easel
        let note = try EaselItem(frame: EaselFrame(x: 70, y: 70, width: 300, height: 220),
                                 content: .note(text: "A quieter corner of the web\n\nSketch an idea. Keep a few thoughts.\n\nEverything here belongs to this private test window."))
        let cg = CGContext(data: nil, width: 120, height: 100, bitsPerComponent: 8, bytesPerRow: 480,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        cg.setFillColor(CGColor(srgbRed: 0.80, green: 0.88, blue: 0.94, alpha: 1)); cg.fill(CGRect(x: 0, y: 0, width: 120, height: 100))
        cg.setFillColor(CGColor(srgbRed: 0.38, green: 0.60, blue: 0.51, alpha: 1)); cg.fill(CGRect(x: 0, y: 0, width: 120, height: 40))
        cg.setFillColor(CGColor(srgbRed: 0.97, green: 0.78, blue: 0.43, alpha: 1)); cg.fillEllipse(in: CGRect(x: 75, y: 60, width: 24, height: 24))
        let png = NSBitmapImageRep(cgImage: cg.makeImage()!).representation(using: .png, properties: [:])!
        let assets = try store.easelAssets(for: BrowserProfile.defaultID), assetID = try assets.put(png)
        let image = try EaselItem(frame: EaselFrame(x: 420, y: 70, width: 240, height: 210),
                                  content: .image(assetID: assetID, pixelWidth: 120, pixelHeight: 100, sourceURL: nil, sourceTitle: nil))
        var arrow = try EaselDrawingGesture(kind: .arrow, style: EaselDrawingStyle(color: "#DB3945", lineWidth: 5, opacity: 1),
                                            start: EaselCanvasSample(x: 240, y: 350))
        try arrow.append(EaselCanvasSample(x: 465, y: 275))
        _ = try store.editEasel(in: tab, expectedRevision: board.revision, edits: [.insert(note), .insert(image), .insert(arrow.makeItem())])
        let suite = "Alcove.DrawingWindow." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!; defaults.set(236.0, forKey: "sidebarWidth")
        defer { defaults.removePersistentDomain(forName: suite) }
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1100, height: 760), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Alcove Drawing QA"; window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: BrowserUI(store: store, sidebarDefaults: defaults).environmentObject(UpdateController(installedTag: "drawing-window-qa")))
        host.sizingOptions = []; host.safeAreaRegions = []; window.contentView = host
        defer { window.contentView = nil; window.close() }
        window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true)
        func find<T: NSView>(_ view: NSView, _ type: T.Type) -> T? {
            if let found = view as? T { return found }; return view.subviews.compactMap { find($0, type) }.first
        }
        let mounted = await until { find(host, EaselCanvasView.self)?.bounds.width ?? 0 > 500 && find(host, EaselDrawingControls.self) != nil && window.isKeyWindow }
        check(mounted, "The actual browser mounts drawing tools and the native canvas in an active owned window")
        guard let canvas = find(host, EaselCanvasView.self), let tools = find(host, EaselDrawingControls.self), let editor = canvas.cards[note.id]?.noteView else { return 1 }
        window.makeFirstResponder(canvas.canvas)
        func capture(_ name: String) async throws {
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try await Task.sleep(for: .milliseconds(150))
            try await NativeOwnedWindowCapture.capture(window, kind: name, directory: directory)
        }
        try await capture("drawing-select")
        tools.toolButtons[EaselCanvasTool.allCases.firstIndex(of: .pen)!].performClick(nil)
        check(canvas.drawingTool == .pen, "The visible native Pen button selects the mounted browser canvas")
        let prior = store.easelContext(for: tab)!.easel
        func mouse(_ type: NSEvent.EventType, at point: NSPoint) async throws {
            guard window.isKeyWindow, window.isVisible else { throw CocoaError(.userCancelled) }
            let location = canvas.drawingOverlay.convert(point, to: nil)
            let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
            NSApplication.shared.postEvent(event, atStart: false)
            try await Task.sleep(for: .milliseconds(40))
        }
        try await mouse(.leftMouseDown, at: NSPoint(x: 450, y: 150))
        for point in [NSPoint(x: 480, y: 115), NSPoint(x: 520, y: 130), NSPoint(x: 560, y: 185), NSPoint(x: 600, y: 150)] { try await mouse(.leftMouseDragged, at: point) }
        check(canvas.drawing.isDrawing && canvas.drawing.preview != nil && store.easelContext(for: tab)!.easel == prior, "Posted application mouse events preview ink over the image without writing the canvas")
        try await capture("drawing-preview")
        try await mouse(.leftMouseUp, at: NSPoint(x: 600, y: 150))
        let saved = await until { store.easelContext(for: tab)?.easel.items.count == 4 && !canvas.drawing.isDrawing }
        check(saved && canvas.cards[note.id]?.noteView === editor, "Actual mouse release commits the drawing while preserving the note editor")
        if let last = store.easelContext(for: tab)?.easel.items.last, case .drawing(let drawing) = last.content {
            check(drawing.points.count == 5, "The posted native drag preserves its five distinct board-space samples")
        } else { check(false, "Native drawing input produces a typed pen item") }
        _ = canvas.canvas.tryToPerform(NSSelectorFromString("undo:"), with: nil)
        check(store.easelContext(for: tab)!.easel.items == prior.items, "The native responder Undo removes the whole posted gesture")
        _ = canvas.canvas.tryToPerform(NSSelectorFromString("redo:"), with: nil)
        check(store.easelContext(for: tab)!.easel.items.count == 4, "Native Redo restores the posted gesture as one item")
        _ = canvas.setDrawingTool(.select)
        window.makeFirstResponder(editor)
        editor.insertText(" Saved.", replacementRange: NSRange(location: (editor.string as NSString).length, length: 0))
        try store.easelDrafts.flush(tabID: tab)
        try await capture("drawing-saved")
        window.setContentSize(NSSize(width: 660, height: 520))
        find(host, SidebarResizeHandle.Handle.self)?.setAccessibilityValue(NSNumber(value: 340))
        let compact = await until { tools.bounds.width > 50 && tools.bounds.width < 600 && canvas.bounds.width > 50 }
        print("DRAWING_NARROW_GEOMETRY window=\(host.bounds.width) tools=\(tools.bounds.width) canvas=\(canvas.bounds.width) sidebar=\(String(describing: find(host, SidebarResizeHandle.Handle.self)?.accessibilityValue()))")
        check(compact && tools.subviews.filter { !$0.isHidden }.allSatisfy { $0.frame.minX >= 0 && $0.frame.maxX <= tools.bounds.width }, "A real narrow browser/sidebar resize keeps every visible drawing control inside its pane")
        check(canvas.cards[note.id]?.noteView === editor && editor.string.hasSuffix(" Saved."), "Narrow resizing preserves typed note input and its mounted editor")
        try await capture("drawing-compact")
        window.setContentSize(NSSize(width: 1100, height: 760))
        find(host, SidebarResizeHandle.Handle.self)?.setAccessibilityValue(NSNumber(value: 236))
        store.setTheme(.ocean)
        _ = await until { tools.bounds.width > 500 && canvas.appearance?.name == .darkAqua }
        _ = canvas.setDrawingTool(.ellipse)
        _ = canvas.setDrawingStyle(try EaselDrawingStyle(color: "#FFFFFF", lineWidth: 6, opacity: 1))
        try await mouse(.leftMouseDown, at: NSPoint(x: 100, y: 340))
        try await mouse(.leftMouseDragged, at: NSPoint(x: 350, y: 450))
        try await mouse(.leftMouseUp, at: NSPoint(x: 350, y: 450))
        check(store.easelContext(for: tab)!.easel.items.count == 5, "The actual dark-theme canvas accepts a white ellipse from native input")
        try await capture("drawing-dark")
        canvas.setZoom(0.5)
        check(canvas.cards[note.id]?.noteView === editor && canvas.magnification == 0.5, "Zooming the real window preserves editable note identity")
        try await capture("drawing-half-zoom")
        // Preserve the original compositor result, then observe whether an
        // explicit document repaint changes the apparent zoom-tile boundary.
        canvas.canvas.needsDisplay = true
        try await capture("drawing-half-zoom-refresh-control")
        guard let paper = canvas.canvas.background.usingColorSpace(.sRGB) else { throw CocoaError(.fileWriteUnknown) }
        let export = EaselCanvasExport(easel: store.easelContext(for: tab)!.easel, assets: assets, background: ThemeColor(paper.redComponent, paper.greenComponent, paper.blueComponent))
        try export.png().write(to: root.appendingPathComponent("canvas.png"), options: .atomic)
        try export.html().write(to: root.appendingPathComponent("canvas.html"), options: .atomic)
        check(store.views[tab] == nil && store.easelDrafts.failures(in: store).isEmpty, "The complete native drawing flow uses no website view and leaves no unsaved drafts")
        window.setContentSize(NSSize(width: 660, height: 520))
        find(host, SidebarResizeHandle.Handle.self)?.setAccessibilityValue(NSNumber(value: 340))
        _ = try store.createEasel(title: "Another little idea")
        let split = store.openInSplit(tab, at: .left)
        func all<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap { all($0, type) }
        }
        let splitMounted = await until {
            let bars = all(host, EaselDrawingControls.self)
            return bars.count == 2 && bars.allSatisfy { $0.bounds.width > 50 && $0.bounds.width < 286 }
        }
        let bars = all(host, EaselDrawingControls.self)
        check(split && splitMounted && bars.allSatisfy { bar in bar.subviews.filter { !$0.isHidden }.allSatisfy { $0.frame.minX >= 0 && $0.frame.maxX <= bar.bounds.width } }, "Actual narrow split panes retain bounded compact drawing menus")
        check(store.easelContext(for: tab)?.easel.items.count == 5 && store.easelDrafts.failures(in: store).isEmpty, "Opening the compact split preserves every saved drawing and note")
        try await capture("drawing-split")
        print("Easel drawing window checks: \(checks) checked, \(failures) failed")
        return failures == 0 ? 0 : 1
    }
    @MainActor static func main() {
        setbuf(stdout, nil); NSApplication.shared.setActivationPolicy(.regular)
        Task { @MainActor in
            do { exit(try await run()) }
            catch { print("FAIL: owned drawing window: \(error)"); exit(1) }
        }
        NSApplication.shared.run()
    }
}
