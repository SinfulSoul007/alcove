import WebKit
import BrowserCore

enum ResolvedLinkDestination: Equatable {
    case quick(profileID: UUID), space(spaceID: UUID, profileID: UUID), newSpace(profileID: UUID)
    var profileID: UUID {
        switch self { case .quick(let id), .space(_,let id), .newSpace(let id): return id }
    }
}
struct LinkRoutingDecision: Equatable { let rule: LinkRule?; let destination: ResolvedLinkDestination }
enum LinkRoutingError: LocalizedError {
    case unavailableDestination, contextChanged
    var errorDescription: String? {
        switch self {
        case .unavailableDestination: return "This route's Space is unavailable. Choose another destination in Link Routing Settings."
        case .contextChanged: return "The preview, route or destination changed. Open the preview again before moving it."
        }
    }
}
struct PeekPromotionRequest {
    let context: PeekContext, lifetimeID: UUID, documentID: NSUUID, url: URL, sourceProfileID: UUID, sourceSpaceID: UUID?
    let web: WKWebView, explicitSpaceID: UUID?, decision: LinkRoutingDecision
}

extension BrowserStore {
    var linkRuleCatalog: LinkRuleCatalog {
        if isPrivate { return LinkRuleCatalog(nil) }
        if let linkRuleCatalogCache { return linkRuleCatalogCache }
        let catalog = LinkRuleCatalog(preferences.linkRules); linkRuleCatalogCache = catalog; return catalog
    }
    var canEditLinkRules: Bool { !isPrivate && savingEnabled && !isShuttingDown && !profileDataOperationInProgress }
    var effectiveDefaultLinkDestination: LinkDestination {
        if isPrivate { return .mostRecentSpace }
        return preferences.linkDefaultDestination ?? ((preferences.quickBrowseExternalLinks ?? true) ? .quickBrowse : .mostRecentSpace)
    }
    func requireLinkOpening() throws {
        guard !isShuttingDown else { throw CancellationError() }
        guard isPrivate || savingEnabled else { throw ProfileError.locked }
        guard !profileDataOperationInProgress else { throw ProfileError.busy }
    }
    private func persistLinkPreferences(_ change: (inout Preferences) throws -> Void) throws {
        guard !isPrivate else { throw ProfileError.privateMode }
        try requireLinkOpening()
        var candidate = makeDocument(); try change(&candidate.preferences); try commitProfileDocument(candidate)
    }
    func saveLinkRule(_ rule: LinkRule) throws { try persistLinkPreferences { $0.linkRules = try linkRuleCatalog.upserting(rule) } }
    func removeLinkRule(_ id: UUID) throws { try persistLinkPreferences { $0.linkRules = linkRuleCatalog.removing(id) } }
    func moveLinkRule(_ id: UUID, by offset: Int) throws {
        guard let index = linkRuleCatalog.entries.firstIndex(where:{$0.id == id}) else { throw LinkRuleError.missingRule }
        let (position, overflow) = index.addingReportingOverflow(offset)
        guard !overflow else { throw LinkRuleError.invalidPosition }
        try persistLinkPreferences { $0.linkRules = try linkRuleCatalog.moving(id,to:position) }
    }
    func setDefaultLinkDestination(_ destination: LinkDestination) throws {
        try persistLinkPreferences { $0.linkDefaultDestination = destination; $0.quickBrowseExternalLinks = destination == .quickBrowse }
    }
    func linkDecision(for url: URL, ownerProfileID: UUID? = nil, preferredSpaceID: UUID? = nil, useExternalDefault: Bool = true, explicitDestination: LinkDestination? = nil) throws -> LinkRoutingDecision {
        try requireLinkOpening()
        guard QuickBrowseRouting.host(for:url) != nil else { throw QuickBrowseError.invalidAddress }
        let rule = isPrivate || explicitDestination != nil ? nil : linkRuleCatalog.matching(url)
        let choice = explicitDestination ?? rule?.destination ?? (useExternalDefault && !isPrivate ? effectiveDefaultLinkDestination : nil)
        if case .space(let id) = choice {
            guard let target = session.spaces.first(where:{$0.id == id}) else { throw LinkRoutingError.unavailableDestination }
            let owner = isPrivate ? BrowserProfile.defaultID : target.effectiveProfileID
            try requireQuickProfile(owner)
            return LinkRoutingDecision(rule:rule,destination:.space(spaceID:id,profileID:owner))
        }
        let owner: UUID
        if isPrivate { owner = BrowserProfile.defaultID }
        else if let ownerProfileID { owner = ownerProfileID }
        else if let host = QuickBrowseRouting.host(for:url), let remembered = preferences.quickDomainChoices?.first(where:{RoutingHost.normalized($0.host) == host}) { owner = remembered.profileID }
        else { owner = activeProfileID }
        try requireQuickProfile(owner)
        if choice == .quickBrowse { return LinkRoutingDecision(rule:rule,destination:.quick(profileID:owner)) }
        func validSpace(_ id: UUID?) -> Space? { session.spaces.first { $0.id == id && (isPrivate || $0.effectiveProfileID == owner) } }
        let preferred = choice == nil ? validSpace(preferredSpaceID) : nil
        let recent = validSpace(session.lastUsedSpaces?[owner])
        let current = validSpace(session.selectedSpace)
        if let target = preferred ?? recent ?? current ?? session.spaces.first(where:{isPrivate || $0.effectiveProfileID == owner}) {
            return LinkRoutingDecision(rule:rule,destination:.space(spaceID:target.id,profileID:owner))
        }
        return LinkRoutingDecision(rule:rule,destination:.newSpace(profileID:owner))
    }
    func preparePeekPromotion(in context: PeekContext, to spaceID: UUID? = nil) throws -> PeekPromotionRequest {
        try requireLinkOpening()
        guard let page = peekPages[context], let url = page.web.url ?? page.requestedURL else { throw QuickBrowseError.missing }
        try requireQuickProfile(page.profileID)
        switch context {
        case .primary: guard page.spaceID == space.id, isPrivate || activeProfileID == page.profileID else { throw LinkRoutingError.contextChanged }
        case .quick(let id): guard quickProfileID(id) == page.profileID else { throw LinkRoutingError.contextChanged }
        }
        let decision = try linkDecision(for:url,ownerProfileID:page.profileID,preferredSpaceID:page.spaceID,useExternalDefault:false,explicitDestination:spaceID.map(LinkDestination.space))
        return PeekPromotionRequest(context:context,lifetimeID:page.id,documentID:documentIdentity(for:page.web),url:url,sourceProfileID:page.profileID,sourceSpaceID:page.spaceID,web:page.web,explicitSpaceID:spaceID,decision:decision)
    }
}
