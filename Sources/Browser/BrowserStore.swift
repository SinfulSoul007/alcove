import AppKit
import SwiftUI
import WebKit
import BrowserCore
import CryptoKit
import Combine

enum BrowserPanel: String, Identifiable { case library, settings, appearance, updates, profiles, siteSearch, links, boosts, spaces; var id: String { rawValue } }

@MainActor
final class BrowserStore: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    @Published var session = Session() { didSet { if boostPicker != nil { reconcileBoostPicker() } } }
    @Published var commandVisible = false {
        didSet {
            if !commandVisible {
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
    @Published var sidebarVisible = true
    @Published var presentedPanel: BrowserPanel?
    @Published var boostPicker: BoostPickerSession?
    @Published var boostEditor: BoostEditor?
    var boostApprovalJobs: [ObjectIdentifier: BoostApprovalJob] = [:]
    var appearanceVisible: Bool { get { presentedPanel == .appearance } set { if newValue { presentedPanel = .appearance } else if appearanceVisible { presentedPanel = nil } } }
    var updatesVisible: Bool { get { presentedPanel == .updates } set { if newValue { presentedPanel = .updates } else if updatesVisible { presentedPanel = nil } } }
    var profilesVisible: Bool { get { presentedPanel == .profiles } set { if newValue { presentedPanel = .profiles } else if profilesVisible { presentedPanel = nil } } }
    @Published var onboardingVisible = false
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

    @Published var splitID: UUID? { didSet { if boostPicker != nil { reconcileBoostPicker() } } }
    @Published var activePaneID: UUID? { didSet { if boostPicker != nil { reconcileBoostPicker() } } }
    @Published var message: String?
    @Published var revision = 0
    @Published var profiles: [BrowserProfile] = [.defaultProfile]
    @Published var profileLibraries: [ProfileLibrary] = [ProfileLibrary(profileID: BrowserProfile.defaultID)]
    var library: BrowserLibrary {
        get { library(for: activeProfileID) }
        set { setLibrary(newValue, for: activeProfileID) }
    }
    @Published var preferences = Preferences() { didSet { siteSearchCatalogCache = nil; linkRuleCatalogCache = nil } }
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
    @Published var peekPages: [PeekContext: PeekState] = [:] { didSet { reconcileSearchInputContext(); if boostPicker != nil { reconcileBoostPicker() } } }
    @Published var siteIcons: [UUID: NSImage] = [:]
    let isPrivate: Bool
    let privateDataStore: WKWebsiteDataStore?
    var extensionReviewEpochs:[UUID:UUID] = [:]
    @Published var extensionInstallationInProgress = false
    var extensionPublication:Task<InstalledExtensionPackage,Error>?
    var extensionMaintenance:Task<Int,Error>?
    var vault: MetadataStore?
    @Published var savingEnabled = true
    @Published var unlocking = false
    @Published var awaitingInitialMetadata = false
    @Published var metadataLoadError: String?
    @Published var profileInUse = false
    var metadataOwnership: MetadataOwnershipLease?
    let metadataKeyAccess: MetadataKeyAccess
    var metadataDidLoad: (() -> Void)?
    var privateWindowRequested: (() -> Void)?
    var downloadIDs: [ObjectIdentifier: UUID] = [:]
    var archiveTimer: Timer?
    var views: [UUID: WKWebView] = [:]
    private let documentIDs = NSMapTable<WKWebView, NSUUID>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    func documentIdentity(for web: WKWebView) -> NSUUID {
        if let identity = documentIDs.object(forKey: web) { return identity }
        let identity = NSUUID(); documentIDs.setObject(identity, forKey: web); return identity
    }
    func invalidateDocumentIdentity(for web: WKWebView) {
        documentIDs.setObject(NSUUID(), forKey: web)
        if boostPicker?.source.web === web { cancelBoostPicker() }
        BoostRuntime.invalidate(web)
    }
    var viewProfileIDs: [UUID: UUID] = [:]
    var namedDataStores: [UUID: WKWebsiteDataStore] = [:]
    var persistedProfileIDs: Set<UUID> = [BrowserProfile.defaultID]
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
    func focusPane(_ id: UUID) { if id == selectedID || id == splitID { activePaneID = id } }

    init(isPrivate: Bool = false, dataRoot: URL? = nil, keyProvider: ((Bool) throws -> SymmetricKey)? = nil, metadataKeyAccess: MetadataKeyAccess? = nil) {
        self.isPrivate = isPrivate
        self.metadataKeyAccess = metadataKeyAccess ?? .shared
        privateDataStore = isPrivate ? .nonPersistent() : nil
        let requestedRoot = dataRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OpenBrowser", isDirectory: true)
        let root = isPrivate ? requestedRoot : requestedRoot.standardizedFileURL.resolvingSymlinksInPath()
        sessionURL = root.appendingPathComponent("session-v2.sealed")
        previousSessionURL = root.appendingPathComponent("session.sealed")
        super.init()
        guard !isPrivate else { return }
        profileOperationSubscription = ProfileDataOperations.shared.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
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
            if value.spaces[i].tabs.isEmpty { value.spaces[i].tabs = [BrowserCore.Tab()] }
            if !value.spaces[i].tabs.contains(where: { $0.id == value.spaces[i].selected }) { value.spaces[i].selected = value.spaces[i].tabs.first?.id }
        }
        return value
    }
    func save() {
        guard !isPrivate, savingEnabled, !isShuttingDown else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }
    func flush() {
        guard !isPrivate, savingEnabled, !isShuttingDown else { return }
        do { if let vault { try vault.save(makeDocument()); hasSavedDocument = true } }
        catch { savingEnabled = false; message = "Couldn’t save your data. Existing data is preserved. \(error.localizedDescription)" }
    }
    func shutdown() {
        guard !isShuttingDown else { return }
        flush(); isShuttingDown = true; extensionPublication?.cancel(); extensionMaintenance?.cancel(); cancelBoostApprovals(); cancelBoostPicker(); cancelLinkReloads(); quickArchiveProbeID = nil; saveTask?.cancel(); saveTask = nil; archiveTimer?.invalidate()
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
        if focusedID != id { dismissCommand() }
        session.spaces[spaceIndex].selected = id; activePaneID = nil
        accessOrder.removeAll { $0 == id }; accessOrder.append(id)
        update(id) { $0.lastAccessed = Date() }
        if activePaneID == id { activePaneID = nil }
        if splitID == id { splitID = nil }
        save()
    }
    func selectSpace(_ id: UUID) {
        guard session.spaces.contains(where: { $0.id == id }) else { return }
        if session.selectedSpace != id { dismissCommand() }
        closePrimaryPeek(); activePaneID = nil; splitID = nil; session.activateSpace(id); save()
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
            update(id) { $0.url = $0.homeURL ?? $0.url; $0.title = $0.pinnedTitle ?? $0.title }; discardView(id); return
        }
        guard let owner = session.spaces.first(where: { $0.tabs.contains(where: { $0.id == id }) })?.id else { return }
        if let tab = tab(id), tab.pinned {
            update(id) { $0.url = $0.homeURL ?? $0.url; $0.title = $0.pinnedTitle ?? $0.title }
            discardView(id)
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
        discardView(id)
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
        if let profile = quickProfileID(id) {
            guard profile == activeProfileID, !profileUnavailable(profile) else { return }
            touchQuickPage(id); quickPageRequested?(id); return
        }
        if favorites.contains(where: { $0.id == id }) { if materializeFavorite(id) { select(id) }; return }
        if let owner = session.spaces.first(where: { $0.tabs.contains(where: { $0.id == id }) }) {
            if owner.id != space.id { selectSpace(owner.id) }; select(id)
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
        guard !awaitingInitialMetadata, !isShuttingDown else { return }
        commandFocusRequest += 1
        commandOpensNewTab = new
        commandSiteSearch = nil; commandError = nil; commandContext = searchInputContext()
        command = new ? "" : (primaryPeekView?.url?.absoluteString ?? currentView?.url?.absoluteString ?? selectedTab?.url ?? ""); commandVisible = true
    }
    func navigate(_ input: String) {
        let editing = commandVisible, new = commandOpensNewTab
        do {
            if editing { guard let context = commandContext, matchesSearchInputContext(context) else { throw SearchInputError.contextChanged } }
            guard !profileUnavailable(activeProfileID), !isShuttingDown else { throw ProfileError.pending }
            let url = try resolveSearchInput(input, selection: editing ? commandSiteSearch : nil)
            let peek = editing && !new ? primaryPeekView : nil
            commandVisible = false
            if let peek { peek.load(URLRequest(url: url)); return }
            if editing && new { closePrimaryPeek() }
            let id = new && selectedTab?.url.isEmpty != true ? newTab() : (focusedID ?? newTab())
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
            let unknown = WKWebView(frame: .zero, configuration: config); unknown.navigationDelegate = self
            return unknown
        }
        config.websiteDataStore = websiteDataStore(forProfile: profile)
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let web = WKWebView(frame: .zero, configuration: config)
        registerView(web, for: id, profile: profile)
        if !profileUnavailable(profile), let value = tab(id)?.url, !value.isEmpty, let url = URL(string: value) { web.load(URLRequest(url: url)) }
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
    }
    func toggleSplit() {
        if splitID != nil { splitID = nil; return }
        splitID = space.tabs.first(where: { $0.id != selectedID && !$0.url.isEmpty })?.id
        if splitID == nil { message = "Open a second website, then choose Split View." }
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let owner = profileID(for: webView), !profileUnavailable(owner), let url = action.request.url else { decisionHandler(.cancel); return }
        guard ["https", "http", "about", "blob", "data"].contains(url.scheme?.lowercased() ?? "") else {
            decisionHandler(.cancel); message = "This prototype only opens web links (http and https)."; return
        }
        if action.navigationType == .linkActivated && action.modifierFlags.contains(.shift) && ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            decisionHandler(.cancel); openPeek(url, from: webView); return
        }
        decisionHandler(action.shouldPerformDownload ? .download : .allow)
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
        if (error as NSError).code != NSURLErrorCancelled { message = error.localizedDescription }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { invalidateDocumentIdentity(for: webView); message = "This page stopped responding. Use Reload to try again." }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        createPopup(from: webView, configuration: configuration)
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
