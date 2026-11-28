import AppKit
import SwiftUI
import BrowserCore
import CryptoKit
import ScreenCaptureKit

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

@main struct EaselDrawingRestoreWindowChecks {
    @MainActor static func run() async throws -> Int32 {
        var checks = 0, failures = 0, keyRequests = 0
        func check(_ ok: Bool, _ name: String) { checks += 1; if !ok { failures += 1 }; print("\(ok ? "PASS" : "FAIL"): \(name)") }
        func until(_ test: () -> Bool) async -> Bool {
            for _ in 0..<400 { if test() { return true }; try? await Task.sleep(for: .milliseconds(20)) }
            return test()
        }
        func all<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap { all($0, type) }
        }
        guard let directory = ProcessInfo.processInfo.environment["ALCOVE_DRAWING_SCREENSHOT_DIR"] else { throw CocoaError(.fileNoSuchFile) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Alcove.DrawingWindowRestore." + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256)
        let store = BrowserStore(dataRoot: root, keyProvider: { _ in keyRequests += 1; return key })
        defer { store.shutdown() }
        store.onboardingVisible = false; store.preferences.onboardingCompleted = true; store.preferences.automaticUpdateChecks = false
        let tab = try store.createEasel(title: "Saved sketchbook")
        let note = try EaselItem(frame: EaselFrame(x: 70, y: 70, width: 300, height: 210), content: .note(text: "Only this owned normal-window fixture."))
        _ = try store.editEasel(in: tab, expectedRevision: store.easelContext(for: tab)!.easel.revision, edits: [.insert(note)])
        let defaultsName = "Alcove.DrawingRestore." + UUID().uuidString
        let defaults = UserDefaults(suiteName: defaultsName)!; defaults.set(236.0, forKey: "sidebarWidth")
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let delegate = AppDelegate()
        func makeWindow(_ source: BrowserStore) -> (NSWindow, NSHostingView<some View>) {
            let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1100, height: 760), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "Alcove Owned Restore QA"; window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: BrowserUI(store: source, sidebarDefaults: defaults).environmentObject(UpdateController(installedTag: "drawing-restore-qa")))
            host.sizingOptions = []; host.safeAreaRegions = []; window.contentView = host
            window.delegate = delegate; delegate.windows[window] = source
            window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true)
            return (window, host)
        }
        let (window, host) = makeWindow(store)
        defer { delegate.windows.removeValue(forKey: window); window.delegate = nil; window.contentView = nil; window.close() }
        let mounted = await until { all(host, EaselCanvasView.self).first?.bounds.width ?? 0 > 500 && window.isKeyWindow }
        check(mounted, "The owned normal browser window mounts its editable native canvas")
        guard let canvas = all(host, EaselCanvasView.self).first, let tools = all(host, EaselDrawingControls.self).first else { return 1 }
        let editor = canvas.cards[note.id]?.noteView
        window.makeFirstResponder(canvas.canvas)
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint, in view: NSView, window target: NSWindow) async throws {
            let event = NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: target.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
            NSApplication.shared.postEvent(event, atStart: false); try await Task.sleep(for: .milliseconds(50))
        }
        func draw(_ start: NSPoint, _ end: NSPoint) async throws {
            tools.toolButtons[EaselCanvasTool.allCases.firstIndex(of: .pen)!].performClick(nil)
            try await mouse(.leftMouseDown, start, in: canvas.drawingOverlay, window: window)
            try await mouse(.leftMouseDragged, end, in: canvas.drawingOverlay, window: window)
            try await mouse(.leftMouseUp, end, in: canvas.drawingOverlay, window: window)
        }
        func capture(_ target: NSWindow, _ name: String) async throws {
            target.contentView?.layoutSubtreeIfNeeded(); target.displayIfNeeded(); try await Task.sleep(for: .milliseconds(150))
            try await NativeOwnedWindowCapture.capture(target, kind: name, directory: directory)
        }
        try await draw(NSPoint(x: 410, y: 120), NSPoint(x: 590, y: 240))
        check(store.easelContext(for: tab)!.easel.items.count == 2 && canvas.cards[note.id]?.noteView === editor, "Posted normal-window input saves a drawing without remounting the note editor")
        let saved = store.easelContext(for: tab)!.easel
        let priorBytes = try Data(contentsOf: store.sessionURL)
        check(priorBytes.range(of: Data("Saved sketchbook".utf8)) == nil, "The real normal-window session file hides its saved canvas title")
        try await capture(window, "normal-drawing-saved")

        tools.toolButtons[EaselCanvasTool.allCases.firstIndex(of: .pen)!].performClick(nil)
        try await mouse(.leftMouseDown, NSPoint(x: 400, y: 340), in: canvas.drawingOverlay, window: window)
        try await mouse(.leftMouseDragged, NSPoint(x: 570, y: 380), in: canvas.drawingOverlay, window: window)
        guard let pendingMark = canvas.drawing.preview else { throw CocoaError(.fileWriteUnknown) }
        let backup = root.appendingPathComponent("prior-ciphertext")
        try FileManager.default.moveItem(at: store.sessionURL, to: backup)
        try FileManager.default.createDirectory(at: store.sessionURL, withIntermediateDirectories: false)
        try await mouse(.leftMouseUp, NSPoint(x: 570, y: 380), in: canvas.drawingOverlay, window: window)
        let failedSave = await until { !store.savingEnabled && store.easelDrafts.failures(in: store).count == 1 }
        check(failedSave && store.easelContext(for: tab)?.easel == saved && store.easelDrafts.failures(in: store).first?.pendingDrawing == pendingMark,
              "A real native-input save failure keeps the previous board and complete pending mark")
        window.performClose(nil)
        check(window.isVisible && store.tab(tab) != nil, "The actual normal-window close action is canceled while a completed drawing cannot save")
        check(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel, "The application quit decision protects the same failed completed drawing")
        try await capture(window, "normal-drawing-save-failed")
        try FileManager.default.removeItem(at: store.sessionURL); try FileManager.default.moveItem(at: backup, to: store.sessionURL)

        func button(_ title: String) -> (any NSAccessibilityProtocol)? {
            var seen = Set<ObjectIdentifier>(), visited = 0
            func search(_ value: Any, depth: Int) -> (any NSAccessibilityProtocol)? {
                guard depth < 35, visited < 5000, let element = value as? any NSAccessibilityProtocol else { return nil }
                guard seen.insert(ObjectIdentifier(element as AnyObject)).inserted else { return nil }
                visited += 1
                if element.accessibilityRole() == .button && (element.accessibilityLabel() == title || element.accessibilityTitle() == title) { return element }
                for child in element.accessibilityChildren() ?? [] { if let found = search(child, depth: depth + 1) { return found } }
                return nil
            }
            return search(host, depth: 0)
        }
        func scrollRecoveryToBottom() {
            for scroll in all(host, NSScrollView.self) where !(scroll is EaselCanvasView) {
                guard let document = scroll.documentView, scroll.bounds.width > 450, scroll.bounds.height < 350 else { continue }
                let y = document.isFlipped ? max(document.bounds.minY, document.bounds.maxY - scroll.contentView.bounds.height) : document.bounds.minY
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        func clickRecovery(_ title: String) async throws -> Bool {
            scrollRecoveryToBottom(); try await Task.sleep(for: .milliseconds(150))
            guard let element = button(title), element.isAccessibilityEnabled() else {
                print("RESTORE_BUTTON_UNAVAILABLE", title); return false
            }
            let frame = element.accessibilityFrame()
            guard frame.width > 1, frame.height > 1, window.frame.contains(NSPoint(x: frame.midX, y: frame.midY)) else { return false }
            let point = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
                NSApplication.shared.postEvent(event, atStart: false); try await Task.sleep(for: .milliseconds(50))
            }
            return true
        }
        let clickedSaving = try await clickRecovery("Retry Saving")
        let unlocked = await until { store.savingEnabled && !store.unlocking }
        check(clickedSaving && unlocked && keyRequests == 1, "The visible Retry Saving button restores writes using the existing authorized key")
        try await capture(window, "normal-drawing-retry-ready")
        guard clickedSaving && unlocked else {
            print("Easel drawing restore window checks: \(checks) checked, \(failures) failed; saving retry did not complete")
            return 1
        }
        let clickedRetry = try await clickRecovery("Retry")
        let recovered = await until { store.easelDrafts.failures(in: store).isEmpty && store.easelContext(for: tab)?.easel.items.count == 3 }
        check(clickedRetry && recovered && store.easelContext(for: tab)?.easel.items.last == pendingMark, "The visible Retry button saves the same retained drawing exactly once")
        guard clickedRetry && recovered else {
            try await capture(window, "normal-drawing-retry-incomplete")
            print("Easel drawing restore window checks: \(checks) checked, \(failures) failed; drawing retry did not complete")
            return 1
        }
        check(canvas.cards[note.id]?.noteView === editor, "Native recovery preserves the original normal-window note editor")
        let restoredBoard = store.easelContext(for: tab)!.easel
        try await capture(window, "normal-drawing-recovered")
        delegate.windows.removeValue(forKey: window); window.delegate = nil; window.contentView = nil; window.close(); store.shutdown()

        let reopened = BrowserStore(dataRoot: root, keyProvider: { _ in keyRequests += 1; return key }); defer { reopened.shutdown() }
        reopened.onboardingVisible = false; reopened.preferences.automaticUpdateChecks = false
        check(reopened.easelContext(for: tab)?.easel == restoredBoard && keyRequests == 2, "A fresh normal browser store restores every saved mark from the actual encrypted session")
        let (secondWindow, secondHost) = makeWindow(reopened)
        defer { delegate.windows.removeValue(forKey: secondWindow); secondWindow.delegate = nil; secondWindow.contentView = nil; secondWindow.close() }
        let remounted = await until { all(secondHost, EaselCanvasView.self).first?.cards.count == 3 && secondWindow.isKeyWindow }
        check(remounted && all(secondHost, EaselCanvasView.self).first?.cards[note.id]?.noteView?.string == "Only this owned normal-window fixture.",
              "The reopened normal UI mounts its complete saved drawing and note content")
        try await capture(secondWindow, "normal-drawing-reopened")

        let privateRoot = root.appendingPathComponent("must-not-exist-private")
        var privateKeyRequests = 0
        let ephemeral = BrowserStore(isPrivate: true, dataRoot: privateRoot, keyProvider: { _ in privateKeyRequests += 1; return key })
        let privateTab = try ephemeral.createEasel(title: "Private drawing that must not restore")
        let privateBoard = ephemeral.easelContext(for: privateTab)!.easel
        _ = try ephemeral.editEasel(in: privateTab, expectedRevision: privateBoard.revision, edits: [.insert(pendingMark)])
        ephemeral.shutdown()
        let freshPrivate = BrowserStore(isPrivate: true, dataRoot: privateRoot, keyProvider: { _ in privateKeyRequests += 1; return key }); defer { freshPrivate.shutdown() }
        check(privateKeyRequests == 0 && freshPrivate.library.easels?.isEmpty != false && !FileManager.default.fileExists(atPath: privateRoot.path),
              "A fresh private session restores no private drawings, requests no key and creates no files")
        check(reopened.easelContext(for: tab)?.easel == restoredBoard, "Private retirement leaves the normal saved canvas unchanged")
        print("Easel drawing restore window checks: \(checks) checked, \(failures) failed")
        return failures == 0 ? 0 : 1
    }
    @MainActor static func main() {
        setbuf(stdout, nil); NSApplication.shared.setActivationPolicy(.regular)
        Task { @MainActor in
            do { exit(try await run()) }
            catch { print("FAIL: owned normal drawing restore: \(error)"); exit(1) }
        }
        NSApplication.shared.run()
    }
}
