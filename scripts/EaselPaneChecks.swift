import AppKit
import SwiftUI
import BrowserCore
import CryptoKit

@main struct EaselPaneChecks {
    @MainActor static func run() async throws -> Int32 {
        var checks = 0, failures = 0
        func check(_ value: Bool, _ name: String) {
            checks += 1; print("\(value ? "PASS" : "FAIL"): \(name)")
            if !value { failures += 1 }
        }
        func until(_ predicate: () -> Bool) async -> Bool {
            for _ in 0..<250 { if predicate() { return true }; try? await Task.sleep(for: .milliseconds(20)) }
            return predicate()
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Alcove.EaselPane." + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BrowserStore(dataRoot: root, keyProvider: { _ in SymmetricKey(data: Data(repeating: 23, count: 32)) })
        let owner = BrowserWindowOwner(store: store), lease = try owner.acquirePrimaryStore().lease
        defer { owner.release(lease) }
        store.onboardingVisible = false
        store.preferences.automaticUpdateChecks = false
        let tab = try store.createEasel(title: "Actual browser pane")
        let board = store.easelContext(for: tab)!.easel
        let note = try EaselItem(frame: EaselFrame(x: 70, y: 70, width: 320, height: 230), content: .note(text: "Pane note"))
        _ = try store.editEasel(in: tab, expectedRevision: board.revision, edits: [.insert(note)])
        let suite = "Alcove.EaselPaneChecks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!; defaults.set(240.0, forKey: "sidebarWidth")
        defer { defaults.removePersistentDomain(forName: suite) }
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1100, height: 760), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: BrowserUI(store: store, sidebarDefaults: defaults).environmentObject(UpdateController(installedTag: "easel-pane-fixture")))
        host.sizingOptions = []; host.safeAreaRegions = []; window.contentView = host
        defer { window.contentView = nil; window.close() }
        window.orderFront(nil)
        func canvases(_ view: NSView) -> [EaselCanvasView] {
            if let canvas = view as? EaselCanvasView { return [canvas] }
            return view.subviews.flatMap { canvases($0) }
        }
        let mounted = await until { canvases(host).first.map { $0.bounds.width > 100 && $0.bounds.height > 100 } ?? false }
        check(mounted, "The actual browser mounts a native canvas with a usable viewport")
        guard let canvas = canvases(host).first, let text = canvas.cards[note.id]?.noteView else { return 1 }
        check(canvas.bounds.width < host.bounds.width && canvas.bounds.height <= host.bounds.height && store.views[tab] == nil, "The canvas fits inside browser chrome without creating a WebKit page")
        window.makeFirstResponder(text)
        text.insertText(" across redraw", replacementRange: NSRange(location: (text.string as NSString).length, length: 0))
        let saved = await until { store.easelContext(for: tab)?.easel.items.first?.content == .note(text: "Pane note across redraw") }
        check(saved && canvases(host).first === canvas && canvas.cards[note.id]?.noteView === text && window.firstResponder === text, "Actual SwiftUI autosave redraw preserves native note focus and identity")
        store.windowSidebarWidth = 300
        window.setContentSize(NSSize(width: 740, height: 520))
        let resized = await until { host.bounds.width < 800 && canvas.bounds.width > 100 && canvas.bounds.width < 500 && canvas.bounds.height <= host.bounds.height }
        check(resized && canvas.cards[note.id]?.noteView === text, "Window and sidebar resizing keep the canvas bounded and its editor stable")
        let secondTab = try store.createEasel(title: "Second pane")
        let split = store.openInSplit(tab, at: .left)
        let splitMounted = await until { Set(canvases(host).map(\.tabID)) == Set([tab, secondTab]) }
        check(split && splitMounted && store.views[tab] == nil && store.views[secondTab] == nil, "Two Easels render as distinct native split panes without WebKit registration")
        check(canvases(host).allSatisfy { $0.bounds.width > 50 && $0.bounds.width <= host.bounds.width && $0.bounds.height <= host.bounds.height }, "Narrow split panes preserve usable bounded native viewports")
        store.separateSplit(); store.select(tab)
        let returned = await until { canvases(host).count == 1 && canvases(host).first?.tabID == tab }
        check(returned && store.easelContext(for: tab)?.easel.items.first?.content == .note(text: "Pane note across redraw"), "Leaving Split View restores the complete saved canvas")
        store.setTheme(.ocean)
        let themed = await until { canvases(host).first?.appearance?.name == .darkAqua }
        check(themed && canvases(host).first?.cards[note.id]?.noteView?.string == "Pane note across redraw", "The actual canvas follows a dark Space theme without losing its note")
        print("Easel pane checks: \(checks) checked, \(failures) failed")
        return failures == 0 ? 0 : 1
    }
    @MainActor static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { exit(try await run()) }
            catch { print("FAIL: Easel pane fixture: \(error.localizedDescription)"); exit(1) }
        }
        app.run()
    }
}
