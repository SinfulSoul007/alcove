import AppKit
import BrowserCore
import CryptoKit

@main
struct BrowserWindowGroupChecks {
    @MainActor
    static func main() throws {
        var passed = 0
        var failed = 0
        func check(_ condition: Bool, _ description: String) {
            if condition {
                passed += 1
                print("PASS: \(description)")
            } else {
                failed += 1
                print("FAIL: \(description)")
            }
        }

        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent("alcove-window-group-\(UUID())")
        let movedURL = rootURL.appendingPathExtension("moved")
        defer {
            try? FileManager.default.removeItem(at: rootURL)
            try? FileManager.default.removeItem(at: movedURL)
        }
        let key = SymmetricKey(size: .bits256)
        var keyLookups = 0
        let root = BrowserStore(dataRoot: rootURL, keyProvider: { _ in keyLookups += 1; return key })
        let owner = BrowserWindowOwner(store: root)
        let first = try owner.acquirePrimaryStore()
        let otherSpace = try root.createSpace(name: "Second Space")
        let secondTab = root.newTab(url: URL(string: "https://example.net/"))
        let second = try owner.acquirePrimaryStore(copying: root)
        let child = second.store
        check(first.store === root && child !== root && owner.leaseCount == 2, "Normal windows lease distinct projections of one owner")
        check(keyLookups == 1 && root.vault != nil && root.metadataOwnership != nil && child.vault == nil && child.metadataOwnership == nil, "Only the root acquires a key, encrypted store and writer lease")
        check(child.space.id == otherSpace && child.selectedID == secondTab, "New window copies the source selection")
        let privateStore = BrowserStore(isPrivate: true)
        defer { privateStore.shutdown() }
        root.sidebarVisible = false
        root.findVisible = true
        child.selectSpace(child.session.spaces[0].id)
        check(root.space.id == otherSpace && child.space.id != otherSpace, "Selecting a Space in one window keeps the other window selection")
        check(child.sidebarVisible && !child.findVisible && !root.sidebarVisible && root.findVisible, "Sidebar and Find state stay local to each window")
        let childTab = child.newTab(url: URL(string: "https://example.org/"))
        check(root.tab(childTab)?.url == "https://example.org/" && root.selectedID == secondTab, "Direct tab creation appears in both windows with independent selection")
        var appearance = child.appearance
        appearance.animationsEnabled = false
        child.appearance = appearance
        check(!root.appearance.animationsEnabled && privateStore.appearance.animationsEnabled, "Preferences synchronize within the normal owner")

        let savedBefore = try root.vault?.load(BrowserDocument.self)
        let stale = root.makeDocument()
        let newProfile = try child.createProfile(name: "Testing Profile")
        check(root.profiles.contains { $0.id == newProfile } && child.activeProfileID == newProfile && root.activeProfileID != newProfile, "Durable profile creation updates all windows and selects only in the initiator")
        check(root.tab(childTab) != nil && privateStore.tab(childTab) == nil, "Normal tab changes stay outside private browsing")
        do {
            try root.commitProfileDocument(stale)
            check(false, "A stale prepared snapshot cannot overwrite the newer profile")
        } catch BrowserWindowGroupError.staleDocument {
            check(root.profiles.contains { $0.id == newProfile }, "A stale prepared snapshot cannot overwrite the newer profile")
        }
        let savedAfter = try root.vault?.load(BrowserDocument.self)
        check(savedBefore?.profiles?.contains { $0.id == newProfile } == false &&
              savedAfter?.profiles?.contains { $0.id == newProfile } == true,
              "A transaction from a second window commits through the original encrypted store")
        let quickURL = URL(string: "https://example.org/quick")!
        var presentedQuick: [UUID] = []
        root.quickPageRequested = { presentedQuick.append($0) }
        let quick = try child.openQuickPage(url: quickURL)
        check(root.quickPage(quick) != nil && child.quickPage(quick) != nil, "Compact pages remain shared with the root service store")
        let existing = try child.openQuickPage(url: quickURL)
        check(existing == quick && presentedQuick == [quick, quick], "Reopening a compact page from a secondary window surfaces the existing native window")
        root.quickPageRequested = nil
        let profileWebsiteStore = root.websiteDataStore(forProfile: newProfile)
        check(profileWebsiteStore === child.websiteDataStore(forProfile: newProfile) && child.namedDataStores.isEmpty,
              "The writer alone retains the shared WebKit data store for a profile")
        let quickLease = try owner.acquireQuick(quick)
        child.selectSpace(otherSpace)
        try root.renameSpace(otherSpace, name: "Renamed across windows")
        check(child.space.name == "Renamed across windows", "Space edits update the other window immediately")
        let durable = try root.vault?.load(BrowserDocument.self)
        check(durable?.workingRevision == nil, "The in-process edit revision is absent from the saved document")
        try root.deleteSpace(otherSpace)
        check(child.space.id != otherSpace && child.tab(secondTab) == nil, "Removing a Space repairs the other window and removes its tabs")

        owner.release(first.lease)
        check(!owner.isClosed && !root.isShuttingDown && root.metadataOwnership != nil &&
              owner.leaseCount == 2 && child.quickPage(quick) != nil, "Closing the root window keeps the writer and compact pages alive")
        let closed = child.makeDocument()
        owner.release(second.lease)
        check(child.isShuttingDown && !root.isShuttingDown && root.quickPage(quick) != nil, "Closing a member retires only its store while a compact window remains")
        do {
            try child.commitProfileDocument(closed)
            check(false, "A closed member cannot commit")
        } catch is CancellationError {
            check(true, "A closed member cannot commit")
        }

        let last = try owner.acquirePrimaryStore()
        let observer = try owner.acquirePrimaryStore(copying: last.store)
        let published = last.store.makeDocument()
        try FileManager.default.moveItem(at: rootURL, to: movedURL)
        do {
            var invalid = published
            invalid.preferences.archiveAfterDays = 99
            try last.store.commitProfileDocument(invalid)
            check(false, "A writer failure keeps the proposed state out of every window")
        } catch {
            check(!root.savingEnabled && !observer.store.savingEnabled && observer.store.preferences.archiveAfterDays != 99,
                  "A writer failure keeps the proposed state out of every window")
        }
        owner.release(last.lease)
        owner.release(observer.lease)
        owner.release(quickLease)
        check(owner.isClosed && root.isShuttingDown && root.metadataOwnership == nil, "The last lease releases the sole writer and completes shutdown")
        print("Window group checks: \(passed) passed, \(failed) failed")
        if failed > 0 { exit(1) }
    }
}
