import AppKit
import WebKit
import CryptoKit
import BrowserCore

@main struct ProfileStoreChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        var failures = 0
        func check(_ value: Bool, _ name: String) { print("\(value ? "PASS" : "FAIL"): \(name)"); if !value { failures += 1 } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256)
        let work = BrowserProfile(name: "Work", icon: "briefcase.fill")
        var defaultTab = BrowserCore.Tab(title: "Personal", url: "", pinned: true); defaultTab.favorite = true
        var workTab = BrowserCore.Tab(title: "Work", url: "", pinned: true); workTab.favorite = true
        let personal = Space(name: "Personal", tabs: [defaultTab])
        var workSpace = Space(name: "Work", tabs: [workTab]); workSpace.profileID = work.id
        var session = Session(); session.spaces = [personal, workSpace]; session.selectedSpace = workSpace.id
        var personalLibrary = BrowserLibrary(); personalLibrary.bookmark(title: "Personal bookmark", url: "https://example.com/personal")
        var workLibrary = BrowserLibrary(); workLibrary.bookmark(title: "Work bookmark", url: "https://example.com/work")
        var document = BrowserDocument(session: session, library: personalLibrary, profiles: [.defaultProfile, work], profileLibraries: [ProfileLibrary(profileID: BrowserProfile.defaultID, library: personalLibrary), ProfileLibrary(profileID: work.id, library: workLibrary)])
        document.preferences.onboardingCompleted = true
        try MetadataStore(url: root.appendingPathComponent("session-v2.sealed"), key: key).save(document)
        var store: BrowserStore? = BrowserStore(dataRoot: root, keyProvider: { _ in key })
        check(store!.library.bookmarks.first?.title == "Work bookmark", "Selected Space opens its own profile library")
        check(store!.favorites.map(\.id) == [workTab.id], "Favorites do not cross a profile boundary")
        var namedView: WKWebView? = store!.view(for: workTab.id)
        check(namedView!.configuration.websiteDataStore.identifier == work.id, "Named profile page uses its saved WebKit store identifier")
        var defaultView: WKWebView? = store!.view(for: defaultTab.id)
        check(defaultView!.configuration.websiteDataStore.identifier == nil && defaultView!.configuration.websiteDataStore.isPersistent, "Legacy profile page retains WebKit's persistent default store")
        let privateStore = BrowserStore(isPrivate: true, dataRoot: root.appendingPathComponent("private"), keyProvider: { _ in fatalError("Private requested a metadata key") })
        privateStore.session = session
        check(!privateStore.view(for: workTab.id).configuration.websiteDataStore.isPersistent, "Private windows ignore normal profile IDs and keep pages ephemeral")
        store!.selectSpace(personal.id)
        var popup = store!.createPopup(from: namedView!, configuration: WKWebViewConfiguration())
        let popupID = store!.views.first(where: { $0.value === popup })!.key
        check(popup?.configuration.websiteDataStore.identifier == work.id && store!.space.id == personal.id && store!.session.spaces.first(where: { $0.id == workSpace.id })!.tabs.contains(where: { $0.id == popupID }), "Background popup keeps its opener's Space and profile")
        store!.update(popupID) { $0.url = "https://example.com/background-popup" }
        store!.close(popupID); popup = nil
        check(store!.library(for: work.id).closedTabs.first?.url == "https://example.com/background-popup" && store!.library.closedTabs.isEmpty, "Closing a background page records it only in its owning profile")
        let unownedConfiguration = WKWebViewConfiguration(); unownedConfiguration.websiteDataStore = .nonPersistent()
        let unowned = WKWebView(frame: .zero, configuration: unownedConfiguration)
        store!.openPeek(URL(string: "about:blank")!, from: unowned)
        check(store!.primaryPeekView == nil, "An unowned stale page cannot open Peek in another profile")
        store!.closePrimaryPeek()
        store!.openPeek(URL(string: "about:blank")!, from: namedView!)
        check(store!.primaryPeekView?.configuration.websiteDataStore.identifier == work.id && store!.peekPages[.primary]?.spaceID == workSpace.id, "Peek uses the clicked page's profile instead of the selected Space")
        store!.closePrimaryPeek()
        var personalArchived = BrowserCore.Tab(title: "Personal archived", url: "https://example.com/personal-archived"); personalArchived.lastAccessed = Date(timeIntervalSince1970: 1)
        var workArchived = BrowserCore.Tab(title: "Work archived", url: "https://example.com/work-archived"); workArchived.lastAccessed = Date(timeIntervalSince1970: 1)
        store!.session.spaces[0].tabs.append(personalArchived); store!.session.spaces[1].tabs.append(workArchived)
        store!.preferences.archiveAfterDays = 1; store!.archiveOldTabs()
        check(store!.library.archive.map(\.id) == [personalArchived.id] && store!.library(for: work.id).archive.map(\.id) == [workArchived.id], "Automatic archive keeps each profile's records separate")
        store!.selectSpace(workSpace.id)
        store!.move(workTab.id, to: personal.id)
        check(store!.session.spaces.first(where: { $0.id == workSpace.id })!.tabs.contains(where: { $0.id == workTab.id }), "Moving between profiles requires explicit consent before changing page ownership")
        let moved = store!.move(workTab.id, to: personal.id, allowProfileChange: true)
        check(moved && store!.profileID(for: workTab.id) == BrowserProfile.defaultID && store!.views[workTab.id] == nil, "A consented cross-profile move discards the old native page before reuse")
        check(store!.view(for: workTab.id).configuration.websiteDataStore.identifier == nil, "Moved page recreates with the destination profile's store")
        let schoolID = try store!.createProfile(name: "School")
        let schoolSpaceID = store!.space.id; let schoolTabID = store!.selectedID!
        check(store!.activeProfileID == schoolID && store!.library.bookmarks.isEmpty, "Creating a profile opens a Space with an empty library")
        let durable = try MetadataStore(url: root.appendingPathComponent("session-v2.sealed"), key: key).load(BrowserDocument.self)!
        check(durable.profiles?.contains(where: { $0.id == schoolID }) == true && durable.session.spaces.contains(where: { $0.id == schoolSpaceID && $0.effectiveProfileID == schoolID }), "New profile identifiers are encrypted before website storage is used")
        var schoolView: WKWebView? = store!.view(for: schoolTabID)
        check(schoolView!.configuration.websiteDataStore.identifier == schoolID, "New profile pages use their own named store")
        try store!.assignProfile(work.id, to: schoolSpaceID)
        check(store!.views[schoolTabID] == nil && store!.library.bookmarks.first?.title == "Work bookmark", "Assigning a Space preserves tabs and switches its library")
        var assignedView: WKWebView? = store!.view(for: schoolTabID)
        check(assignedView !== schoolView && assignedView!.configuration.websiteDataStore.identifier == work.id, "Space reassignment recreates pages without transferring cookies")
        let locked = BrowserStore(dataRoot: root, keyProvider: { _ in throw CocoaError(.fileReadNoPermission) })
        locked.unlockLocalData(keyProvider: { key })
        for _ in 0..<500 where locked.unlocking { try await Task.sleep(for: .milliseconds(10)) }
        check(locked.savingEnabled && locked.activeProfileID == work.id && locked.library.bookmarks.first?.title == "Work bookmark" && locked.library(for: BrowserProfile.defaultID).bookmarks.first?.title == "Personal bookmark", "Unlock restores the registry and every profile's library atomically")
        store!.flush()
        let saved = try MetadataStore(url: root.appendingPathComponent("session-v2.sealed"), key: key).load(BrowserDocument.self)!
        check(saved.library(for: work.id).bookmarks.first?.title == "Work bookmark", "Encrypted browser save preserves every profile library")
        for id in Array(privateStore.views.keys) { privateStore.discardView(id) }
        for id in Array(store!.views.keys) { store!.discardView(id) }
        store!.archiveTimer?.invalidate(); locked.archiveTimer?.invalidate()
        namedView = nil; defaultView = nil; schoolView = nil; assignedView = nil; store!.namedDataStores.removeAll(); store = nil
        await Task.yield()
        for id in [work.id, schoolID] { try? await WKWebsiteDataStore.remove(forIdentifier: id) }
        exit(failures == 0 ? 0 : 1)
    }
}
