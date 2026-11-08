import AppKit
import CryptoKit
import WebKit
import BrowserCore

/// Native controller lifecycle checks. Windows stay hidden; this is not visual/keyboard QA.
@main struct QuickBrowseNativeChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        var failures = 0
        func check(_ value: Bool, _ name: String) { print("\(value ? "PASS" : "FAIL"): \(name)"); if !value { failures += 1 } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256)
        let store = BrowserStore(dataRoot: root, keyProvider: { _ in key })
        let owner = BrowserWindowOwner(store: store)
        let id = try store.openQuickPage()
        var closed = 0
        let controller = try QuickBrowseWindowController(owner: owner, pageID: id, requestPrimary: {}, requestProfiles: {}, didClose: { closed += 1 })
        let window = controller.window!
        store.quickPagesDidChange = { [weak controller] in if store.quickPage(id) == nil { controller?.modelDidRemovePage() } }
        check(window.minSize == NSSize(width: 480, height: 360) && window.styleMask.contains(.resizable), "The real compact controller creates a resizable window with its specified minimum size")
        if let screen = NSScreen.main {
            check(screen.visibleFrame.contains(window.frame), "The compact window's initial frame fits within the available display")
        }
        let oldBytes = try Data(contentsOf: store.sessionURL)
        store.vault = MetadataStore(url: root, key: key)
        check(!controller.windowShouldClose(window), "The native close delegate refuses to close when archiving cannot be saved")
        check(store.quickPage(id) != nil && owner.leaseCount == 1 && !owner.isClosed && window.contentView != nil && closed == 0, "A failed native close preserves the quick record, hosting view and data-writer lease")
        check(try Data(contentsOf: store.sessionURL) == oldBytes, "A failed native close leaves the prior encrypted session intact")
        store.unlockLocalData(keyProvider: { key })
        for _ in 0..<500 where store.unlocking { try await Task.sleep(for: .milliseconds(10)) }
        check(store.savingEnabled && store.quickPage(id) != nil, "Unlock makes the preserved native quick window retryable")
        let canClose = controller.windowShouldClose(window)
        check(canClose && store.quickPage(id) == nil && !owner.isClosed, "A successful close commits first without reentrantly releasing the native window")
        window.close()
        check(owner.isClosed && store.isShuttingDown && closed == 1 && window.contentView == nil, "The actual native close notification tears down hosting before releasing its final owner lease")
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
        check(closed == 1, "Repeated native close notifications are harmless")
        store.quickPagesDidChange = nil

        let handoff = BrowserStore(dataRoot: root.appendingPathComponent("handoff"), keyProvider: { _ in key })
        let handoffOwner = BrowserWindowOwner(store: handoff)
        let handoffID = try handoff.openQuickPage()
        var destinationLease: UUID?
        var handoffClosed = 0
        let compact = try QuickBrowseWindowController(owner: handoffOwner, pageID: handoffID,
            requestPrimary: { destinationLease = try? handoffOwner.acquirePrimary() }, requestProfiles: {}, didClose: { handoffClosed += 1 })
        handoff.quickPagesDidChange = { [weak compact] in if handoff.quickPage(handoffID) == nil { compact?.modelDidRemovePage() } }
        compact.promote()
        check(destinationLease != nil && !handoffOwner.isClosed && handoffOwner.leaseCount == 1 && handoffClosed == 1 && handoff.selectedID == handoffID, "The real promotion controller acquires its destination before the backend removes and closes the compact window")
        check(handoff.library.archive.isEmpty, "Closing the promoted native window cannot archive the page a second time")
        handoff.quickPagesDidChange = nil
        if let destinationLease { handoffOwner.release(destinationLease) }

        let retained = BrowserStore(dataRoot: root.appendingPathComponent("primary-close"), keyProvider: { _ in key })
        let delegate = AppDelegate()
        let retainedQuick = try retained.openQuickPage()
        let retainedOwner = delegate.makeOwner(retained); delegate.normalOwner = retainedOwner
        let primaryLease = try retainedOwner.acquirePrimary(); let retainedQuickLease = try retainedOwner.acquireQuick(retainedQuick)
        let primaryID = retained.selectedID!
        let primaryPage = retained.view(for: primaryID)
        let quickPage = retained.view(for: retainedQuick)
        let retainedCompact = try QuickBrowseWindowController(owner: retainedOwner, pageID: retainedQuick, requestPrimary: {}, requestProfiles: {}, didClose: {})
        retained.openPeek(URL(string: "about:blank")!, from: quickPage)
        let retainedQuickPeek = retained.quickPeekView(retainedQuick)!
        for _ in 0..<500 where retainedQuickPeek.url == nil { try await Task.sleep(for: .milliseconds(10)) }
        retainedCompact.requestLocation()
        check(retainedCompact.activeWebView === retainedQuickPeek && retainedCompact.state.isEditingAddress && retainedCompact.state.addressText == retainedQuickPeek.url?.absoluteString && retained.quickPeekView(retainedQuick) === retainedQuickPeek, "The location command uses the visible Peek's address without discarding that preview")
        retained.openPeek(URL(string: "about:blank")!, from: primaryPage)
        let oldPrimaryPeek = retained.primaryPeekView!
        let primaryWindow = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        primaryWindow.contentView = primaryPage
        delegate.windows[primaryWindow] = retained; delegate.primaryOwners[primaryWindow] = retainedOwner
        delegate.primaryLeases[primaryWindow] = primaryLease; delegate.normalWindow = primaryWindow
        delegate.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: primaryWindow))
        check(retained.views[primaryID] == nil && primaryPage.navigationDelegate == nil && primaryPage.uiDelegate == nil && retained.primaryPeekView == nil && oldPrimaryPeek.navigationDelegate == nil, "Closing the actual primary delegate path tears down its documents and Peek while a quick window survives")
        check(retained.views[retainedQuick] === quickPage && retained.quickPeekView(retainedQuick) === retainedQuickPeek && retained.quickPage(retainedQuick) != nil && retained.tab(primaryID) != nil && !retained.isShuttingDown, "Primary native teardown preserves quick identity, its independent Peek and saved main tabs")
        check(delegate.ensureNormalOwner() === retainedOwner && retainedOwner.store === retained && delegate.normalWindow == nil, "Reopening after actual primary close resolves the same surviving data writer")
        retainedCompact.window?.close(); retainedOwner.release(retainedQuickLease)

        let privateRoot = root.appendingPathComponent("private")
        var keyRequests = 0
        let privateStore = BrowserStore(isPrivate: true, dataRoot: privateRoot, keyProvider: { _ in keyRequests += 1; return key })
        let privateOwner = BrowserWindowOwner(store: privateStore)
        let privateID = try privateStore.openQuickPage()
        let privateWindow = try QuickBrowseWindowController(owner: privateOwner, pageID: privateID, requestPrimary: {}, requestProfiles: {}, didClose: {})
        if privateWindow.windowShouldClose(privateWindow.window!) { privateWindow.window?.close() }
        check(privateOwner.isClosed && keyRequests == 0 && !FileManager.default.fileExists(atPath: privateRoot.path), "Closing the final native private quick window never requests or writes normal metadata")
        exit(failures == 0 ? 0 : 1)
    }
}
