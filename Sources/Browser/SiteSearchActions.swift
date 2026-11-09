import WebKit
import BrowserCore

enum SearchInputContext: Equatable {
    case primary(spaceID: UUID, profileID: UUID, tabID: UUID?, peekID: ObjectIdentifier?)
    case quick(pageID: UUID, profileID: UUID, peekID: ObjectIdentifier?)
}
enum SearchInputError: LocalizedError {
    case contextChanged
    var errorDescription: String? { "The page or profile changed. Open the address field again before searching." }
}

extension BrowserStore {
    var siteSearchCatalog: SiteSearchCatalog {
        if let siteSearchCatalogCache { return siteSearchCatalogCache }
        let catalog = SiteSearchCatalog(preferences.siteSearches); siteSearchCatalogCache = catalog; return catalog
    }
    var canEditSiteSearches: Bool { canModifyLocalMetadata && !isShuttingDown && !profileDataOperationInProgress }
    func saveSiteSearch(_ site: SiteSearch) throws { try persistSiteSearches(siteSearchCatalog.upserting(site)) }
    func removeSiteSearch(_ id: UUID) throws { try persistSiteSearches(siteSearchCatalog.removing(id)) }
    private func persistSiteSearches(_ entries: [SiteSearch]) throws {
        guard !isShuttingDown else { throw CancellationError() }
        guard isPrivate || savingEnabled else { throw ProfileError.locked }
        guard !profileDataOperationInProgress else { throw ProfileError.busy }
        if isPrivate { preferences.siteSearches = entries; return }
        var candidate = makeDocument(); candidate.preferences.siteSearches = entries
        try commitProfileDocument(candidate)
    }
    func searchInputContext(quickID: UUID? = nil) -> SearchInputContext? {
        guard !isShuttingDown else { return nil }
        if let id = quickID {
            guard let profile = quickProfileID(id), !profileUnavailable(profile) else { return nil }
            let peek = peekPages[.quick(id)]
            guard peek == nil || peek?.profileID == profile else { return nil }
            return .quick(pageID: id, profileID: profile, peekID: peek.map { ObjectIdentifier($0.web) })
        }
        let profile = activeProfileID, peek = peekPages[.primary]
        guard !profileUnavailable(profile), peek == nil || (peek?.profileID == profile && peek?.spaceID == space.id) else { return nil }
        guard peek != nil || focusedID.flatMap({ profileID(for: $0) }) == profile else { return nil }
        return .primary(spaceID: space.id, profileID: profile, tabID: focusedID, peekID: peek.map { ObjectIdentifier($0.web) })
    }
    func matchesSearchInputContext(_ context: SearchInputContext) -> Bool {
        switch context {
        case .primary: return searchInputContext() == context
        case .quick(let id, _, _): return searchInputContext(quickID: id) == context
        }
    }
    func resolveSearchInput(_ input: String, selection: SiteSearch?) throws -> URL {
        if let selection {
            guard selection.enabled, siteSearchCatalog.entries.contains(selection) else { throw SiteSearchError.configurationChanged }
            return try selection.url(for: input)
        }
        guard let url = Address.resolve(input) else { throw QuickBrowseError.invalidAddress }
        return url
    }
    @discardableResult func activateCommandSiteSearch(_ site: SiteSearch) -> Bool {
        guard commandVisible, let context = commandContext, matchesSearchInputContext(context),
              site.enabled, siteSearchCatalog.entries.contains(site) else { return false }
        commandSiteSearch = site; command = ""; commandError = nil; return true
    }
    func leaveCommandSiteSearch(restoreKeyword: Bool) {
        if restoreKeyword, let site = commandSiteSearch { command = site.keyword }
        commandSiteSearch = nil; commandError = nil
    }
    @discardableResult func activatePreferredCommandSiteSearch() -> Bool {
        guard commandSiteSearch == nil, let site = siteSearchCatalog.preferredMatch(command) else { return false }
        return activateCommandSiteSearch(site)
    }
    @discardableResult func deleteEmptyCommandSiteSearch() -> Bool {
        guard command.isEmpty, commandSiteSearch != nil else { return false }
        leaveCommandSiteSearch(restoreKeyword: true); return true
    }
    func submitCommandInput() { if commandVisible { navigate(command) } }
    func dismissCommand() {
        guard commandVisible || commandSiteSearch != nil || commandContext != nil || commandError != nil || !command.isEmpty || commandOpensNewTab else { return }
        commandVisible = false
    }
    func reconcileSearchInputContext() {
        if let context = commandContext, !matchesSearchInputContext(context) { dismissCommand() }
    }
}
