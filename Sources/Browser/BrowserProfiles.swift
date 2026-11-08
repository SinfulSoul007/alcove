import AppKit
import WebKit
import BrowserCore
import Combine

@MainActor
final class ProfileDataOperations: ObservableObject {
    static let shared = ProfileDataOperations()
    @Published private(set) var activeIDs: Set<UUID> = []
    func begin(_ id: UUID) -> Bool { guard !activeIDs.contains(id) else { return false }; activeIDs.insert(id); return true }
    func finish(_ id: UUID) { activeIDs.remove(id) }
}

final class ClosingProfilePage {
    weak var webView: WKWebView?
    let profileID: UUID
    init(_ webView: WKWebView, profileID: UUID) { self.webView = webView; self.profileID = profileID }
}

enum ProfileError: LocalizedError {
    case privateMode, locked, missing, pending, inUse, defaultProfile, busy, pagesClosing
    var errorDescription: String? {
        switch self {
        case .privateMode: return "Profiles are managed in a normal window."
        case .locked: return "Unlock local data before changing profiles."
        case .missing: return "This profile no longer exists."
        case .pending: return "This profile has an unfinished deletion. Finish or retry it before using the profile."
        case .inUse: return "Move this profile’s Spaces to another profile before deleting it."
        case .defaultProfile: return "The default profile can be cleared but cannot be removed."
        case .busy: return "Another profile data operation is still running."
        case .pagesClosing: return "Some pages are still closing. Try deleting this profile again shortly."
        }
    }
}

extension BrowserStore {
    func deleteProfile(_ id: UUID, removeStore: @escaping @MainActor (UUID) async throws -> Void = { id in
        if await WKWebsiteDataStore.allDataStoreIdentifiers.contains(id) { try await WKWebsiteDataStore.remove(forIdentifier: id) }
    }) async throws {
        guard !isPrivate else { throw ProfileError.privateMode }
        guard deletingProfileID == nil, !clearingData else { throw ProfileError.busy }
        guard id != BrowserProfile.defaultID else { throw ProfileError.defaultProfile }
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { throw ProfileError.missing }
        guard !profiles[index].isPendingClear else { throw ProfileError.busy }
        guard !session.spaces.contains(where: { $0.effectiveProfileID == id }) else { throw ProfileError.inUse }
        guard ProfileDataOperations.shared.begin(id) else { throw ProfileError.busy }
        defer { ProfileDataOperations.shared.finish(id) }
        deletingProfileID = id; defer { deletingProfileID = nil }
        var candidate = makeDocument(); candidate.profiles?[index].pendingDeletion = true
        try commitProfileDocument(candidate)
        if peekProfileID == id { closePeek() }
        for tabID in Array(views.keys) where viewProfileIDs[tabID] == id { discardView(tabID) }
        namedDataStores.removeValue(forKey: id)
        do {
            let clock = ContinuousClock(); let deadline = clock.now.advanced(by: .seconds(5))
            while closingPages.contains(where: { $0.profileID == id && $0.webView != nil }) {
                guard !isShuttingDown else { throw CancellationError() }
                guard clock.now < deadline else { throw ProfileError.pagesClosing }
                try await Task.sleep(for: .milliseconds(20))
            }
            closingPages.removeAll { $0.webView == nil }
            guard !isShuttingDown else { throw CancellationError() }
            try await removeStore(id)
            guard !isShuttingDown else { throw CancellationError() }
        }
        catch { message = "Couldn’t remove this profile’s website data. Its entry and library were kept so you can retry. \(error.localizedDescription)"; throw error }
        var finished = makeDocument()
        finished.profiles?.removeAll { $0.id == id }; finished.profileLibraries?.removeAll { $0.profileID == id }
        do { try commitProfileDocument(finished) }
        catch { message = "Website data was removed, but deletion could not be finalized. Unlock local data and retry; the profile entry was kept."; throw error }
        message = "Profile deleted. Other profiles were kept."
    }
    func renameProfile(_ id: UUID, name: String) throws {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { throw ProfileError.missing }
        guard !profiles[index].isPendingDeletion, !profiles[index].isPendingClear else { throw ProfileError.pending }
        var candidate = makeDocument(); candidate.profiles?[index].name = BrowserProfile.cleanedName(name)
        try commitProfileDocument(candidate)
    }
    func clearProfileData(_ id: UUID, removeData: @escaping @MainActor (WKWebsiteDataStore) async throws -> Void = { dataStore in
        await withCheckedContinuation { continuation in dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { continuation.resume() } }
    }) async throws {
        guard !clearingData, deletingProfileID == nil else { throw ProfileError.busy }
        guard !isShuttingDown else { throw CancellationError() }
        guard isPrivate ? id == BrowserProfile.defaultID : profiles.contains(where: { $0.id == id && !$0.isPendingDeletion }) else { throw ProfileError.missing }
        if !isPrivate { guard ProfileDataOperations.shared.begin(id) else { throw ProfileError.busy } }
        defer { if !isPrivate { ProfileDataOperations.shared.finish(id) } }
        if !isPrivate { guard savingEnabled, vault != nil, persistedProfileIDs.contains(id) else { throw ProfileError.locked } }
        var candidate = makeDocument(); var affected: [UUID] = []
        let resuming = !isPrivate && profiles.first(where: { $0.id == id })?.isPendingClear == true
        if let index = candidate.profiles?.firstIndex(where: { $0.id == id }) { candidate.profiles?[index].pendingDataClear = true }
        for index in candidate.session.spaces.indices where !resuming && (isPrivate || candidate.session.spaces[index].effectiveProfileID == id) {
            affected += candidate.session.spaces[index].tabs.map(\.id)
            let empty = BrowserCore.Tab(); candidate.session.spaces[index].tabs = [empty]; candidate.session.spaces[index].selected = empty.id
        }
        var records = library(for: id)
        if !resuming { records.history = []; records.archive = []; records.closedTabs = [] }
        candidate.setLibrary(records, for: id)
        if isPrivate { for tabID in affected { discardView(tabID) }; session = candidate.session; setLibrary(records, for: id); splitID = nil; activePaneID = nil }
        else { try commitProfileDocument(candidate, discarding: affected, resetting: activeProfileID == id ? space.id : nil) }
        if peekProfileID == id { closePeek() }
        clearingData = true; clearingProfileID = id
        defer { clearingData = false; clearingProfileID = nil }
        // This path is deliberately allowed to access a pending-clear store for removal only.
        let dataStore: WKWebsiteDataStore
        if let privateDataStore { dataStore = privateDataStore }
        else if id == BrowserProfile.defaultID { dataStore = .default() }
        else if let cached = namedDataStores[id] { dataStore = cached }
        else { let created = WKWebsiteDataStore(forIdentifier: id); namedDataStores[id] = created; dataStore = created }
        do { try await removeData(dataStore) }
        catch { message = "Website clearing did not finish. This profile remains paused so you can retry safely. \(error.localizedDescription)"; throw error }
        guard !isShuttingDown else { throw CancellationError() }
        for tabID in Array(views.keys) where viewProfileIDs[tabID] == id { discardView(tabID) }
        if !isPrivate {
            var finished = makeDocument()
            if let index = finished.profiles?.firstIndex(where: { $0.id == id }) { finished.profiles?[index].pendingDataClear = false }
            do { try commitProfileDocument(finished) }
            catch { message = "Website data was cleared, but its completion could not be saved. Unlock local data and retry this profile’s clear operation."; throw error }
        }
        message = "Website data and history cleared for this profile. Other profiles, bookmarks and downloaded files were kept."
    }
    func profileUnavailable(_ id: UUID) -> Bool {
        if clearingProfileID == id { return true }
        if isPrivate { return false }
        if ProfileDataOperations.shared.activeIDs.contains(id) { return true }
        return !persistedProfileIDs.contains(id) || !profiles.contains(where: { $0.id == id && !$0.isPendingDeletion && !$0.isPendingClear })
    }
    var activeProfileID: UUID { isPrivate ? BrowserProfile.defaultID : space.effectiveProfileID }
    var activeProfile: BrowserProfile { profiles.first(where: { $0.id == activeProfileID }) ?? .defaultProfile }
    var profileDataOperationInProgress: Bool { clearingData || deletingProfileID != nil || (!isPrivate && !ProfileDataOperations.shared.activeIDs.isEmpty) }
    func profileID(for tabID: UUID) -> UUID? {
        guard !isPrivate else { return BrowserProfile.defaultID }
        return session.spaces.first(where: { $0.tabs.contains(where: { $0.id == tabID }) })?.effectiveProfileID
    }
    func profileID(for web: WKWebView) -> UUID? {
        if web === peekView { return peekProfileID }
        return views.first(where: { $0.value === web }).flatMap { viewProfileIDs[$0.key] }
    }
    func spaceID(for web: WKWebView) -> UUID? {
        if web === peekView { return peekSpaceID }
        return views.first(where: { $0.value === web }).flatMap { item in session.spaces.first(where: { $0.tabs.contains(where: { $0.id == item.key }) })?.id }
    }
    func library(for id: UUID) -> BrowserLibrary { profileLibraries.first(where: { $0.profileID == id })?.library ?? BrowserLibrary() }
    func setLibrary(_ value: BrowserLibrary, for id: UUID) {
        if let index = profileLibraries.firstIndex(where: { $0.profileID == id }) { profileLibraries[index].library = value }
        else { profileLibraries.append(ProfileLibrary(profileID: id, library: value)) }
    }
    func mutateLibrary(for id: UUID, _ change: (inout BrowserLibrary) -> Void) {
        var value = library(for: id); change(&value); setLibrary(value, for: id)
    }
    func makeDocument() -> BrowserDocument {
        BrowserDocument(session: session, library: library(for: BrowserProfile.defaultID), preferences: preferences, profiles: profiles, profileLibraries: profileLibraries)
    }
    func applyDocument(_ document: BrowserDocument) {
        var prepared = document; prepared.repairProfiles()
        session = Self.repairedSession(prepared.session); profiles = prepared.profiles ?? [.defaultProfile]
        profileLibraries = prepared.profileLibraries ?? [ProfileLibrary(profileID: BrowserProfile.defaultID, library: prepared.library)]
        preferences = prepared.preferences
    }
    func commitProfileDocument(_ candidate: BrowserDocument, discarding ids: [UUID] = [], resetting spaceID: UUID? = nil) throws {
        guard !isPrivate else { throw ProfileError.privateMode }
        guard !isShuttingDown else { throw CancellationError() }
        guard savingEnabled, let vault else { throw ProfileError.locked }
        var prepared = candidate; prepared.repairProfiles(); prepared.session = Self.repairedSession(prepared.session)
        do { try vault.save(prepared) }
        catch { savingEnabled = false; message = "Couldn’t save profile changes. Your existing tabs and data were kept. \(error.localizedDescription)"; throw error }
        persistedProfileIDs = Set((prepared.profiles ?? []).map(\.id))
        if let spaceID, peekSpaceID == spaceID { closePeek() }
        for id in ids { discardView(id) }
        if spaceID == space.id || ids.contains(where: { $0 == splitID || $0 == selectedID }) { splitID = nil; activePaneID = nil }
        applyDocument(prepared); hasSavedDocument = true
    }
    @discardableResult func createProfile(name: String) throws -> UUID {
        let profile = BrowserProfile(name: name)
        var candidate = makeDocument(); candidate.profiles?.append(profile)
        candidate.setLibrary(BrowserLibrary(), for: profile.id)
        var newSpace = Space(name: profile.name); newSpace.profileID = profile.id
        candidate.session.spaces.append(newSpace); candidate.session.selectedSpace = newSpace.id
        try commitProfileDocument(candidate); closePeek(); splitID = nil; activePaneID = nil
        return profile.id
    }
    func assignProfile(_ id: UUID, to spaceID: UUID) throws {
        guard let profile = profiles.first(where: { $0.id == id }), let index = session.spaces.firstIndex(where: { $0.id == spaceID }) else { throw ProfileError.missing }
        guard !profile.isPendingDeletion, !profile.isPendingClear else { throw ProfileError.pending }
        guard session.spaces[index].effectiveProfileID != id else { return }
        var candidate = makeDocument(); candidate.session.spaces[index].profileID = id
        try commitProfileDocument(candidate, discarding: session.spaces[index].tabs.map(\.id), resetting: spaceID)
    }
    @discardableResult func placeTab(_ id: UUID, in destination: UUID, section: SidebarSection, before target: UUID? = nil, folder: String? = nil, allowProfileChange: Bool = false) -> Bool {
        guard let source = session.spaces.first(where: { $0.tabs.contains(where: { $0.id == id }) }), let dest = session.spaces.first(where: { $0.id == destination }), id != target else { return false }
        let changingProfile = !isPrivate && source.effectiveProfileID != dest.effectiveProfileID
        guard !changingProfile || allowProfileChange else { return false }
        guard isPrivate || profiles.contains(where: { $0.id == dest.effectiveProfileID && !$0.isPendingDeletion && !$0.isPendingClear }) else { return false }
        var candidate = makeDocument(); candidate.session.placeTab(id, in: destination, section: section, before: target)
        if let folder, let s = candidate.session.spaces.firstIndex(where: { $0.id == destination }), let t = candidate.session.spaces[s].tabs.firstIndex(where: { $0.id == id }) { candidate.session.spaces[s].tabs[t].folder = folder }
        if changingProfile {
            do { try commitProfileDocument(candidate, discarding: [id], resetting: source.id) }
            catch { return false }
        } else { session = candidate.session; save() }
        if source.id != dest.id { splitID = nil; activePaneID = nil }
        return true
    }
    func websiteDataStore(forProfile id: UUID) -> WKWebsiteDataStore {
        if let privateDataStore { return privateDataStore }
        guard let profile = profiles.first(where: { $0.id == id }), !profileUnavailable(id),
              id != BrowserProfile.zeroID, persistedProfileIDs.contains(id) else {
            message = "This profile is unavailable. Its website data is preserved; this page uses temporary storage."
            return .nonPersistent()
        }
        if profile.isDefault { return .default() }
        if let existing = namedDataStores[id] { return existing }
        let store = WKWebsiteDataStore(forIdentifier: id); namedDataStores[id] = store; return store
    }
    func createPopup(from opener: WKWebView, configuration: WKWebViewConfiguration) -> WKWebView? {
        let owner = spaceID(for: opener)
        guard let owner, session.spaces.contains(where: { $0.id == owner }) else { return nil }
        let id = newTab(in: owner, activate: owner == space.id)
        return view(for: id, configuration: configuration)
    }
}
