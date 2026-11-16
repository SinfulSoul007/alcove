import AppKit
import SwiftUI
import WebKit
import BrowserCore
import CryptoKit
import Combine

enum BrowserPanel: String, Identifiable { case library, settings, appearance, updates, profiles, siteSearch, links, boosts, spaces; var id: String { rawValue } }

@MainActor
final class BrowserStore: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    weak var windowGroup: BrowserWindowGroup?
    var windowGroupID: UUID?
    var extensionPopupProfileID: UUID?
    var savedWindowRestore: BrowserWindowRestoreState?
    var metadataWriter: BrowserStore { windowGroup?.root ?? self }
    @Published var session = Session() {
        didSet {
            windowGroup?.sessionDidChange(from: self)
            if boostPicker != nil { reconcileBoostPicker() }
            extensionBrowserStateChanged()
        }
    }
    @Published var commandVisible = false {
        didSet {
            if commandVisible { cancelRecentTabSwitcher() }
            else {
                if commandSiteSearch != nil { commandSiteSearch = nil }
                commandContext = nil
                if commandError != nil { commandError = nil }
                if !command.isEmpty { command = "" }
                commandOpensNewTab = false
            }
        }
    }
    @Published var command = ""
    @Published var commandSiteSearch: SiteSearch?
    var commandContext: SearchInputContext?
    @Published var commandError: String?
    var commandOpensNewTab = false
    private(set) var commandFocusRequest = 0
    @Published var sidebarVisible = true {
        didSet { if oldValue != sidebarVisible { windowGroup?.sidebarLayoutDidChange(in: self) } }
    }
    @Published var windowSidebarWidth: Double? {
        didSet { if oldValue != windowSidebarWidth { windowGroup?.sidebarLayoutDidChange(in: self) } }
    }
    @Published var presentedPanel: BrowserPanel? {
        didSet { if presentedPanel != nil { cancelRecentTabSwitcher() } }
    }
    @Published var boostPicker: BoostPickerSession?
    @Published var boostEditor: BoostEditor?
    var boostApprovalJobs: [ObjectIdentifier: BoostApprovalJob] = [:]
    var appearanceVisible: Bool { get { presentedPanel == .appearance } set { if newValue { presentedPanel = .appearance } else if appearanceVisible { presentedPanel = nil } } }
    var updatesVisible: Bool { get { presentedPanel == .updates } set { if newValue { presentedPanel = .updates } else if updatesVisible { presentedPanel = nil } } }
    var profilesVisible: Bool { get { presentedPanel == .profiles } set { if newValue { presentedPanel = .profiles } else if profilesVisible { presentedPanel = nil } } }
    @Published var onboardingVisible = false
    @Published var recentTabSwitcher: RecentTabSwitcher?
    var hasSavedDocument = false
    @Published var lastSpaceDeletion: DeletedSpaceReference?
    @Published var spacesShowingDeleted = false
    var onboardingDidFinish: (() -> Void)?
    var quickPagesDidChange: (() -> Void)?
    var quickPageRequested: ((UUID) -> Void)?
    var focusedQuickPageID: UUID?
    var quickActivityTimes: [UUID: Date] = [:]
    var quickArchiveProbeID: UUID?
    var linkReloadRequests: [ObjectIdentifier: LinkReloadRequest] = [:]
    var automaticUpdatesDidChange: (() -> Void)?
    func setAutomaticUpdateChecks(_ enabled: Bool) { preferences.automaticUpdateChecks = enabled; save(); automaticUpdatesDidChange?() }
    var appearance: AppearanceSettings {
        get { (preferences.appearance ?? AppearanceSettings()).normalized }
        set { preferences.appearance = newValue.normalized; save() }
    }
    private var cachedTheme: AppearanceTheme?
    var activeTheme: AppearanceTheme {
        let palette = space.customTheme ?? (SidebarTheme(rawValue: space.theme ?? "midnight") ?? .midnight).palette
        if let cachedTheme, cachedTheme.palette == palette { return cachedTheme }
        let theme = AppearanceTheme(palette: palette); cachedTheme = theme; return theme
    }
    func setTheme(_ preset: SidebarTheme) { session.spaces[spaceIndex].theme = preset.rawValue; session.spaces[spaceIndex].customTheme = nil; save() }
    func setCustomTheme(_ theme: CustomTheme) { session.spaces[spaceIndex].customTheme = theme; save() }
    func finishOnboarding() { preferences.onboardingCompleted = true; onboardingVisible = false; flush(); onboardingDidFinish?() }

    @Published var splitID: UUID? { didSet { if boostPicker != nil { reconcileBoostPicker() };extensionBrowserStateChanged() } }
    @Published var activePaneID: UUID? { didSet { if boostPicker != nil { reconcileBoostPicker() };extensionBrowserStateChanged() } }
    @Published var message: String?
    @Published var revision = 0 {didSet {extensionBrowserStateChanged()}}
    @Published var profiles: [BrowserProfile] = [.defaultProfile] {
        didSet { windowGroup?.sharedFieldDidChange(.profiles, from: self) }
    }
    @Published var profileLibraries: [ProfileLibrary] = [ProfileLibrary(profileID: BrowserProfile.defaultID)] {
        didSet { windowGroup?.sharedFieldDidChange(.libraries, from: self) }
    }
    var library: BrowserLibrary {
        get { library(for: activeProfileID) }
        set { setLibrary(newValue, for: activeProfileID) }
    }
    @Published var preferences = Preferences() {
        didSet {
            siteSearchCatalogCache = nil
            linkRuleCatalogCache = nil
            windowGroup?.sharedFieldDidChange(.preferences, from: self)
        }
    }
    var siteSearchCatalogCache: SiteSearchCatalog?
    var linkRuleCatalogCache: LinkRuleCatalog?
    var libraryVisible: Bool { get { presentedPanel == .library } set { if newValue { presentedPanel = .library } else if libraryVisible { presentedPanel = nil } } }
    var settingsVisible: Bool { get { presentedPanel == .settings } set { if newValue { presentedPanel = .settings } else if settingsVisible { presentedPanel = nil } } }
    @Published var findVisible = false
    @Published var findText = ""
    @Published var findResult = ""
    @Published var downloads: [DownloadItem] = []
    @Published var clearingData = false
    @Published var clearingProfileID: UUID?
    @Published var deletingProfileID: UUID?
    var isShuttingDown = false
    @Published var peekPages: [PeekContext: PeekState] = [:] { didSet { reconcileSearchInputContext(); if boostPicker != nil { reconcileBoostPicker() };extensionBrowserStateChanged() } }
    @Published var siteIcons: [UUID: NSImage] = [:]
    let isPrivate: Bool
    let privateDataStore: WKWebsiteDataStore?
    var privateUserContentController:WKUserContentController?
    var privateExtensionReopenJob:PrivateExtensionReopenJob?
    var privateExtensionReopenTimeout:Duration = .seconds(60)
    let extensionOriginPopups = NSHashTable<WKWebView>.weakObjects()
    let extensionPopupOwners = NSMapTable<WKWebView,NSString>(keyOptions:.weakMemory,valueOptions:.strongMemory)
    var extensionReviewEpochs:[UUID:UUID] = [:]
    @Published var extensionInstallationInProgress = false
    var extensionPublication:Task<InstalledExtensionPackage,Error>?
    var extensionMaintenance:Task<Int,Error>?
    private var ownedExtensionHosting: (any BrowserExtensionHosting)? {
        didSet { if oldValue !== ownedExtensionHosting { oldValue?.shutdown() } }
    }
    var extensionHosting: (any BrowserExtensionHosting)? {
        get {
            if let writer = windowGroup?.root, writer !== self, !isShuttingDown { return writer.ownedExtensionHosting }
            return ownedExtensionHosting
        }
        set { ownedExtensionHosting = newValue }
    }
    @Published var extensionStates: [UUID: ExtensionProfileState] = [:] {
        didSet { windowGroup?.extensionStatusDidChange(from: self) }
    }
    @Published var extensionDiagnostics: [UUID: [UUID: [String]]] = [:] {
        didSet { windowGroup?.extensionStatusDidChange(from: self) }
    }
    var extensionNavigationTickets:[UUID:ExtensionNavigationTicket] = [:]
    @Published var extensionNavigationProblem:ExtensionNavigationProblem?
    let extensionStoreID = UUID()
    var extensionPrivateAttachments:[UUID:PrivateExtensionAttachment] = [:]
    var extensionWindows:[ExtensionWindowKind:ExtensionBrowserWindow] = [:]
    var extensionManagers:[UUID:ExtensionManagerWindowController] = [:]
    var extensionPrimaryWindowRequested:(()->Void)?
    var vault: MetadataStore?
    @Published var savingEnabled = true { didSet { windowGroup?.writerStateDidChange(from: self) } }
    @Published var unlocking = false { didSet { windowGroup?.writerStateDidChange(from: self) } }
    @Published var awaitingInitialMetadata = false { didSet { windowGroup?.writerStateDidChange(from: self) } }
    @Published var metadataLoadError: String? { didSet { windowGroup?.writerStateDidChange(from: self) } }
    @Published var profileInUse = false { didSet { windowGroup?.writerStateDidChange(from: self) } }
    var metadataOwnership: MetadataOwnershipLease?
    let metadataKeyAccess: MetadataKeyAccess
    var metadataDidLoad: (() -> Void)?
    var privateWindowRequested: (() -> Void)?
    var downloadIDs: [ObjectIdentifier: UUID] = [:]
    var archiveTimer: Timer?
    var views: [UUID: WKWebView] = [:]
    private let documentIDs = NSMapTable<WKWebView, NSUUID>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    private let presentationIDs = NSMapTable<WKWebView, NSUUID>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    func documentIdentity(for web: WKWebView) -> NSUUID {
        if let identity = documentIDs.object(forKey: web) { return identity }
        let identity = NSUUID(); documentIDs.setObject(identity, forKey: web); return identity
    }
    func presentationIdentity(for web: WKWebView) -> NSUUID {
        if let identity = presentationIDs.object(forKey: web) { return identity }
        let identity = NSUUID()
        presentationIDs.setObject(identity, forKey: web)
        return identity
    }
    func invalidateDocumentIdentity(for web: WKWebView) {
        documentIDs.setObject(NSUUID(), forKey: web)
        reconcilePrivateExtensionReopen()
        cancelInvalidExtensionNavigations()
        extensionHosting?.sourceDocumentChanged(web)
        if boostPicker?.source.web === web { cancelBoostPicker() }
        BoostRuntime.invalidate(web)
    }
    func canMoveView(_ id: UUID, profile: UUID, to destination: BrowserStore) -> Bool {
        guard let web = views[id], viewProfileIDs[id] == profile,
              let group = windowGroup, group === destination.windowGroup,
              !isPrivate, !isShuttingDown, !destination.isShuttingDown,
              !destination.profileUnavailable(profile), destination.profileID(for: id) == profile,
              destination.metadataWriter.matchesBoostWebsiteDataStore(web, profileID: profile),
              destination.views[id] == nil else { return false }
        return true
    }
    func moveView(_ id: UUID, profile: UUID, to destination: BrowserStore) -> Bool {
        guard canMoveView(id, profile: profile, to: destination), let web = views[id] else { return false }
        let icon = siteIcons.removeValue(forKey: id)
        views.removeValue(forKey: id)
        observations.removeValue(forKey: id)
        viewProfileIDs.removeValue(forKey: id)
        accessOrder.removeAll { $0 == id }
        transferDocumentBindings(for: web, to: destination)
        if let icon { destination.siteIcons[id] = icon }
        destination.registerView(web, for: id, profile: profile)
        extensionHosting?.sourceDocumentChanged(web)
        revision += 1
        destination.revision += 1
        return true
    }
    func transferDocumentBindings(for web: WKWebView, to destination: BrowserStore) {
        let identity = documentIdentity(for: web)
        let extensionOrigin = extensionOriginPopups.contains(web)
        let popupOwner = extensionPopupOwners.object(forKey: web)
        documentIDs.removeObject(forKey: web)
        presentationIDs.removeObject(forKey: web)
        extensionOriginPopups.remove(web)
        extensionPopupOwners.removeObject(forKey: web)
        cancelExtensionNavigations(for: web)
        cancelInvalidExtensionNavigations()
        reconcilePrivateExtensionReopen()
        if boostPicker?.source.web === web { cancelBoostPicker() }
        for job in Array(boostApprovalJobs.values) where job.request.source.web === web {
            finishBoostApproval(job, cancelled: true)
        }
        if let host = web.superview as? EdgeToEdgeWebHost { host.removeContent(web) }
        else { web.removeFromSuperview() }
        destination.documentIDs.setObject(identity, forKey: web)
        if extensionOrigin { destination.extensionOriginPopups.add(web) }
        if let popupOwner { destination.extensionPopupOwners.setObject(popupOwner, forKey: web) }
    }
    var viewProfileIDs: [UUID: UUID] = [:]
    var namedDataStores: [UUID: WKWebsiteDataStore] = [:]
    var persistedProfileIDs: Set<UUID> = [BrowserProfile.defaultID] {
        didSet { windowGroup?.writerStateDidChange(from: self) }
    }
    var closingPages: [ClosingProfilePage] = []
    var accessOrder: [UUID] = []
    var observations: [UUID: [NSKeyValueObservation]] = [:]
    private var saveTask: Task<Void, Never>?
    private var profileOperationSubscription: AnyCancellable?
    let sessionURL: URL
    let previousSessionURL: URL
    var spaceIndex: Int { session.spaces.firstIndex { $0.id == session.selectedSpace } ?? 0 }
    var space: Space { session.spaces[spaceIndex] }
    var selectedID: UUID? { space.selected }
    var focusedID: UUID? { activePaneID == splitID && splitID != nil ? splitID : selectedID }
    var selectedTab: BrowserCore.Tab? { space.tabs.first { $0.id == focusedID } }
    var currentView: WKWebView? { focusedID.flatMap { views[$0] } }
    func focusPane(_ id: UUID) {
        guard id == selectedID || id == splitID else { return }
        let previous = focusedID
        activePaneID = id
        if focusedID != previous {
            cancelRecentTabSwitcher()
            recordTabVisit(id)
        }
    }

    init(isPrivate: Bool = false, dataRoot: URL? = nil, keyProvider: ((Bool) throws -> SymmetricKey)? = nil,
         metadataKeyAccess: MetadataKeyAccess? = nil, windowGroup: BrowserWindowGroup? = nil) {
        self.isPrivate = isPrivate
        self.windowGroup = windowGroup
        self.metadataKeyAccess = metadataKeyAccess ?? .shared
        privateDataStore = isPrivate ? .nonPersistent() : nil
        privateUserContentController = isPrivate ? WKUserContentController() : nil
        let requestedRoot = dataRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OpenBrowser", isDirectory: true)
        let root = isPrivate ? requestedRoot : requestedRoot.standardizedFileURL.resolvingSymlinksInPath()
        sessionURL = root.appendingPathComponent("session-v2.sealed")
        previousSessionURL = root.appendingPathComponent("session.sealed")
        super.init()
        guard !isPrivate else { return }
        profileOperationSubscription = ProfileDataOperations.shared.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        if windowGroup != nil { return }
        if let keyProvider {
            do { try acquireMetadataOwnership() }
            catch { metadataOwnershipFailed(error); return }
            do { try restoreInitialMetadata(using: keyProvider(canCreateMetadataKey)) }
            catch { savingEnabled = false; message = "Local data is locked or unreadable. Saving is disabled to preserve it. \(error.localizedDescription)" }
        } else {
            awaitingInitialMetadata = true; savingEnabled = false; persistedProfileIDs = []
            beginInitialMetadataLoad()
        }
    }
    func startArchiveTimer() {
        let writer = metadataWriter
        if writer !== self { writer.startArchiveTimer(); return }
        guard !isShuttingDown, archiveTimer?.isValid != true, !isPrivate || !allQuickPages.isEmpty else { return }
        archiveTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.archiveOldTabs(); self?.archiveInactiveQuickPages() }
        }
    }
    func repairSession() {
        session = Self.repairedSession(session)
    }
    static func repairedSession(_ input: Session) -> Session {
        var value = input
        if value.spaces.isEmpty { value = Session() }
        if !value.spaces.contains(where: { $0.id == value.selectedSpace }) { value.selectedSpace = value.spaces[0].id }
        for i in value.spaces.indices {
            let folders = value.spaces[i].folderNames
            if !folders.isEmpty { value.spaces[i].folders = folders }
            if value.spaces[i].folderParents != nil {
                let parents = SidebarFolderTree(space: value.spaces[i]).parents
                value.spaces[i].folderParents = parents.isEmpty ? nil : parents
            }
            if value.spaces[i].tabs.isEmpty { value.spaces[i].tabs = [BrowserCore.Tab()] }
            if !value.spaces[i].tabs.contains(where: { $0.id == value.spaces[i].selected }) { value.spaces[i].selected = value.spaces[i].tabs.first?.id }
        }
        return value
    }
    func save() {
        guard !isPrivate, savingEnabled, !isShuttingDown else { return }
        let writer = metadataWriter
        if writer !== self { writer.save(); return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }
    func flush() {
        guard !isPrivate, savingEnabled, !isShuttingDown else { return }
        let writer = metadataWriter
        if writer !== self { writer.flush(); return }
        do { if let vault { try vault.save(windowGroup?.persistenceDocument() ?? makeDocument()); hasSavedDocument = true } }
        catch { savingEnabled = false; message = "Couldn’t save your data. Existing data is preserved. \(error.localizedDescription)" }
    }
    func shutdown() {
        guard !isShuttingDown else { return }
        closeExtensionManagers()
        cancelRecentTabSwitcher()
        flush(); isShuttingDown = true; privateExtensionReopenJob?.finish(.failure(ExtensionHostError.closed)); cancelAllExtensionNavigations(); extensionHosting = nil; extensionPublication?.cancel(); extensionMaintenance?.cancel(); cancelBoostApprovals(); cancelBoostPicker(); cancelLinkReloads(); quickArchiveProbeID = nil; saveTask?.cancel(); saveTask = nil; archiveTimer?.invalidate()
        profileOperationSubscription?.cancel(); profileOperationSubscription = nil
        closeAllPeeks(); for id in Array(views.keys) { discardView(id) }; namedDataStores.removeAll()
        metadataOwnership?.release(); metadataOwnership = nil
    }
    func closePrimaryWindowPages() {
        closePrimaryPeek()
        for id in Array(views.keys) where quickProfileID(id) == nil { discardView(id) }
        splitID = nil; activePaneID = nil; presentedPanel = nil; commandVisible = false; findVisible = false
    }
    func select(_ id: UUID) {
        guard session.spaces[spaceIndex].tabs.contains(where: { $0.id == id }) else { return }
        if focusedID != id { dismissCommand(); cancelRecentTabSwitcher() }
        if let windowGroup, !windowGroup.claimPresentation(tabID: id, in: self) { return }
        session.spaces[spaceIndex].selected = id; activePaneID = nil
        recordTabVisit(id)
        if activePaneID == id { activePaneID = nil }
        if splitID == id { splitID = nil }
        save()
    }
    private func recordTabVisit(_ id: UUID) {
        guard (windowGroup?.presentation(tabID: id, in: self) ?? .owned) == .owned else { return }
        accessOrder.removeAll { $0 == id }; accessOrder.append(id)
        update(id) { $0.lastAccessed = Date() }
    }

    func selectSpace(_ id: UUID, recordingVisit: Bool = true) {
        guard session.spaces.contains(where: { $0.id == id && (extensionPopupProfileID == nil || $0.effectiveProfileID == extensionPopupProfileID) }) else { return }
        let switching = session.selectedSpace != id
        if switching { dismissCommand(); cancelRecentTabSwitcher() }
        closePrimaryPeek(); activePaneID = nil; splitID = nil
        session.activateSpace(id)
        if switching, recordingVisit, let selectedID { recordTabVisit(selectedID) }
        save()
    }
    func addSpace() {
        let alert = NSAlert(); alert.messageText = "Create a Space"; alert.informativeText = "Give this collection of tabs a name."
        let field = NSTextField(string: ""); field.placeholderString = "Work, Personal, Research…"; field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field; alert.addButton(withTitle: "Create"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            var newSpace = Space(name: name); newSpace.profileID = activeProfileID; session.spaces.append(newSpace); selectSpace(newSpace.id)
        }
    }
    @discardableResult func newTab(url: URL? = nil, in ownerID: UUID? = nil, activate: Bool = true) -> UUID {
        let tab = BrowserCore.Tab(title: url?.host ?? "New Tab", url: url?.absoluteString ?? "")
        let index = ownerID.flatMap { id in session.spaces.firstIndex(where: { $0.id == id }) } ?? spaceIndex
        session.spaces[index].tabs.append(tab); session.spaces[index].selected = tab.id
        if activate { if session.selectedSpace != session.spaces[index].id { selectSpace(session.spaces[index].id) }; select(tab.id) }
        else { save() }
        return tab.id
    }
    func close(_ id: UUID) {
        if quickPage(id) != nil { do { try closeQuickPage(id) } catch { message = error.localizedDescription }; return }
        if !session.spaces.contains(where: { $0.tabs.contains(where: { $0.id == id }) }), let favorite = tab(id), favorite.favorite == true {
            update(id) { $0.url = $0.homeURL ?? $0.url; $0.title = $0.pinnedTitle ?? $0.title }; discardSharedView(id); return
        }
        guard let owner = session.spaces.first(where: { $0.tabs.contains(where: { $0.id == id }) })?.id else { return }
        if let tab = tab(id), tab.pinned {
            update(id) { $0.url = $0.homeURL ?? $0.url; $0.title = $0.pinnedTitle ?? $0.title }
            discardSharedView(id)
            if activePaneID == id { activePaneID = nil }
        if splitID == id { splitID = nil }
            if let s = session.spaces.firstIndex(where: { $0.id == owner }), session.spaces[s].selected == id {
                if let next = session.spaces[s].tabs.first(where: { $0.id != id && !$0.pinned }) { session.spaces[s].selected = next.id }
                else { let empty = BrowserCore.Tab(); session.spaces[s].tabs.append(empty); session.spaces[s].selected = empty.id }
            }
            save(); return
        }
        if let tab = tab(id), !tab.url.isEmpty {
            let profile = session.spaces.first(where: { $0.id == owner })?.effectiveProfileID ?? BrowserProfile.defaultID
            mutateLibrary(for: profile) { value in value.closedTabs.insert(tab, at: 0); value.closedTabs = Array(value.closedTabs.prefix(30)) }
        }
        if activePaneID == id { activePaneID = nil }
        if splitID == id { splitID = nil }
        discardSharedView(id)
        session.close(id, in: owner)
        if splitID == selectedID { splitID = nil }
        save()
    }
    func togglePin(_ id: UUID) {
        if favorites.contains(where: { $0.id == id }) { _ = materializeFavorite(id) }
        update(id) {
            $0.pinned.toggle()
            if $0.pinned { $0.homeURL = $0.url; $0.pinnedTitle = $0.title }
            else { $0.favorite = nil; $0.folder = nil; $0.homeURL = nil; $0.pinnedTitle = nil }
        }
    }
    func favorites(for profile: UUID) -> [BrowserCore.Tab] {
        library(for: profile).favoriteTabs ?? session.spaces.filter { isPrivate || $0.effectiveProfileID == profile }.flatMap(\.tabs).filter { $0.favorite == true }
    }
    var profileTabs: [BrowserCore.Tab] {
        if extensionPopupProfileID != nil { return extensionPopupTabs }
        let local = session.spaces.filter { isPrivate || $0.effectiveProfileID == activeProfileID }.flatMap(\.tabs)
        let ids = Set(local.map(\.id))
        return local + favorites.filter { !ids.contains($0.id) } + quickPages(for: activeProfileID).map(\.tab)
    }
    var favorites: [BrowserCore.Tab] { favorites(for: activeProfileID) }
    /// Mount a shared Favorite in this Space without changing its profile or native page.
    @discardableResult func materializeFavorite(_ id: UUID) -> Bool {
        guard let favorite = favorites.first(where: { $0.id == id }) else { return false }
        if let source = session.spaces.first(where: { $0.tabs.contains(where: { $0.id == id }) }) {
            guard isPrivate || source.effectiveProfileID == activeProfileID else { return false }
            if source.id == space.id { return true }
            session.close(id, in: source.id)
        }
        session.spaces[spaceIndex].tabs.append(favorite)
        return true
    }
    func selectAny(_ id: UUID) {
        if extensionPopupProfileID != nil { selectExtensionPopupTab(id); return }
        if let profile = quickProfileID(id) {
            guard profile == activeProfileID, !profileUnavailable(profile) else { return }
            touchQuickPage(id); quickPageRequested?(id); return
        }
        if favorites.contains(where: { $0.id == id }) { if materializeFavorite(id) { select(id) }; return }
        if let owner = session.spaces.first(where: { $0.tabs.contains(where: { $0.id == id }) }) {
            if owner.id != space.id { selectSpace(owner.id, recordingVisit: false) }; select(id)
        }
    }
    func toggleFavorite(_ id: UUID) {
        if favorites.contains(where: { $0.id == id }) { _ = materializeFavorite(id) }
        update(id) {
            $0.favorite = !($0.favorite ?? false)
            if $0.favorite == true { $0.pinned = true; $0.homeURL = $0.homeURL ?? $0.url; $0.pinnedTitle = $0.pinnedTitle ?? $0.title }
        }
    }
    func removeFromSidebar(_ id: UUID) {
        if favorites.contains(where: { $0.id == id }) { _ = materializeFavorite(id) }
        update(id) { $0.pinned = false; $0.favorite = nil }; close(id)
    }
    @discardableResult func move(_ id: UUID, to destination: UUID, allowProfileChange: Bool = false) -> Bool {
        guard let source = tab(id) else { return false }
        return placeTab(id, in: destination, section: source.favorite == true ? .favorites : (source.pinned ? .pinned : .today), folder: source.folder, allowProfileChange: allowProfileChange)
    }
    func showCommand(new: Bool = false) {
        guard !awaitingInitialMetadata, !isShuttingDown,
              extensionPopupProfileID == nil || space.effectiveProfileID == extensionPopupProfileID else { return }
        commandFocusRequest += 1
        commandOpensNewTab = new
        commandSiteSearch = nil; commandError = nil; commandContext = searchInputContext()
        command = new ? "" : (primaryPeekView?.url?.absoluteString ?? currentView?.url?.absoluteString ?? selectedTab?.url ?? ""); commandVisible = true
    }
    func navigate(_ input: String) {
        let editing = commandVisible, new = commandOpensNewTab
        do {
            if editing { guard let context = commandContext, matchesSearchInputContext(context) else { throw SearchInputError.contextChanged } }
            guard !profileUnavailable(activeProfileID), !isShuttingDown,
                  extensionPopupProfileID == nil || space.effectiveProfileID == extensionPopupProfileID else { throw ProfileError.pending }
            let url = try resolveSearchInput(input, selection: editing ? commandSiteSearch : nil)
            let peek = editing && !new ? primaryPeekView : nil
            if let peek {
                guard !extensionOriginPopups.contains(peek) else { throw ExtensionHostError.unsupportedWebsitePopup }
                commandVisible = false
                peek.load(URLRequest(url: url))
                return
            }
            if editing && new { closePrimaryPeek() }
            let reusableBlank = selectedTab?.url.isEmpty == true && (currentView.map{!extensionOriginPopups.contains($0)} ?? true)
            let id = new && !reusableBlank ? newTab() : (focusedID ?? newTab())
            if let windowGroup, !windowGroup.claimPresentation(tabID: id, in: self) { throw SearchInputError.contextChanged }
            if !new, let web = views[id], extensionOriginPopups.contains(web) { throw ExtensionHostError.unsupportedWebsitePopup }
            commandVisible = false
            update(id) { $0.url = url.absoluteString; $0.title = url.host ?? "Page" }
            view(for: id).load(URLRequest(url: url))
        } catch {
            if editing { commandError = error.localizedDescription }
            else { message = error.localizedDescription }
        }
    }
    func update(_ id: UUID, change: (inout BrowserCore.Tab) -> Void) {
        guard let profile = profileID(for: id), var value = tab(id) else { return }
        change(&value)
        if let page = quickPage(id) {
            mutateLibrary(for: profile) { records in
                guard let index = records.quickPages?.firstIndex(where: { $0.id == id }) else { return }
                records.quickPages?[index].tab = value
                if page.requestedURL == nil, let url = URL(string: value.url), QuickBrowseRouting.host(for: url) != nil { records.quickPages?[index].requestedURL = value.url }
            }
            save(); return
        }
        for s in session.spaces.indices {
            if let t = session.spaces[s].tabs.firstIndex(where: { $0.id == id }) { session.spaces[s].tabs[t] = value; break }
        }
        var shelf = favorites(for: profile)
        if value.favorite == true {
            if let index = shelf.firstIndex(where: { $0.id == id }) { shelf[index] = value } else { shelf.append(value) }
        } else { shelf.removeAll { $0.id == id } }
        mutateLibrary(for: profile) { $0.favoriteTabs = shelf }; save()
    }
    func tab(_ id: UUID) -> BrowserCore.Tab? {
        session.spaces.flatMap(\.tabs).first { $0.id == id } ?? profileLibraries.compactMap { $0.library.favoriteTabs?.first(where: { $0.id == id }) }.first ?? quickPage(id)?.tab
    }
    func view(for id: UUID, configuration: WKWebViewConfiguration? = nil) -> WKWebView {
        if let existing = views[id] { return existing }
        let config = configuration ?? WKWebViewConfiguration()
        guard let profile = profileID(for: id) else {
            config.websiteDataStore = .nonPersistent()
            configureExtensions(config,profileID:nil)
            let unknown = WKWebView(frame: .zero, configuration: config); unknown.navigationDelegate = self
            return unknown
        }
        config.websiteDataStore = websiteDataStore(forProfile: profile)
        configureExtensions(config,profileID:profile)
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let web = WKWebView(frame: .zero, configuration: config)
        registerView(web, for: id, profile: profile)
        if !profileUnavailable(profile), let value = tab(id)?.url, !value.isEmpty, let url = URL(string: value) {
            if configuration == nil,url.scheme?.lowercased() == "webkit-extension" {restoreSavedExtensionTab(id,url:url,placeholder:web,profileID:profile)}
            else {web.load(URLRequest(url:url))}
        }
        // Keep active and split panes alive; suspended tabs retain their last URL, but lose in-memory page state.
        while preferences.suspendTabs && views.count > 6, let victim = accessOrder.first(where: { $0 != id && $0 != selectedID && $0 != splitID && quickPage($0) == nil && views[$0]?.isLoading == false }) {
            discardView(victim)
        }
        return web
    }
    func registerView(_ web: WKWebView, for id: UUID, profile: UUID) {
        if let previous = views[id], previous !== web { discardView(id) }
        accessOrder.removeAll { $0 == id }; accessOrder.append(id)
        web.allowsBackForwardNavigationGestures = true
        web.isInspectable = false
        web.navigationDelegate = self; web.uiDelegate = self
        views[id] = web
        viewProfileIDs[id] = profile
        BoostRuntime.install(on: web)
        observations[id] = [
            web.observe(\.title, options: [.new]) { [weak self] web, _ in
                Task { @MainActor in guard let self, self.views[id] === web else { return }; self.update(id) {
                        $0.title = web.title ?? web.url?.host ?? "Page"
                        if $0.pinned && ($0.pinnedTitle == nil || $0.pinnedTitle == web.url?.host) { $0.pinnedTitle = $0.title }
                    } }
            },
            web.observe(\.url, options: [.new]) { [weak self] web, _ in
                Task { @MainActor in guard let self, self.views[id] === web else { return }; if let url = web.url { self.update(id) { $0.url = url.absoluteString } } }
            },
            web.observe(\.cameraCaptureState, options: [.new]) { [weak self] web, _ in
                Task { @MainActor in guard let self, self.views[id] === web else { return }; self.revision += 1 }
            },
            web.observe(\.microphoneCaptureState, options: [.new]) { [weak self] web, _ in
                Task { @MainActor in guard let self, self.views[id] === web else { return }; self.revision += 1 }
            },
            web.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.revision += 1 } },
            web.observe(\.isLoading, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.revision += 1 } }
        ]
        extensionBrowserStateChanged()
    }
    func openInSplit(_ id: UUID) {
        guard !isShuttingDown, id != selectedID, space.tabs.contains(where: { $0.id == id && !$0.url.isEmpty }),
              !profileUnavailable(activeProfileID) else { return }
        if let windowGroup, !windowGroup.claimPresentation(tabID: id, in: self) { return }
        splitID = id
    }
    func toggleSplit() {
        if splitID != nil { splitID = nil; return }
        let available = space.tabs.first {
            $0.id != selectedID && !$0.url.isEmpty &&
                (extensionPopupProfileID == nil || windowGroup?.presentation(tabID: $0.id, in: self) == .owned)
        }
        guard let id = available?.id else {
            message = "Open a second website, then choose Split View."
            return
        }
        openInSplit(id)
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.targetFrame?.isMainFrame != false {beginExtensionMainNavigation(webView)}
        guard let owner = profileID(for: webView), !profileUnavailable(owner), let url = action.request.url else { decisionHandler(.cancel); return }
        guard ["https", "http", "about", "blob", "data"].contains(url.scheme?.lowercased() ?? "") || extensionHosting?.allowsExtensionURL(url,profileID:owner) == true else {
            decisionHandler(.cancel); message = "This prototype only opens web links (http and https)."; return
        }
        if action.navigationType == .linkActivated && action.modifierFlags.contains(.shift) && ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            decisionHandler(.cancel); openPeek(url, from: webView); return
        }
        if action.targetFrame?.isMainFrame != false,extensionOriginPopups.contains(webView),["http","https"].contains(url.scheme?.lowercased() ?? "") {
            decisionHandler(.cancel);message = ExtensionHostError.unsupportedWebsitePopup.localizedDescription;return
        }
        if action.targetFrame?.isMainFrame == true,!action.shouldPerformDownload,!extensionOriginPopups.contains(webView),
           webView.url?.scheme?.lowercased() == "webkit-extension",url.scheme?.lowercased() != "webkit-extension",
           views.values.contains(where:{$0 === webView}) || peekContext(for:webView) != nil {
            // Keep the extension document mounted until the same preparation/lifetime gate
            // authorizes its destination. The scoped source view itself cannot leave its origin.
            let document = documentIdentity(for:webView)
            decideExtensionNavigation(webView,request:action.request,isMainFrame:true,allow:.allow) { [weak self,weak webView] policy in
                decisionHandler(.cancel)
                guard policy == .allow,let self,let webView,self.profileID(for:webView) == owner,self.documentIdentity(for:webView) === document else {return}
                guard ExtensionNavigationProblem.canReplay(action.request) else {
                    if let host=self.extensionHosting {
                        let source=ExtensionNavigationSource(store:self,web:webView,host:host,profileID:owner)
                        let problem=ExtensionNavigationProblem(source:source,request:action.request,isMainFrame:true,policy:.allow,error:ExtensionHostError.native("This request cannot move between an extension page and a website."))
                        problem.recoveryNotice="This request was kept in its original page. Open the website in an ordinary tab before submitting a form there."
                        self.extensionNavigationProblem=problem
                    }
                    return
                }
                do {try self.navigateExtensionSurface(webView,to:url,profileID:owner,request:action.request)} catch {self.message = error.localizedDescription}
            }
            return
        }
        decideExtensionNavigation(webView,request:action.request,isMainFrame:action.targetFrame?.isMainFrame != false,allow:action.shouldPerformDownload ? .download : .allow,decision:decisionHandler)
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard let owner = profileID(for: webView), !profileUnavailable(owner) else { decisionHandler(.cancel); return }
        decisionHandler(response.canShowMIMEType ? .allow : .download)
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = URL(fileURLWithPath: suggestedFilename).lastPathComponent
        panel.begin { [weak self] result in
            guard let self, result == .OK, let url = panel.url else { completionHandler(nil); return }
            let item = DownloadItem(name: url.lastPathComponent, status: "Downloading…")
            self.downloads.insert(item, at: 0); self.downloadIDs[ObjectIdentifier(download)] = item.id
            completionHandler(url)
        }
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) { updateDownload(download, status: "Failed: \(error.localizedDescription)"); message = "Download failed: \(error.localizedDescription)" }
    func downloadDidFinish(_ download: WKDownload) { updateDownload(download, status: "Finished"); message = "Download finished." }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if extensionNavigationProblem?.source.web === webView {return}
        if (error as NSError).code != NSURLErrorCancelled { message = error.localizedDescription }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { invalidateDocumentIdentity(for: webView); message = "This page stopped responding. Use Reload to try again." }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        createPopup(from: webView, configuration: configuration,requestedURL:action.request.url)
    }
    func webViewDidClose(_ webView: WKWebView) { if let context = peekContext(for: webView) { closePeek(in: context); return }; if let id = views.first(where: { $0.value === webView })?.key { close(id) } }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert(); alert.messageText = frame.request.url?.host ?? "Website"; alert.informativeText = message; alert.runModal(); completionHandler()
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert(); alert.messageText = frame.request.url?.host ?? "Website"; alert.informativeText = message
        alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Cancel"); completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert(); alert.messageText = prompt
        let field = NSTextField(string: defaultText ?? ""); field.frame = NSRect(x: 0, y: 0, width: 280, height: 24); alert.accessoryView = field
        alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Cancel"); completionHandler(alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
    }
}
