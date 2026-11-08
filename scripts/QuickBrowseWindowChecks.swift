import AppKit
import CryptoKit
import WebKit
import BrowserCore

/// Only the OS focus signal is substituted; no window is shown and no device is requested.
@MainActor final class FocusFixtureWindow: NSWindow {
    var fixtureIsKey = false
    var fixtureSheet: NSWindow?
    override var isKeyWindow: Bool { fixtureIsKey }
    override var attachedSheet: NSWindow? { fixtureSheet ?? super.attachedSheet }
}

@main struct QuickBrowseWindowChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        var failures = 0
        func check(_ value: Bool, _ name: String) { print("\(value ? "PASS" : "FAIL"): \(name)"); if !value { failures += 1 } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256)
        let store = BrowserStore(dataRoot: root, keyProvider: { _ in key })
        var ended = 0
        let owner = BrowserWindowOwner(store: store, onLastWindow: { ended += 1 })
        let primary = try owner.acquirePrimary()
        let quick = try store.openQuickPage()
        let lease = try owner.acquireQuick(quick)
        check(try owner.acquireQuick(quick) == lease && owner.leaseCount == 2, "Resurfacing one quick window does not create a duplicate lease")
        owner.release(primary)
        check(!store.isShuttingDown && owner.store === store && owner.leaseCount == 1, "Closing the primary keeps its single browser store alive while a quick window remains")
        let reopened = try owner.acquirePrimary()
        check(owner.store === store && !owner.isClosed, "Reopening the primary reuses the same live data writer")
        owner.release(primary)
        check(owner.leaseCount == 2 && ended == 0, "An already-released window cannot shut down another live lease")
        owner.release(reopened); owner.release(lease); owner.release(lease)
        check(store.isShuttingDown && owner.isClosed && ended == 1, "The final window shuts its owner down exactly once")
        var rejected = false
        do { _ = try owner.acquirePrimary() } catch { rejected = true }
        check(rejected, "A disposed owner cannot reopen a shut-down browser store")

        let second = BrowserStore(dataRoot: root.appendingPathComponent("handoff"), keyProvider: { _ in key })
        let handoffOwner = BrowserWindowOwner(store: second)
        let page = try second.openQuickPage()
        let quickLease = try handoffOwner.acquireQuick(page)
        let destinationLease = try handoffOwner.acquirePrimary()
        second.quickPagesDidChange = { if second.quickPage(page) == nil { handoffOwner.release(quickLease) } }
        _ = try second.promoteQuickPage(page)
        second.quickPagesDidChange = nil
        check(!second.isShuttingDown && handoffOwner.leaseCount == 1, "Promotion retains a primary lease before removing the quick window")
        handoffOwner.release(destinationLease)
        check(second.isShuttingDown, "The promoted page's last primary lease releases the writer")

        let external = BrowserStore(dataRoot: root.appendingPathComponent("external"), keyProvider: { _ in key })
        let externalOwner = BrowserWindowOwner(store: external)
        let externalLease = try externalOwner.acquirePrimary()
        let spaceA = external.space.id
        let profileB = try external.createProfile(name: "Work")
        external.selectSpace(spaceA)
        external.preferences.quickDomainChoices = [QuickDomainChoice(host: "work.example", profileID: profileB)]
        let url = URL(string: "https://work.example/path")!
        let routed = try externalOwner.dispatchExternal(url)
        guard case .quick(let routedID) = routed else { fatalError("Expected quick destination") }
        check(external.quickProfileID(routedID) == profileB && external.space.id == spaceA, "An external domain choice uses its remembered profile without changing the main Space")
        check(try externalOwner.dispatchExternal(url) == routed, "An identical external URL resurfaces its existing compact page")
        let lookalike = try externalOwner.dispatchExternal(URL(string: "https://sub.work.example/")!)
        guard case .quick(let localID) = lookalike else { fatalError("Expected quick destination") }
        check(external.quickProfileID(localID) == BrowserProfile.defaultID, "Subdomains do not inherit another hostname's account selection")
        var resurfaced: UUID?
        external.quickPageRequested = { resurfaced = $0 }
        let selectedBeforeSearch = external.selectedID
        check(external.profileTabs.contains { $0.id == localID } && !external.profileTabs.contains { $0.id == routedID }, "Command search includes open quick pages only from its current profile")
        external.selectAny(localID)
        check(resurfaced == localID && external.selectedID == selectedBeforeSearch && external.quickPage(localID) != nil, "Selecting a quick search result resurfaces its window without turning it into a Today tab")
        resurfaced = nil; external.selectAny(routedID)
        check(resurfaced == nil && external.space.id == spaceA, "A stale quick search result cannot switch into another profile")
        external.quickPageRequested = nil
        try external.bookmarkQuickPage(routedID)
        check(external.library(for: profileB).bookmarks.contains { $0.url == url.absoluteString } && external.library(for: BrowserProfile.defaultID).bookmarks.isEmpty, "Bookmarking a quick page writes only its captured profile's library")
        let oldWorkSpace = external.session.spaces.first { $0.effectiveProfileID == profileB }!.id
        try external.assignProfile(BrowserProfile.defaultID, to: oldWorkSpace)
        let beforeLibrary = external.allQuickPages.count
        try external.focusProfileSpace(profileB)
        check(external.activeProfileID == profileB && external.space.id != oldWorkSpace && external.allQuickPages.count == beforeLibrary, "Opening a quick page's Library creates a matching Space when its profile has none without moving its quick pages")
        external.preferences.quickBrowseExternalLinks = false
        let quickCount = external.allQuickPages.count
        let direct = try externalOwner.dispatchExternal(URL(string: "https://work.example/direct")!)
        guard case .space(let directSpace) = direct else { fatalError("Expected Space destination") }
        check(external.space.id == directSpace && external.activeProfileID == profileB && external.selectedTab?.url == "https://work.example/direct" && external.allQuickPages.count == quickCount, "External-link opt-out commits directly into the chosen profile's Space without a temporary quick page")
        rejected = false
        do { _ = try externalOwner.dispatchExternal(URL(string: "file:///tmp/example")!) } catch { rejected = true }
        check(rejected && external.allQuickPages.count == quickCount, "Non-web external URLs cannot create persistent browser pages")
        let snapshot = external.quickActionSnapshot(routedID)!
        check(external.matchesQuickAction(snapshot), "A quick action captures its original page and profile")
        external.update(routedID) { $0.url = "https://work.example/changed" }
        check(!external.matchesQuickAction(snapshot), "A modal action is cancelled when its source navigates while awaiting consent")
        external.profiles[external.profiles.firstIndex(where: { $0.id == profileB })!].pendingDataClear = true
        rejected = false
        do { _ = try externalOwner.dispatchExternal(url) } catch { rejected = true }
        check(rejected && external.allQuickPages.count == quickCount, "A remembered but paused external profile never falls through into another account")
        external.profiles[external.profiles.firstIndex(where: { $0.id == profileB })!].pendingDataClear = nil
        let archivedPage = try external.openQuickPage(url: URL(string: "https://work.example/archive"), profileID: profileB)
        try external.closeQuickPage(archivedPage)
        let windowsBeforeRestore = external.allQuickPages.count
        let restoredPage = try external.restoreQuickArchiveInSpace(archivedPage, profileID: profileB)
        check(restoredPage != archivedPage && external.selectedID == restoredPage && external.selectedTab?.archiveSource == nil && external.activeProfileID == profileB && external.library(for: profileB).archive.allSatisfy { $0.id != archivedPage } && external.allQuickPages.count == windowsBeforeRestore, "A quick archive restores directly into its profile's Space with fresh identity and no transient compact window")
        let failedArchive = try external.openQuickPage(url: URL(string: "https://work.example/keep-archive"), profileID: profileB)
        try external.closeQuickPage(failedArchive)
        let selectedBeforeFailure = external.selectedID
        let beforeFailure = try Data(contentsOf: external.sessionURL)
        external.vault = MetadataStore(url: root, key: key)
        rejected = false
        do { _ = try externalOwner.dispatchExternal(URL(string: "https://work.example/failed-save")!) } catch { rejected = true }
        let afterFailure = try Data(contentsOf: external.sessionURL)
        check(rejected && beforeFailure == afterFailure && external.selectedID == selectedBeforeFailure, "A failed direct external save preserves the selected page and prior encrypted data")
        rejected = false
        do { _ = try external.restoreQuickArchiveInSpace(failedArchive, profileID: profileB) } catch { rejected = true }
        check(rejected && external.library(for: profileB).archive.contains { $0.id == failedArchive } && external.selectedID == selectedBeforeFailure, "A failed archive restore keeps its recoverable record and existing selected page")
        externalOwner.release(externalLease)

        var keyRequests = 0
        let privateRoot = root.appendingPathComponent("private")
        let privateStore = BrowserStore(isPrivate: true, dataRoot: privateRoot, keyProvider: { _ in keyRequests += 1; return key })
        let privateOwner = BrowserWindowOwner(store: privateStore)
        let privateID = try privateStore.openQuickPage()
        let privateLease = try privateOwner.acquireQuick(privateID)
        rejected = false
        do { _ = try privateOwner.dispatchExternal(url) } catch { rejected = true }
        check(rejected && privateStore.allQuickPages.count == 1, "External-link dispatch cannot use a focused private owner's temporary account")
        privateOwner.release(privateLease)
        check(keyRequests == 0 && privateStore.isShuttingDown && !FileManager.default.fileExists(atPath: privateRoot.path), "The last private quick window disposes its owner without accessing normal metadata")
        let focused = BrowserStore(dataRoot: root.appendingPathComponent("focus"), keyProvider: { _ in key })
        focused.onboardingVisible = false // The foreground primary fixture is past its welcome overlay.
        let focusID = try focused.openQuickPage()
        let quickWeb = focused.view(for: focusID)
        let compact = FocusFixtureWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        let main = FocusFixtureWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        let host = NSView(); compact.contentView = host; host.addSubview(quickWeb)
        let primaryWeb = focused.view(for: focused.selectedID!); main.contentView = primaryWeb
        compact.fixtureIsKey = true; focused.focusedQuickPageID = focusID
        check(focused.isFocusedWebsite(quickWeb) && !focused.isFocusedWebsite(primaryWeb), "Permission eligibility follows the focused quick window instead of the main window's selected tab")
        let permissionSheet = FocusFixtureWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        compact.fixtureIsKey = false; compact.fixtureSheet = permissionSheet; permissionSheet.fixtureIsKey = true
        focused.focusedQuickPageID = nil // Native sheets take key status from their parent.
        check(focused.isFocusedWebsite(quickWeb), "A foreground permission sheet keeps its originating quick website eligible when the parent resigns key status")
        permissionSheet.fixtureIsKey = false
        check(!focused.isFocusedWebsite(quickWeb), "A background permission sheet cannot keep capture eligibility")
        compact.fixtureSheet = nil; compact.fixtureIsKey = true; focused.focusedQuickPageID = focusID
        focused.openPeek(URL(string: "about:blank")!, from: quickWeb)
        let peek = focused.peekView!; host.addSubview(peek)
        check(focused.isFocusedWebsite(peek) && !focused.isFocusedWebsite(quickWeb), "A quick Peek is the only eligible website while it covers its parent")
        compact.fixtureIsKey = false; main.fixtureIsKey = true; focused.focusedQuickPageID = nil
        check(focused.isFocusedWebsite(primaryWeb) && !focused.isFocusedWebsite(peek), "A background quick Peek cannot request devices or block another foreground primary page")
        focused.profiles[0].pendingDataClear = true
        check(!focused.isFocusedWebsite(primaryWeb), "A profile paused for website clearing cannot request capture permission")
        focused.profiles[0].pendingDataClear = nil
        main.fixtureIsKey = false; compact.fixtureSheet = permissionSheet; permissionSheet.fixtureIsKey = true
        for _ in 0..<500 where peek.isLoading || quickWeb.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        check(!peek.isLoading && !quickWeb.isLoading, "The sheet-expiry fixture has finished loading before its inactivity check")
        focused.archiveInactiveQuickPages(now: Date().addingTimeInterval(7 * 3600))
        for _ in 0..<300 where focused.quickArchiveProbeID != nil { try await Task.sleep(for: .milliseconds(10)) }
        check(focused.quickPage(focusID) != nil, "Inactivity expiry keeps a quick page while its native sheet is open")
        focused.shutdown(); compact.contentView = nil; main.contentView = nil
        exit(failures == 0 ? 0 : 1)
    }
}
