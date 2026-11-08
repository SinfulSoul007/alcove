import AppKit
import WebKit
import BrowserCore

enum ProfileError: LocalizedError {
    case privateMode, locked, missing, pending, inUse, defaultProfile
    var errorDescription: String? {
        switch self {
        case .privateMode: return "Profiles are managed in a normal window."
        case .locked: return "Unlock local data before changing profiles."
        case .missing: return "This profile no longer exists."
        case .pending: return "This profile has an unfinished deletion. Finish or retry it before using the profile."
        case .inUse: return "Move this profile’s Spaces to another profile before deleting it."
        case .defaultProfile: return "The default profile can be cleared but cannot be removed."
        }
    }
}

extension BrowserStore {
    var activeProfileID: UUID { isPrivate ? BrowserProfile.defaultID : space.effectiveProfileID }
    var activeProfile: BrowserProfile { profiles.first(where: { $0.id == activeProfileID }) ?? .defaultProfile }
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
        guard !profile.isPendingDeletion else { throw ProfileError.pending }
        guard session.spaces[index].effectiveProfileID != id else { return }
        var candidate = makeDocument(); candidate.session.spaces[index].profileID = id
        try commitProfileDocument(candidate, discarding: session.spaces[index].tabs.map(\.id), resetting: spaceID)
    }
    @discardableResult func placeTab(_ id: UUID, in destination: UUID, section: SidebarSection, before target: UUID? = nil, folder: String? = nil, allowProfileChange: Bool = false) -> Bool {
        guard let source = session.spaces.first(where: { $0.tabs.contains(where: { $0.id == id }) }), let dest = session.spaces.first(where: { $0.id == destination }), id != target else { return false }
        let changingProfile = !isPrivate && source.effectiveProfileID != dest.effectiveProfileID
        guard !changingProfile || allowProfileChange else { return false }
        guard isPrivate || profiles.contains(where: { $0.id == dest.effectiveProfileID && !$0.isPendingDeletion }) else { return false }
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
        guard let profile = profiles.first(where: { $0.id == id }), !profile.isPendingDeletion,
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
