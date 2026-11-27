import AppKit
import BrowserCore

@main struct EaselReviewPresentationChecks {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited); setbuf(stdout, nil)
        var checks = 0, failures = 0, fixtures: [OutputFixture] = []
        defer { fixtures.forEach { $0.close() } }
        func check(_ value: Bool, _ name: String) { checks += 1; print("\(value ? "PASS" : "FAIL"): \(name)"); if !value { failures += 1 } }
        func fixture() throws -> OutputFixture { let f = try OutputFixture(); fixtures.append(f); return f }
        func wait(_ ready: () -> Bool) async throws {
            for _ in 0..<200 { if ready() { return }; try await Task.sleep(for: .milliseconds(10)) }
            throw OutputCheckError.expected
        }
        let f = try fixture(), tab = try f.store.createEasel()
        let canvas = EaselCanvasView(store: f.store, tabID: tab); f.window.contentView = canvas
        let boundary = OutputBoundaries(), output = PageOutputCoordinator(environment: boundary.environment)
        var choices: [(URL?) -> Void] = []
        let exports = EaselExportController(output: output, choose: { _, _, _, _, done in choices.append(done); return {} })
        _ = exports.start(canvas: canvas, format: .html)
        f.window.fixtureSheet = NSWindow()
        try await Task.sleep(for: .milliseconds(200))
        check(choices.isEmpty && exports.isBusy(in: f.window), "An asynchronously prepared export waits while another native sheet is attached")
        f.window.fixtureSheet = nil; NotificationCenter.default.post(name: NSWindow.didEndSheetNotification, object: f.window)
        try await wait { choices.count == 1 }; choices[0](nil)
        _ = exports.start(canvas: canvas, format: .html); f.window.fixtureKey = false
        try await Task.sleep(for: .milliseconds(200))
        check(choices.count == 1 && exports.isBusy(in: f.window), "A prepared export waits while its source window is in the background")
        f.window.fixtureKey = true; NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: f.window)
        try await wait { choices.count == 2 }
        _ = try f.store.editEasel(in: tab, expectedRevision: f.store.easelContext(for: tab)!.easel.revision, edits: [.rename("Changed after chooser")])
        f.store.message = nil; choices[1](f.destination)
        check(!FileManager.default.fileExists(atPath: f.destination.path) && f.store.message?.lowercased().contains("cancel") == true, "Accepting a stale canvas chooser writes no file and explains that saving was canceled")
        let beforeSibling = f.store.space.id, board = f.store.easelContext(for: tab)!.easel
        let note = try EaselItem(frame: EaselFrame(x: 50, y: 50, width: 300, height: 200), content: .note(text: "Saved sibling"))
        _ = try f.store.editEasel(in: tab, expectedRevision: board.revision, edits: [.insert(note)])
        let space = try f.store.createSpace(name: "Sibling editor", profileID: BrowserProfile.defaultID), sibling = try f.store.openEasel(board.id, in: space)
        f.store.selectSpace(beforeSibling); f.store.select(tab)
        _ = exports.start(canvas: canvas, format: .html); try await wait { choices.count == 3 }
        try f.store.easelDrafts.update("Fresh sibling input", tabID: sibling, itemID: note.id, from: f.store)
        choices[2](f.destination)
        check(!FileManager.default.fileExists(atPath: f.destination.path), "Fresh input in a sibling tab invalidates an accepted export before its debounce save")
        let page = try fixture()
        var snapshot: ((Result<EaselRaster, Error>) -> Void)?, previews: [(EaselCaptureChoice?) throws -> Void] = []
        let capture = EaselCaptureCoordinator(environment: EaselCaptureEnvironment(snapshot: { _, done in snapshot = done }, preview: { _, _, _, done in previews.append(done); return {} }))
        let raster = try EaselRaster(data: Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgYPgPAAEDAQAIicLsAAAAAElFTkSuQmCC")!)
        capture.capture(web: page.web, store: page.store, window: page.window)
        page.window.fixtureSheet = NSWindow(); snapshot?(.success(raster))
        check(previews.isEmpty && capture.isBusy(in: page.window), "A delayed page snapshot waits for another native sheet before presenting its preview")
        page.window.fixtureSheet = nil; NotificationCenter.default.post(name: NSWindow.didEndSheetNotification, object: page.window)
        try await wait { previews.count == 1 }; try previews[0](nil)
        capture.capture(web: page.web, store: page.store, window: page.window)
        page.window.fixtureKey = false; snapshot?(.success(raster))
        check(previews.count == 1 && capture.isBusy(in: page.window), "A delayed capture preview waits for its source window to become key")
        page.window.fixtureKey = true; NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: page.window)
        try await wait { previews.count == 2 }; try previews[1](nil)
        print("Easel presentation review checks: \(checks) checked, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
