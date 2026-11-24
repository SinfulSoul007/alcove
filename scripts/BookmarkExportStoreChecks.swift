import AppKit
import CryptoKit
import BrowserCore

@main struct BookmarkExportStoreChecks {
    @MainActor static func main() {
        setbuf(stdout, nil); NSApplication.shared.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { exit(try await run()) } catch { print("FAIL: \(error)"); exit(1) }
        }
        NSApp.run()
    }
    @MainActor static func run() async throws -> Int32 {
        var failures = 0, checks = 0
        func check(_ result: Bool, _ name: String) {
            checks += 1; print("\(result ? "PASS" : "FAIL"): \(name)"); if !result { failures += 1 }
        }
        func wait(_ predicate: () -> Bool) async -> Bool {
            for _ in 0..<200 { if predicate() { return true }; try? await Task.sleep(for: .milliseconds(10)) }
            return predicate()
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Alcove.BookmarkExport.\(UUID())")
        let key = SymmetricKey(size: .bits256)
        let store = BrowserStore(dataRoot: root.appendingPathComponent("metadata"), keyProvider: { _ in key })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); store.shutdown(); try? FileManager.default.removeItem(at: root) }
        store.onboardingVisible = false
        let defaultSpace = store.space.id
        let work = try store.createProfile(name: "Export work")
        var pin = BrowserCore.Tab(title: "Work saved", url: "https://work.example/current", pinned: true)
        pin.homeURL = "https://work.example/saved"
        store.session.spaces[store.spaceIndex].tabs = [pin, BrowserCore.Tab(title: "Work Today", url: "https://work.example/today")]
        store.mutateLibrary(for: work) { $0.bookmarks = [PageRecord(title: "Work bookmark", url: "https://work.example/bookmark")]; $0.history = [PageRecord(title: "No history", url: "https://work.example/history")] }
        store.mutateLibrary(for: BrowserProfile.defaultID) { $0.bookmarks = [PageRecord(title: "Personal only", url: "https://personal.example/bookmark")] }
        let source = try store.bookmarkExportSource(profileID: work)
        store.selectSpace(defaultSpace)
        let sourceText = String(decoding: try source.render().data, as: UTF8.self)
        check(sourceText.contains("https://work.example/saved") && sourceText.contains("https://work.example/bookmark"), "Captured profile export retains its saved pages after another profile is selected")
        check(!sourceText.contains("personal.example") && !sourceText.contains("/history") && !sourceText.contains("/today") && !sourceText.contains("/current"), "Export omits the other profile, history, Today and live navigation addresses")
        store.savingEnabled = false
        check(!store.canExportBookmarkHTML && (try? store.bookmarkExportSource(profileID: work)) == nil, "Locked metadata rejects a stale export request")
        store.savingEnabled = true
        let workIndex = store.profiles.firstIndex { $0.id == work }!
        store.profiles[workIndex].pendingDataClear = true
        check((try? store.bookmarkExportSource(profileID: work)) == nil, "A captured profile pending erasure cannot export")
        store.profiles[workIndex].pendingDataClear = false
        check((try? store.bookmarkExportSource(profileID: UUID())) == nil, "A removed or unknown profile cannot export")
        let privateStore = BrowserStore(isPrivate: true)
        check(!privateStore.canExportBookmarkHTML && (try? privateStore.bookmarkExportSource(profileID: BrowserProfile.defaultID)) == nil, "Private windows cannot export normal saved collections")
        privateStore.shutdown()

        let boundary = OutputBoundaries(); boundary.deferWrite = true
        let output = PageOutputCoordinator(environment: boundary.environment)
        var choices: [(String, BookmarkHTMLExport, (URL?) -> Void)] = []
        var cancelled = 0, owned = true
        let exports = BookmarkExportController(output: output, choose: { _, profile, result, done in
            choices.append((profile, result, done)); return { cancelled += 1 }
        })
        check(exports.start(store: store, window: window, stillOwned: { owned }), "A normal profile can start one native export preparation")
        check(!exports.start(store: store, window: window, stillOwned: { owned }), "Repeated export commands cannot open overlapping dialogs")
        let choiceReady = await wait { choices.count == 1 }
        check(choiceReady && choices.first?.0 == "Default", "The save boundary is tied to the originating profile")
        guard choiceReady else { return 1 }
        let cancelledChoice = choices[0].2
        cancelledChoice(nil); cancelledChoice(root.appendingPathComponent("cancelled.html"))
        check(boundary.writes == 0 && output.pendingOutputCount == 0, "Cancelling the save dialog rejects a retained duplicate acceptance")
        check(exports.start(store: store, window: window, stillOwned: { owned }), "Cancellation releases the window for another export")
        check(await wait { choices.count == 2 }, "The second prepared export reaches its save boundary")
        store.savingEnabled = false
        choices[1].2(root.appendingPathComponent("locked.html")); store.savingEnabled = true
        check(boundary.writes == 0, "A retained save callback cannot export metadata after it locks")
        check(exports.start(store: store, window: window, stillOwned: { owned }), "Recovered metadata can prepare an export")
        check(await wait { choices.count == 3 }, "The recovered export reaches its save boundary")
        owned = false; choices[2].2(root.appendingPathComponent("replaced.html")); owned = true
        check(boundary.writes == 0, "A replaced source window cannot accept an old export")

        check(exports.start(store: store, window: window, stillOwned: { owned }), "A current source can prepare the accepted export")
        check(await wait { choices.count == 4 }, "The accepted export reaches its save boundary")
        let destination = root.appendingPathComponent("saved.html")
        store.selectSpace(store.session.spaces.first { $0.effectiveProfileID == work }!.id)
        choices[3].2(destination); choices[3].2(destination)
        check(boundary.writes == 1 && output.pendingWriteCount == 1 && output.pendingOutputCount == 1, "Explicit acceptance starts exactly one tracked immutable write")
        var drained: Bool?
        output.waitForPendingOutput { drained = $0 }
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        boundary.pendingWrites.removeFirst()()
        let saved = try BookmarkHTMLImport.read(from: destination)
        check(saved.bookmarks.map(\.url) == ["https://personal.example/bookmark"] && drained == true && output.pendingOutputCount == 0, "Accepted bytes survive source-window close and complete the waiting output drain")
        boundary.writeCompletions[0](.failure(CocoaError(.fileWriteUnknown)))
        check(boundary.orphanedErrors.isEmpty && output.pendingOutputCount == 0, "A duplicate writer completion cannot report a false late failure")

        let failedURL = root.appendingPathComponent("uncreated/fail.html")
        let accepted = output.writeAcceptedFile(Data("immutable".utf8), to: failedURL, failureMessage: "Could not export bookmarks. Check the destination and try again.")
        var failureDrain: Bool?
        output.waitForPendingOutput { failureDrain = $0 }
        check(accepted && output.pendingOutputCount == 1, "Generic accepted output participates in the existing Quit wait")
        boundary.pendingWrites.removeFirst()()
        check(failureDrain == false && boundary.orphanedErrors == ["Could not export bookmarks. Check the destination and try again."], "A failed export cancels a waiting Quit with a generic error")
        check(!output.writeAcceptedFile(Data("x".utf8), to: URL(string: "https://example.com/remote")!, failureMessage: "Failure"), "No accepted export can write to a non-file destination")
        check(!output.writeAcceptedFile(Data(), to: root.appendingPathComponent("empty.html"), failureMessage: "Failure"), "An empty capture cannot produce an accepted output job")
        check(exports.start(store: store, window: window, stillOwned: { owned }), "A final preparation starts for close cancellation")
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        _ = await wait { !exports.isBusy(in: window) }
        check(!exports.isBusy(in: window) && boundary.writes == 2, "Closing during preparation cancels it before any file is accepted")
        store.selectSpace(defaultSpace)
        let choosingIndex = choices.count
        check(exports.start(store: store, window: window, stillOwned: { owned }), "A save-dialog close witness begins")
        check(await wait { choices.count > choosingIndex }, "The close witness reaches its native dialog boundary")
        let priorCancellations = cancelled
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        choices[choosingIndex].2(root.appendingPathComponent("closed.html"))
        check(cancelled == priorCancellations + 1 && boundary.writes == 2, "Closing an open save dialog dismisses it and rejects its retained acceptance")
        let erasureIndex = choices.count
        check(exports.start(store: store, window: window, stillOwned: { owned }), "A source-removal witness begins")
        check(await wait { choices.count > erasureIndex }, "The source-removal witness reaches its save boundary")
        store.mutateLibrary(for: BrowserProfile.defaultID) { $0.bookmarks.removeAll() }
        choices[erasureIndex].2(root.appendingPathComponent("removed.html"))
        check(boundary.writes == 2, "Removing source saved pages revokes an unaccepted export instead of saving deleted records")
        print("Bookmark export store/output checks: \(checks), \(failures) failures; panel cancellations \(cancelled)")
        return failures == 0 ? 0 : 1
    }
}
