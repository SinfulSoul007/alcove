import AppKit
import BrowserCore

@main struct EaselExportStoreChecks {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited); setbuf(stdout, nil)
        var checks = 0, failures = 0, fixtures: [OutputFixture] = []
        defer { fixtures.forEach { $0.close() } }
        func check(_ value: Bool, _ name: String) { checks += 1; print("\(value ? "PASS" : "FAIL"): \(name)"); if !value { failures += 1 } }
        func fixture() throws -> (OutputFixture, EaselCanvasView) {
            let f = try OutputFixture(); fixtures.append(f)
            let tab = try f.store.createEasel(title: "Export <ideas>")
            let note = try EaselItem(frame: EaselFrame(x: 50, y: 60, width: 300, height: 200), content: .note(text: "Keep 🌲 <script>window.bad=1</script>"))
            _ = try f.store.editEasel(in: tab, expectedRevision: f.store.easelContext(for: tab)!.easel.revision, edits: [.insert(note)])
            let canvas = EaselCanvasView(store: f.store, tabID: tab); canvas.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
            f.window.contentView = canvas; return (f, canvas)
        }
        func wait(_ ready: () -> Bool) async throws {
            for _ in 0..<1000 { if ready() { return }; try await Task.sleep(for: .milliseconds(10)) }
            throw OutputCheckError.expected
        }
        let (f, canvas) = try fixture(), boundary = OutputBoundaries(), output = PageOutputCoordinator(environment: boundary.environment)
        var choices: [(URL?) -> Void] = []
        let exports = EaselExportController(output: output, choose: { _, _, _, _, done in choices.append(done); return {} })
        check(exports.start(canvas: canvas, format: .png), "An owned native private canvas can begin an explicit image export")
        try await wait { choices.count == 1 }
        choices[0](nil)
        check(!exports.isBusy(in: f.window) && boundary.writes == 0 && !FileManager.default.fileExists(atPath: f.destination.path), "Canceling the native chooser writes no canvas data")
        check(exports.start(canvas: canvas, format: .html), "The same canvas can begin a portable HTML export after cancellation")
        try await wait { choices.count == 2 }
        let htmlURL = f.root.appendingPathComponent("Chosen.html"); choices[1](htmlURL); choices[1](f.root.appendingPathComponent("Duplicate.html"))
        let html = try String(contentsOf: htmlURL, encoding: .utf8)
        check(html.contains("Keep 🌲 &lt;script&gt;") && !FileManager.default.fileExists(atPath: f.root.appendingPathComponent("Duplicate.html").path), "Accepted private HTML contains escaped native notes and saves only once")
        check(f.keyCounter.reads == 0 && !FileManager.default.fileExists(atPath: f.store.sessionURL.path), "Explicit private export never opens a normal key or metadata file")
        let (dirty, dirtyCanvas) = try fixture(); var dirtyChoice: ((URL?) -> Void)?
        let dirtyExports = EaselExportController(output: output, choose: { _, _, _, _, done in dirtyChoice = done; return {} })
        _ = dirtyExports.start(canvas: dirtyCanvas, format: .html); try await wait { dirtyChoice != nil }
        let noteID = dirty.store.easelContext(for: dirtyCanvas.tabID)!.easel.items.first!.id
        try dirty.store.easelDrafts.update("New unsaved text", tabID: dirtyCanvas.tabID, itemID: noteID, from: dirty.store)
        dirtyChoice?(dirty.destination)
        check(!FileManager.default.fileExists(atPath: dirty.destination.path), "New note input invalidates a chooser even before its debounce save")
        let (cleared, clearedCanvas) = try fixture(); var clearChoice: ((URL?) -> Void)?
        let clearExports = EaselExportController(output: output, choose: { _, _, _, _, done in clearChoice = done; return {} })
        _ = clearExports.start(canvas: clearedCanvas, format: .html); try await wait { clearChoice != nil }
        cleared.store.invalidateEaselImages(for: BrowserProfile.defaultID); clearChoice?(cleared.destination)
        check(!FileManager.default.fileExists(atPath: cleared.destination.path), "A profile operation invalidates an earlier canvas export chooser")
        let (retired, retiredCanvas) = try fixture(); var retiredChoice: ((URL?) -> Void)?
        let retiredExports = EaselExportController(output: output, choose: { _, _, _, _, done in retiredChoice = done; return {} })
        _ = retiredExports.start(canvas: retiredCanvas, format: .html); try await wait { retiredChoice != nil }
        retired.window.contentView = nil; retiredChoice?(retired.destination)
        check(!FileManager.default.fileExists(atPath: retired.destination.path), "Retiring the exact native canvas prevents stale output publication")
        let (accepted, acceptedCanvas) = try fixture(), deferred = OutputBoundaries(); deferred.deferWrite = true
        let draining = PageOutputCoordinator(environment: deferred.environment); var acceptedChoice: ((URL?) -> Void)?
        let acceptedExports = EaselExportController(output: draining, choose: { _, _, _, _, done in acceptedChoice = done; return {} })
        _ = acceptedExports.start(canvas: acceptedCanvas, format: .html); try await wait { acceptedChoice != nil }
        acceptedChoice?(accepted.destination)
        check(draining.pendingWriteCount == 1 && !FileManager.default.fileExists(atPath: accepted.destination.path), "An approved canvas export enters the browser's shared pending-output drain")
        accepted.window.contentView = nil; accepted.window.close(); accepted.store.shutdown()
        deferred.pendingWrite?()
        check(try String(contentsOf: accepted.destination, encoding: .utf8).contains("Keep 🌲") && draining.pendingWriteCount == 0, "An accepted immutable export finishes after its private window closes")
        let (menuFixture, menuCanvas) = try fixture(); var menuChoice: ((URL?) -> Void)?
        let menuExports = EaselExportController(output: output, choose: { _, _, _, _, done in menuChoice = done; return {} })
        let delegate = AppDelegate(pageOutput: output); delegate.windows[menuFixture.window] = menuFixture.store; delegate.easelExports = menuExports
        defer { delegate.windows.removeAll() }
        delegate.performEaselExport(.html, in: menuFixture.window)
        try await wait { menuChoice != nil }; let menuURL = menuFixture.root.appendingPathComponent("Menu.html"); menuChoice?(menuURL)
        check(try String(contentsOf: menuURL, encoding: .utf8).contains("Keep 🌲"), "Native browser export routing reaches its exact owned canvas and shared writer")
        menuChoice = nil
        menuFixture.store.easelExportRequested = { format in delegate.performEaselExport(format, in: menuFixture.window) }
        menuFixture.store.commandVisible = true; menuFixture.store.runCommand(.exportEaselHTML)
        try await wait { menuChoice != nil }; let commandURL = menuFixture.root.appendingPathComponent("Command.html"); menuChoice?(commandURL)
        check(try !menuFixture.store.commandVisible && String(contentsOf: commandURL, encoding: .utf8).contains("Keep 🌲"), "Command search dismisses its chrome before exporting the focused native canvas")
        let webTab = menuFixture.store.session.spaces.flatMap(\.tabs).first(where: { EaselRoute.parse($0.url) == nil })!.id
        menuFixture.store.select(webTab)
        check(!menuFixture.store.availableCommands.contains(.exportEaselHTML) && !menuFixture.store.availableCommands.contains(.exportEaselPNG), "A website does not expose export commands for an old hidden native canvas")
        _ = menuCanvas
        print("Easel export store checks: \(checks) checked, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
