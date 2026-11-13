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

@MainActor final class ClosingProfilePage {
    weak var webView: WKWebView?
    let profileID: UUID
    let extensionIdentifier:String?
    init(_ webView: WKWebView, profileID: UUID,extensionIdentifier:String? = nil) {
        self.webView = webView; self.profileID = profileID
        self.extensionIdentifier = extensionIdentifier ?? (webView.url?.scheme?.lowercased() == "webkit-extension" ? webView.url?.host : nil)
    }
}

enum ProfileError: LocalizedError {
    case privateMode, locked, missing, pending, inUse, defaultProfile, busy, pagesClosing
    var errorDescription: String? {
        switch self {
        case .privateMode: return "Profiles are managed in a normal window."
        case .locked: return "Unlock local data before changing profiles."
        case .missing: return "This profile no longer exists."
        case .pending: return "Finish or retry this profile’s pending data operation before using it."
        case .inUse: return "Move this profile’s Spaces to another profile before deleting it."
        case .defaultProfile: return "The default profile can be cleared but cannot be removed."
        case .busy: return "Another profile data operation is still running."
        case .pagesClosing: return "Some pages are still closing. Try deleting this profile again shortly."
        }
    }
}

extension BrowserStore {
    func deleteProfile(_ id: UUID, removeStore: @escaping @MainActor (UUID) async throws -> Void = { id in
        for attempt in 0..<50 {
            try Task.checkCancellation()
            guard await WKWebsiteDataStore.allDataStoreIdentifiers.contains(id) else {return}
            do {try await WKWebsiteDataStore.remove(forIdentifier:id);return}
            catch {if attempt == 49 {throw error};try await Task.sleep(for:.milliseconds(100))}
        }
    }) async throws {
        guard !isPrivate else { throw ProfileError.privateMode }
        guard deletingProfileID == nil, !clearingData else { throw ProfileError.busy }
        guard id != BrowserProfile.defaultID else { throw ProfileError.defaultProfile }
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { throw ProfileError.missing }
        if #available(macOS 15.4,*),try retainedExtensionNamespaces(profileID:id).contains(where:{ExtensionErasureJobs.holds($0)}) {throw ExtensionErasureError.busy}
        guard !profiles[index].isPendingClear else { throw ProfileError.busy }
        guard !session.spaces.contains(where: { $0.effectiveProfileID == id }) else { throw ProfileError.inUse }
        guard ProfileDataOperations.shared.begin(id) else { throw ProfileError.busy }
        defer { ProfileDataOperations.shared.finish(id) }
        try ExtensionPublicationOwners.begin(sessionURL);defer {ExtensionPublicationOwners.end(sessionURL)}
        let operationLease = try MetadataOwnership.acquire(for:sessionURL);defer {operationLease.release()}
        let extensionControllerID = profiles[index].extensionControllerID,installedExtensions = extensionRecords(profileID:id)
        let extensionNamespaces = try retainedExtensionNamespaces(profileID:id)
        deletingProfileID = id; defer { deletingProfileID = nil }
        var candidate = makeDocument(); candidate.profiles?[index].pendingDeletion = true
        var records = candidate.library(for: id)
        for page in records.quickPages ?? [] { if let archived = archivedQuickTab(page) { records.archive.insert(archived, at: 0) } }
        records.quickPages = []; candidate.setLibrary(records, for: id)
        try commitProfileDocument(candidate)
        closePeeks(forProfile: id)
        for tabID in Array(views.keys) where viewProfileIDs[tabID] == id { discardView(tabID) }
        var erasureDataStore:WKWebsiteDataStore? = extensionNamespaces.isEmpty ? nil : (namedDataStores[id] ?? WKWebsiteDataStore(forIdentifier:id))
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
            if let dataStore = erasureDataStore {try await eraseProfileExtensionData(installedExtensions,profileID:id,controllerIDs:extensionNamespaces,expectedControllerID:extensionControllerID,dataStore:dataStore)}
            erasureDataStore = nil
            try Task.checkCancellation();guard !isShuttingDown else {throw CancellationError()}
            try operationLease.validate()
            try await removeStore(id)
            guard !isShuttingDown else { throw CancellationError() }
        }
        catch { message = "Couldn’t remove this profile’s website data. Its entry and library were kept so you can retry. \(error.localizedDescription)"; throw error }
        var finished = makeDocument()
        finished.profiles?.removeAll { $0.id == id }; finished.profileLibraries?.removeAll { $0.profileID == id }
        do { try commitProfileDocument(finished) }
        catch { message = "Website data was removed, but deletion could not be finalized. Unlock local data and retry; the profile entry was kept."; throw error }
        let packages = extensionPackagesRoot,staging = extensionStagingRoot,libraries = profileLibraries
        try await Task.detached(priority:.utility) {_ = try ExtensionPackage.reconcile(packagesRoot:packages,stagingRoot:staging,libraries:libraries)}.value
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
        if #available(macOS 15.4,*),!isPrivate,try retainedExtensionNamespaces(profileID:id).contains(where:{ExtensionErasureJobs.holds($0)}) {throw ExtensionErasureError.busy}
        if !isPrivate { guard ProfileDataOperations.shared.begin(id) else { throw ProfileError.busy } }
        defer { if !isPrivate { ProfileDataOperations.shared.finish(id) } }
        if !isPrivate { guard savingEnabled, vault != nil, persistedProfileIDs.contains(id) else { throw ProfileError.locked } }
        let extensionControllerID = profiles.first(where:{$0.id == id})?.extensionControllerID
        let installedExtensions = isPrivate ? [] : extensionRecords(profileID:id)
        let extensionNamespaces = isPrivate ? Set<UUID>() : try retainedExtensionNamespaces(profileID:id)
        let operationLease:MetadataOwnershipLease?
        if !isPrivate {
            try ExtensionPublicationOwners.begin(sessionURL)
            do {operationLease = try MetadataOwnership.acquire(for:sessionURL)}
            catch {ExtensionPublicationOwners.end(sessionURL);throw error}
        } else {operationLease = nil}
        defer {if !isPrivate {ExtensionPublicationOwners.end(sessionURL)};operationLease?.release()}
        var candidate = makeDocument(); var affected: [UUID] = []
        let resuming = !isPrivate && profiles.first(where: { $0.id == id })?.isPendingClear == true
        if let index = candidate.profiles?.firstIndex(where: { $0.id == id }) { candidate.profiles?[index].pendingDataClear = true }
        for index in candidate.session.spaces.indices where !resuming && (isPrivate || candidate.session.spaces[index].effectiveProfileID == id) {
            affected += candidate.session.spaces[index].tabs.map(\.id)
            let empty = BrowserCore.Tab(); candidate.session.spaces[index].tabs = [empty]; candidate.session.spaces[index].selected = empty.id
        }
        var records = library(for: id)
        if !resuming {
            affected += (records.quickPages ?? []).map(\.id)
            records.quickPages = []; records.favoriteTabs = []; records.history = []; records.archive = []; records.closedTabs = []; records.deletedSpaces = []
        }
        candidate.setLibrary(records, for: id)
        if isPrivate { try commitQuickDocument(candidate, discarding: affected, beforePublish: { self.splitID = nil; self.activePaneID = nil }) }
        else { try commitProfileDocument(candidate, discarding: affected, resetting: activeProfileID == id ? space.id : nil) }
        closePeeks(forProfile: id)
        clearingData = true; clearingProfileID = id
        defer { clearingData = false; clearingProfileID = nil }
        // This path is deliberately allowed to access a pending-clear store for removal only.
        let dataStore: WKWebsiteDataStore
        if let privateDataStore { dataStore = privateDataStore }
        else if id == BrowserProfile.defaultID { dataStore = .default() }
        else if let cached = namedDataStores[id] { dataStore = cached }
        else { let created = WKWebsiteDataStore(forIdentifier: id); namedDataStores[id] = created; dataStore = created }
        do {
            if !isPrivate {try await eraseProfileExtensionData(installedExtensions,profileID:id,controllerIDs:extensionNamespaces,expectedControllerID:extensionControllerID,dataStore:dataStore)}
            try Task.checkCancellation();guard !isShuttingDown else {throw CancellationError()}
            try operationLease?.validate()
            try await removeData(dataStore)
        }
        catch { message = "Website clearing did not finish. This profile remains paused so you can retry safely. \(error.localizedDescription)"; throw error }
        guard !isShuttingDown else { throw CancellationError() }
        for tabID in Array(views.keys) where viewProfileIDs[tabID] == id { discardView(tabID) }
        if !isPrivate {
            var finished = makeDocument()
            if let index = finished.profiles?.firstIndex(where: { $0.id == id }) {
                finished.profiles?[index].pendingDataClear = false
                finished.profiles?[index].extensionControllerID = UUID()
            }
            finished.preferences.quickDomainChoices?.removeAll { $0.profileID == id }
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
        if isPrivate { return tab(tabID) == nil ? nil : BrowserProfile.defaultID }
        return session.spaces.first(where: { $0.tabs.contains(where: { $0.id == tabID }) })?.effectiveProfileID ?? profileLibraries.first(where: { $0.library.favoriteTabs?.contains(where: { $0.id == tabID }) == true })?.profileID ?? quickProfileID(tabID)
    }
    func profileID(for web: WKWebView) -> UUID? {
        if let peek = peekState(for: web) { return peek.profileID }
        return views.first(where: { $0.value === web }).flatMap { viewProfileIDs[$0.key] }
    }
    func spaceID(for web: WKWebView) -> UUID? {
        if let peek = peekState(for: web) { return peek.spaceID }
        guard let id = views.first(where: { $0.value === web })?.key else { return nil }
        if let quick = quickPage(id), let profile = quickProfileID(id) {
            return session.spaces.first(where: { $0.id == quick.intendedSpaceID && (isPrivate || $0.effectiveProfileID == profile) })?.id
        }
        return session.spaces.first(where: { $0.tabs.contains(where: { $0.id == id }) })?.id
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
        var entries = profileLibraries
        for index in entries.indices { entries[index].library.quickPages = entries[index].library.quickPages?.map(effectiveQuickPage) }
        return BrowserDocument(session: session, library: entries.first(where: { $0.profileID == BrowserProfile.defaultID })?.library ?? BrowserLibrary(), preferences: preferences, profiles: profiles, profileLibraries: entries)
    }
    func applyDocument(_ document: BrowserDocument) throws {
        var prepared = document; try prepared.repairProfiles()
        invalidateExtensionReviewEpochs(from:profiles,to:prepared.profiles ?? [])
        session = Self.repairedSession(prepared.session); profiles = prepared.profiles ?? [.defaultProfile]
        profileLibraries = prepared.profileLibraries ?? [ProfileLibrary(profileID: BrowserProfile.defaultID, library: prepared.library)]
        preferences = prepared.preferences; reconcileSearchInputContext(); pruneQuickActivity(); quickPagesDidChange?(); refreshBoosts(); extensionHosting?.refresh(); cancelInvalidExtensionNavigations()
    }
    func commitProfileDocument(_ candidate: BrowserDocument, discarding ids: [UUID] = [], resetting spaceID: UUID? = nil, beforePublish: (() -> Void)? = nil) throws {
        guard !isPrivate else { throw ProfileError.privateMode }
        guard !isShuttingDown else { throw CancellationError() }
        guard savingEnabled, let vault else { throw ProfileError.locked }
        var prepared = candidate; try prepared.repairProfiles(); prepared.session = Self.repairedSession(prepared.session)
        do { try vault.save(prepared) }
        catch { savingEnabled = false; message = "Couldn’t save profile changes. Your existing tabs and data were kept. \(error.localizedDescription)"; throw error }
        persistedProfileIDs = Set((prepared.profiles ?? []).map(\.id))
        let retained = Set(prepared.session.spaces.flatMap(\.tabs).map(\.id))
        let nextQuick = Set((prepared.profileLibraries ?? []).flatMap { $0.library.quickPages ?? [] }.map(\.id))
        let removedQuick = Set(allQuickPages.map(\.id)).subtracting(nextQuick).subtracting(retained)
        for id in Set(ids).union(removedQuick) { discardView(id) }
        beforePublish?()
        reconcilePeeks(in: prepared, resetting: spaceID)
        if spaceID == space.id || ids.contains(where: { $0 == splitID || $0 == selectedID }) { splitID = nil; activePaneID = nil }
        try applyDocument(prepared); hasSavedDocument = true
    }
    @discardableResult func createProfile(name: String) throws -> UUID {
        let profile = BrowserProfile(name: name)
        var candidate = makeDocument(); candidate.profiles?.append(profile)
        candidate.setLibrary(BrowserLibrary(), for: profile.id)
        var newSpace = Space(name: profile.name); newSpace.profileID = profile.id
        candidate.session.spaces.append(newSpace); candidate.session.activateSpace(newSpace.id)
        try commitProfileDocument(candidate); closePrimaryPeek(); splitID = nil; activePaneID = nil
        return profile.id
    }
    func assignProfile(_ id: UUID, to spaceID: UUID) throws {
        guard let profile = profiles.first(where: { $0.id == id }), let index = session.spaces.firstIndex(where: { $0.id == spaceID }) else { throw ProfileError.missing }
        guard !profile.isPendingDeletion, !profile.isPendingClear else { throw ProfileError.pending }
        guard session.spaces[index].effectiveProfileID != id else { return }
        var candidate = makeDocument()
        candidate.session.spaces[index].tabs.removeAll { $0.favorite == true }
        candidate.session.spaces[index].profileID = id
        try commitProfileDocument(candidate, discarding: session.spaces[index].tabs.map(\.id), resetting: spaceID)
    }
    @discardableResult func placeTab(_ id: UUID, in destination: UUID, section: SidebarSection, before target: UUID? = nil, folder: String? = nil, allowProfileChange: Bool = false) -> Bool {
        guard canModifyLocalMetadata,!isShuttingDown,!profileDataOperationInProgress else {return false}
        guard let sourceProfile = profileID(for: id), let original = tab(id), let dest = session.spaces.first(where: { $0.id == destination }), id != target else { return false }
        let source = session.spaces.first(where: { $0.tabs.contains(where: { $0.id == id }) })
        let changingProfile = !isPrivate && sourceProfile != dest.effectiveProfileID
        guard !changingProfile || allowProfileChange else { return false }
        guard isPrivate || (profiles.contains(where: { $0.id == dest.effectiveProfileID && !$0.isPendingDeletion && !$0.isPendingClear }) && !profileUnavailable(sourceProfile)) else { return false }
        var candidate = makeDocument()
        if source == nil, let index = candidate.session.spaces.firstIndex(where: { $0.id == destination }) { candidate.session.spaces[index].tabs.append(original) }
        candidate.session.placeTab(id, in: destination, section: section, before: target)
        guard let s = candidate.session.spaces.firstIndex(where: { $0.id == destination }), let t = candidate.session.spaces[s].tabs.firstIndex(where: { $0.id == id }) else { return false }
        if let folder {
            candidate.session.spaces[s].tabs[t].folder = folder
            candidate.session.spaces[s].folders = candidate.session.spaces[s].folderNames
        }
        let placed = candidate.session.spaces[s].tabs[t]
        var oldLibrary = candidate.library(for: sourceProfile); oldLibrary.favoriteTabs = favorites(for: sourceProfile).filter { $0.id != id }
        candidate.setLibrary(oldLibrary, for: sourceProfile)
        var newLibrary = candidate.library(for: dest.effectiveProfileID)
        var shelf = (sourceProfile == dest.effectiveProfileID ? oldLibrary.favoriteTabs : newLibrary.favoriteTabs) ?? []
        if placed.favorite == true {
            if let target, let index = shelf.firstIndex(where: { $0.id == target }) { shelf.insert(placed, at: index) } else { shelf.append(placed) }
        }
        newLibrary.favoriteTabs = shelf; candidate.setLibrary(newLibrary, for: dest.effectiveProfileID)
        do {
            if changingProfile {try commitProfileDocument(candidate,discarding:[id],resetting:source?.id)}
            else {try commitQuickDocument(candidate)}
        } catch {message = error.localizedDescription;return false}
        if source?.id != dest.id { splitID = nil; activePaneID = nil }
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
    func createPopup(from opener: WKWebView, configuration: WKWebViewConfiguration,requestedURL:URL? = nil) -> WKWebView? {
        guard let profile = profileID(for:opener),!isShuttingDown,!profileUnavailable(profile) else {return nil}
        let extensionOrigin = opener.url?.scheme?.lowercased() == "webkit-extension" || extensionOriginPopups.contains(opener)
        let extensionOwner = extensionPopupOwners.object(forKey:opener).map{String($0)} ?? (opener.url?.scheme?.lowercased() == "webkit-extension" ? opener.url?.host : nil)
        if extensionOrigin,["http","https"].contains(requestedURL?.scheme?.lowercased() ?? "") {
            message = ExtensionHostError.unsupportedWebsitePopup.localizedDescription;return nil
        }
        func finish(_ web:WKWebView?) -> WKWebView? {
            if extensionOrigin,let web {
                extensionOriginPopups.add(web)
                if let extensionOwner {extensionPopupOwners.setObject(extensionOwner as NSString,forKey:web)}
            }
            return web
        }
        if let context = quickContext(for: opener) {
            do {
                let id = try openQuickPage(profileID: context.profileID, intendedSpaceID: context.intendedSpaceID, configuration: configuration)
                return finish(views[id])
            } catch { message = error.localizedDescription; return nil }
        }
        let owner = spaceID(for: opener)
        guard let owner, session.spaces.contains(where: { $0.id == owner }) else { return nil }
        let id = newTab(in: owner, activate: owner == space.id)
        return finish(view(for: id, configuration: configuration))
    }
}
