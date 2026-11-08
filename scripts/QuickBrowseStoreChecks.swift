import AppKit
import Darwin
import WebKit
import CryptoKit
import BrowserCore

@main struct QuickBrowseStoreChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared; setbuf(stdout, nil)
        let owned = try OwnedWebsiteStores()
        if CommandLine.arguments.contains("--cleanup-owned-stores") { exit(await owned.cleanup() ? 0 : 1) }
        guard await owned.cleanup() else { exit(1) }
        var failures = 0
        func check(_ value: Bool, _ name: String) { print("\(value ? "PASS" : "FAIL"): \(name)"); if !value { failures += 1 } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256)
        let store = BrowserStore(dataRoot: root, keyProvider: { _ in key })
        let personalSpace = store.space.id
        let work = try store.createProfile(name: "Work"); try owned.register(work)
        let originalWorkSpace = store.space.id
        let url = URL(string: "https://example.com/external")!
        let initialTabCount = store.session.spaces.flatMap(\.tabs).count
        var requested: [UUID] = []; store.quickPageRequested = { requested.append($0) }
        let first = try store.openQuickPage(url: url, profileID: work, intendedSpaceID: originalWorkSpace)
        let saved = try MetadataStore(url: store.sessionURL, key: key).load(BrowserDocument.self)!
        check(saved.library(for: work).quickPages?.contains(where: { $0.id == first }) == true && store.session.spaces.flatMap(\.tabs).count == initialTabCount, "Quick creation is encrypted before exposure and does not add a Today tab")
        store.update(first) { $0.url = "https://example.com/redirected" }
        let same = try store.openQuickPage(url: url, profileID: work)
        check(same == first && requested == [first, first], "Repeating an external link resurfaces its existing window after a redirect")
        let separate = try store.openQuickPage(url: url, profileID: BrowserProfile.defaultID)
        check(separate != first && store.quickProfileID(separate) == BrowserProfile.defaultID, "Identical URLs in different profiles never share a quick page")
        let blank = try store.openQuickPage(profileID: work, intendedSpaceID: originalWorkSpace)
        let secondBlank = try store.openQuickPage(profileID: work)
        check(blank != secondBlank, "Each explicit blank quick-window request opens a separate page")
        var live: WKWebView? = store.view(for: blank)
        check(live!.configuration.websiteDataStore.identifier == work && store.profileID(for: blank) == work, "A quick page uses its saved profile's named WebKit store")
        try store.assignProfile(BrowserProfile.defaultID, to: originalWorkSpace)
        store.selectSpace(personalSpace)
        check(store.quickProfileID(blank) == work && store.quickPage(blank)?.intendedSpaceID == nil && store.views[blank] === live, "Space reassignment cannot transfer or reload an independent quick page")
        let promotedSpace = try store.promoteQuickPage(blank)
        check(store.space.id == promotedSpace && store.activeProfileID == work && store.selectedID == blank && store.quickPage(blank) == nil, "Promotion creates a Space for the captured profile when none remains")
        check(store.views[blank] === live, "Same-profile promotion retains the exact live native page")
        let crossing = try store.openQuickPage(profileID: BrowserProfile.defaultID)
        var oldCrossing: WKWebView? = store.view(for: crossing)
        let bytes = try Data(contentsOf: store.sessionURL)
        var rejected = false
        do { _ = try store.promoteQuickPage(crossing, to: promotedSpace) } catch { rejected = true }
        let afterDenied = try Data(contentsOf: store.sessionURL)
        check(rejected && store.quickProfileID(crossing) == BrowserProfile.defaultID && store.views[crossing] === oldCrossing && afterDenied == bytes, "An unconsented cross-profile promotion preserves page ownership and ciphertext")
        _ = try store.promoteQuickPage(crossing, to: promotedSpace, allowProfileChange: true)
        check(store.views[crossing] == nil && store.profileID(for: crossing) == work && store.quickPage(crossing) == nil, "Consented cross-profile promotion releases the old native page")
        check(store.view(for: crossing).configuration.websiteDataStore.identifier == work, "A promoted cross-profile page recreates using only its destination store")
        try store.closeQuickPage(secondBlank)
        check(store.quickPage(secondBlank) == nil && store.library(for: work).archive.isEmpty, "Closing a blank quick window creates no archive entry")
        try store.closeQuickPage(first)
        check(store.library(for: work).archive.first?.url == "https://example.com/redirected" && store.library(for: work).archive.first?.archiveSource == "quickBrowse", "Closing a quick page archives its latest URL in its actual profile")
        let restored = try store.restoreQuickArchive(first, profileID: work)
        check(restored != first && store.quickProfileID(restored) == work && store.library(for: work).archive.isEmpty, "Restoring a quick archive uses fresh identity and removes the old archive record")
        store.update(separate) { $0.url = "" }
        var protected: WKWebView? = store.view(for: separate)
        store.preferences.suspendTabs = true
        for _ in 0..<9 { _ = store.view(for: store.newTab()) }
        check(store.views[separate] === protected, "Background-tab suspension never unloads a visible quick window")
        check(!store.view(for: UUID()).configuration.websiteDataStore.isPersistent, "An unknown page identity cannot inherit the active profile's persistent website store")
        let parent = try store.openQuickPage(profileID: work, intendedSpaceID: promotedSpace)
        var parentView: WKWebView? = store.view(for: parent)
        try store.assignProfile(BrowserProfile.defaultID, to: promotedSpace)
        let beforePopup = Set(store.allQuickPages.map(\.id))
        var popupConfig: WKWebViewConfiguration? = WKWebViewConfiguration(); popupConfig?.applicationNameForUserAgent = "AlcoveQuickPopupFixture"
        var exposedPopupConfiguration: String?
        store.quickPagesDidChange = {
            if let id = store.allQuickPages.first(where: { !beforePopup.contains($0.id) })?.id {
                exposedPopupConfiguration = store.view(for: id).configuration.applicationNameForUserAgent
            }
        }
        var popup: WKWebView? = store.createPopup(from: parentView!, configuration: popupConfig!)
        popupConfig = nil // The caller's configuration also retains the named website store.
        store.quickPagesDidChange = nil
        let popupID = store.views.first(where: { $0.value === popup })?.key
        check(popupID.flatMap { store.quickProfileID($0) } == work && popup?.configuration.websiteDataStore.identifier == work, "A quick popup retains its opener's profile even after its intended Space changes")
        check(exposedPopupConfiguration == "AlcoveQuickPopupFixture", "A popup's WebKit configuration is installed before window observers can render it")
        store.openPeek(URL(string: "about:blank")!, from: parentView!)
        check(store.peekPages[.quick(parent)]?.profileID == work && store.peekContext(for: store.quickPeekView(parent)!) == .quick(parent) && store.peekPages[.quick(parent)]?.spaceID == nil && store.quickPeekView(parent)?.configuration.websiteDataStore.identifier == work, "Peek belongs to its quick source even when that profile has no remaining Space")
        check(store.primaryPeekView == nil, "A quick window's Peek cannot also mount in the main window")
        var peekPopup: WKWebView?
        if let peek = store.quickPeekView(parent) { peekPopup = store.createPopup(from: peek, configuration: WKWebViewConfiguration()) }
        let peekPopupID = store.views.first(where: { $0.value === peekPopup })?.key
        check(peekPopupID.flatMap { store.quickProfileID($0) } == work, "A popup opened from quick Peek keeps the same profile and compact-window lifecycle")
        store.closeQuickPeek(parent)
        store.preferences.quickDomainChoices = [QuickDomainChoice(host: "clear.example", profileID: work)]
        var clearObserved = false; var clearRouteBlocked = false
        try await store.clearProfileData(work, removeData: { _ in
            clearObserved = store.quickPages(for: work).isEmpty && store.views[parent] == nil
            let available = Set(store.profiles.filter { !store.profileUnavailable($0.id) }.map(\.id))
            clearRouteBlocked = QuickBrowseRouting.profile(for: URL(string: "https://clear.example/")!, choices: store.preferences.quickDomainChoices ?? [], available: available, fallback: BrowserProfile.defaultID) == nil
        })
        check(clearObserved && store.quickPages(for: work).isEmpty && store.quickPage(separate) != nil && store.views[separate] === protected, "Clearing a profile removes its quick pages before WebKit clearing while preserving another profile's live window")
        check(clearRouteBlocked && store.preferences.quickDomainChoices?.contains(where: { $0.profileID == work }) == false, "Pending clear blocks remembered-domain fallback and removes its choices only after completion")
        let deletionID = try store.createProfile(name: "Delete Quick")
        let deletionSpace = store.space.id
        let deletionPage = try store.openQuickPage(url: URL(string: "https://delete.example/"), profileID: deletionID)
        store.preferences.quickDomainChoices = [QuickDomainChoice(host: "delete.example", profileID: deletionID)]
        try store.assignProfile(BrowserProfile.defaultID, to: deletionSpace)
        var archivedBeforeRemoval = false
        do {
            try await store.deleteProfile(deletionID, removeStore: { _ in
                archivedBeforeRemoval = store.quickPage(deletionPage) == nil && store.library(for: deletionID).archive.first?.url == "https://delete.example/"
                throw CocoaError(.fileWriteUnknown)
            })
        } catch { }
        check(archivedBeforeRemoval && store.profiles.first(where: { $0.id == deletionID })?.isPendingDeletion == true, "Interrupted profile deletion keeps closed quick URLs in its retryable encrypted library")
        try await store.deleteProfile(deletionID, removeStore: { _ in })
        check(store.preferences.quickDomainChoices?.contains(where: { $0.profileID == deletionID }) == false && !store.profiles.contains(where: { $0.id == deletionID }), "Completed deletion removes its quick records and remembered domain choices")
        store.vault = MetadataStore(url: root, key: key)
        let beforeFailure = try Data(contentsOf: store.sessionURL)
        rejected = false
        do { try store.changeQuickProfile(separate, to: work, rememberHost: true, allowReload: true) } catch { rejected = true }
        let afterFailure = try Data(contentsOf: store.sessionURL)
        check(rejected && !store.savingEnabled && store.quickProfileID(separate) == BrowserProfile.defaultID && store.views[separate] === protected && beforeFailure == afterFailure, "A failed quick-profile save preserves its original live page, owner and encrypted data")
        store.update(separate) { $0.url = "https://example.com/latest-unsaved" }
        store.unlockLocalData(keyProvider: { key })
        for _ in 0..<500 where store.unlocking { try await Task.sleep(for: .milliseconds(10)) }
        check(store.savingEnabled && store.quickPage(separate)?.tab.url == "https://example.com/latest-unsaved" && store.views[separate] === protected, "Unlock retains latest quick navigation and its live page without duplicate or resurrected records")
        let privateRoot = root.appendingPathComponent("private")
        var keyRequests = 0
        let privateStore = BrowserStore(isPrivate: true, dataRoot: privateRoot, keyProvider: { _ in keyRequests += 1; return key })
        let privateID = try privateStore.openQuickPage(profileID: work)
        check(privateStore.quickProfileID(privateID) == BrowserProfile.defaultID && !privateStore.view(for: privateID).configuration.websiteDataStore.isPersistent, "Private Quick Browse ignores normal profile identities and uses only its owner's temporary store")
        _ = try privateStore.promoteQuickPage(privateID)
        privateStore.flush()
        check(keyRequests == 0 && !FileManager.default.fileExists(atPath: privateRoot.path), "Private quick creation and promotion never access or write normal metadata")
        _ = try privateStore.openQuickPage(url: URL(string: "https://example.com/private-clear"))
        var privateClearRejected = false
        try await privateStore.clearProfileData(BrowserProfile.defaultID, removeData: { _ in
            do { _ = try privateStore.openQuickPage() } catch { privateClearRejected = true }
        })
        check(privateClearRejected && privateStore.allQuickPages.isEmpty && keyRequests == 0, "Private website clearing pauses new quick pages and removes its temporary quick records")
        privateStore.shutdown(); store.shutdown()
        live = nil; oldCrossing = nil; protected = nil; parentView = nil; popup = nil; peekPopup = nil
        let clock = ContinuousClock(); let deadline = clock.now.advanced(by: .seconds(5))
        while store.closingPages.contains(where: { $0.webView != nil }) && clock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        store.namedDataStores.removeAll()
        if !(await owned.cleanup()) { failures += 1 }
        exit(failures == 0 ? 0 : 1)
    }
}
