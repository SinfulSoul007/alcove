import AppKit
import WebKit
import CryptoKit
import BrowserCore

@main struct EaselTabChecks {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        setbuf(stdout, nil)
        var checks = 0, failures = 0
        func check(_ value: Bool, _ name: String) {
            checks += 1; print("\(value ? "PASS" : "FAIL"): \(name)")
            if !value { failures += 1 }
        }
        func rejects(_ name: String, _ body: () throws -> Void) {
            do { try body(); check(false, name) } catch { check(true, name) }
        }
        let files = FileManager.default
        let area = files.temporaryDirectory.appendingPathComponent("Alcove.EaselTabs." + UUID().uuidString)
        defer { try? files.removeItem(at: area) }
        let key = SymmetricKey(size: .bits256)
        var keyRequests = 0
        let store = BrowserStore(dataRoot: area.appendingPathComponent("normal"), keyProvider: { _ in keyRequests += 1; return key })
        defer { store.shutdown() }
        let originalSpace = store.space.id
        let tabID = try store.createEasel(title: "  Research  ")
        let first = store.easelContext(for: tabID)!
        let boardID = first.easel.id
        check(first.profileID == BrowserProfile.defaultID && first.easel.title == "Research" && store.selectedID == tabID, "Creating a canvas atomically selects its tab in the captured profile")
        check(store.tab(tabID)?.pinned == true && store.tab(tabID)?.homeURL == EaselRoute(id: boardID).url.absoluteString, "New canvas tabs live in Pinned with a durable native destination")
        check(store.views[tabID] == nil && store.primaryPageView(for: tabID) == nil, "A canvas tab never registers or supplies a WebKit page")
        let supplied = WKWebViewConfiguration()
        supplied.websiteDataStore = .nonPersistent()
        supplied.userContentController.addUserScript(WKUserScript(source: "window.ownedEaselInjection = true", injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let blank = store.view(for: tabID, configuration: supplied)
        check(blank.navigationDelegate == nil && blank.uiDelegate == nil && !blank.configuration.websiteDataStore.isPersistent && blank.configuration.userContentController.userScripts.isEmpty && store.views[tabID] == nil && store.viewProfileIDs[tabID] == nil, "A defensive WebKit factory call returns an unregistered private blank without the supplied bridge")
        store.registerView(blank, for: tabID, profile: BrowserProfile.defaultID)
        check(store.views[tabID] == nil && store.viewProfileIDs[tabID] == nil, "Direct registration cannot turn a native canvas into an extension or website target")
        let initialCiphertext = try Data(contentsOf: store.sessionURL)
        check(initialCiphertext.range(of: Data("Research".utf8)) == nil, "Saved canvas metadata is not plaintext")
        let same = try store.openEasel(boardID, in: originalSpace)
        check(same == tabID && store.session.spaces.flatMap(\.tabs).filter { EaselRoute.parse($0.url)?.id == boardID }.count == 1, "Reopening a canvas in its Space reuses the same pinned tab")
        let anotherSpace = try store.createSpace(name: "Other Space", profileID: BrowserProfile.defaultID)
        let secondTab = try store.openEasel(boardID, in: anotherSpace)
        store.update(secondTab) { $0.customTitle = "My research" }
        check(secondTab != tabID && store.easelContext(for: secondTab)?.easel == first.easel, "Another Space can present the same saved canvas without copying its content")
        let frame = try EaselFrame(x: 100, y: 100, width: 320, height: 200)
        let note = try EaselItem(frame: frame, content: .note(text: "Owned note"))
        let inserted = try store.editEasel(in: tabID, expectedRevision: first.easel.revision, edits: [.insert(note), .rename("Research updated")])
        check(inserted.items == [note] && inserted.title == "Research updated" && store.space.id == anotherSpace, "A multi-edit transaction updates one canvas without changing the active Space")
        check(store.tab(tabID)?.title == "Research updated" && store.tab(secondTab)?.pinnedTitle == "Research updated" && store.tab(secondTab)?.sidebarTitle == "My research", "Canvas renaming refreshes native titles while preserving a custom tab label")
        let beforeInvalid = try Data(contentsOf: store.sessionURL)
        let missing = try EaselItem(frame: frame, content: .note(text: "Not inserted"))
        rejects("An invalid later edit cannot publish an earlier rename") { _ = try store.editEasel(in: tabID, expectedRevision: inserted.revision, edits: [.rename("Must roll back"), .replace(missing)]) }
        let afterInvalid = try Data(contentsOf: store.sessionURL)
        check(store.easelContext(for: tabID)?.easel == inserted && afterInvalid == beforeInvalid, "An invalid edit batch preserves both live canvas and exact ciphertext")
        rejects("A stale editor cannot replace newer canvas content") { _ = try store.editEasel(in: tabID, expectedRevision: first.easel.revision, edits: [.remove([note.id])]) }
        _ = try store.editEasel(in: tabID, expectedRevision: inserted.revision, edits: [.rename("Research updated"), .reorder([note.id])])
        check(try Data(contentsOf: store.sessionURL) == beforeInvalid, "No-op canvas edits do not rewrite encrypted metadata")

        let otherProfile = try store.createProfile(name: "Other account")
        let foreignSpace = store.space.id
        let foreignBefore = store.session.spaces.flatMap(\.tabs).count
        rejects("Another profile cannot open a canvas by knowing its UUID") { _ = try store.openEasel(boardID) }
        check(store.session.spaces.flatMap(\.tabs).count == foreignBefore && store.library.easels == nil, "A rejected foreign canvas does not create a phantom tab or library record")
        let foreignCanvas = try Easel(id: boardID, title: "Foreign canvas")
        var document = store.makeDocument(); var foreignLibrary = document.library(for: otherProfile)
        foreignLibrary.easels = [foreignCanvas]; document.setLibrary(foreignLibrary, for: otherProfile)
        try store.commitProfileDocument(document)
        let foreignTab = try store.openEasel(boardID, in: foreignSpace)
        check(store.easelContext(for: foreignTab)?.easel.title == "Foreign canvas" && store.easelContext(for: tabID)?.easel.title == "Research updated", "Matching UUIDs in different profiles resolve only through each tab's actual owning library")
        let updated = try store.editEasel(in: tabID, expectedRevision: inserted.revision, edits: [.rename("Source profile only")])
        check(store.tab(foreignTab)?.title == "Foreign canvas" && store.easelContext(for: foreignTab)?.easel == foreignCanvas && store.space.id == foreignSpace, "A background canvas edit cannot rename or select another profile's canvas")
        let profileIndex = store.profiles.firstIndex { $0.id == BrowserProfile.defaultID }!
        store.profiles[profileIndex].pendingDataClear = true
        rejects("An unavailable profile rejects canvas creation") { _ = try store.createEasel(in: originalSpace) }
        rejects("An unavailable profile rejects canvas opening") { _ = try store.openEasel(boardID, in: originalSpace) }
        rejects("An unavailable profile rejects deferred canvas edits") { _ = try store.editEasel(in: tabID, expectedRevision: updated.revision, edits: [.rename("Late edit")]) }
        check(store.easelContext(for: tabID) == nil && store.primaryPageView(for: tabID) == nil, "An unavailable canvas profile supplies neither native content nor a website")
        store.profiles[profileIndex].pendingDataClear = false
        check(keyRequests == 1, "Canvas operations reuse the already unlocked metadata key")

        let normalBefore = store.library(for: BrowserProfile.defaultID).easels!
        let beforeFailure = try Data(contentsOf: store.sessionURL)
        let backup = area.appendingPathComponent("prior-ciphertext")
        try files.moveItem(at: store.sessionURL, to: backup)
        try files.createDirectory(at: store.sessionURL, withIntermediateDirectories: false)
        rejects("A failed canvas save is reported") { _ = try store.editEasel(in: tabID, expectedRevision: updated.revision, edits: [.rename("Unsaved canvas")]) }
        let priorCiphertext = try Data(contentsOf: backup)
        check(store.library(for: BrowserProfile.defaultID).easels == normalBefore && priorCiphertext == beforeFailure, "Failed persistence leaves the old catalog and previous ciphertext intact")
        try files.removeItem(at: store.sessionURL); try files.moveItem(at: backup, to: store.sessionURL)
        store.shutdown()
        let restored = BrowserStore(dataRoot: area.appendingPathComponent("normal"), keyProvider: { _ in key })
        check(restored.easelContext(for: tabID)?.easel == updated && restored.tab(tabID)?.pinned == true, "Encrypted relaunch restores the native destination, board and last committed revision")
        restored.shutdown()

        var privateKeys = 0
        let privateRoot = area.appendingPathComponent("must-not-exist")
        let privateStore = BrowserStore(isPrivate: true, dataRoot: privateRoot, keyProvider: { _ in privateKeys += 1; return key })
        let privateTab = try privateStore.createEasel(title: "Private canvas")
        let privateBoard = privateStore.easelContext(for: privateTab)!.easel
        _ = try privateStore.editEasel(in: privateTab, expectedRevision: privateBoard.revision, edits: [.insert(note)])
        check(privateStore.easelContext(for: privateTab)?.easel.items == [note] && privateStore.views[privateTab] == nil, "Private canvases are editable native content without a WebKit registration")
        privateStore.shutdown()
        check(privateKeys == 0 && !files.fileExists(atPath: privateRoot.path), "Private canvas creation/edit/shutdown requests no key and creates no files")
        rejects("A closed private store rejects a late canvas action") { _ = try privateStore.createEasel() }
        let grouped = BrowserStore(dataRoot: area.appendingPathComponent("grouped"), keyProvider: { _ in key })
        let owner = BrowserWindowOwner(store: grouped)
        let firstWindow = try owner.acquirePrimaryStore()
        let groupedTab = try grouped.createEasel(title: "Window canvas")
        let groupedBoard = grouped.easelContext(for: groupedTab)!.easel
        let secondWindow = try owner.acquirePrimaryStore(copying: grouped)
        check(secondWindow.store.easelContext(for: groupedTab)?.easel == groupedBoard && grouped.easelContext(for: groupedTab) == nil, "Native canvas presentation follows the actual window ownership")
        rejects("A former presenter cannot submit a late canvas edit") { _ = try grouped.editEasel(in: groupedTab, expectedRevision: groupedBoard.revision, edits: [.rename("Wrong window")]) }
        _ = try secondWindow.store.editEasel(in: groupedTab, expectedRevision: groupedBoard.revision, edits: [.rename("Current presenter")])
        check(grouped.library.easels?.first?.title == "Current presenter", "The current window commits through the shared metadata writer")
        owner.release(secondWindow.lease); owner.release(firstWindow.lease)
        print("Easel tab checks: \(checks) checked, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
