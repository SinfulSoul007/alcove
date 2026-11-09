import WebKit
import BrowserCore

struct PreservedPrimaryPeek {
    let page: PeekState, tabID: UUID
}
extension BrowserStore {
    func preservePrimaryPeek(in candidate: inout BrowserDocument, excluding source: PeekContext? = nil) throws -> PreservedPrimaryPeek? {
        guard source != .primary, let page = peekPages[.primary] else { return nil }
        try requireQuickProfile(page.profileID)
        guard let index = candidate.session.spaces.firstIndex(where:{$0.id == page.spaceID && (isPrivate || $0.effectiveProfileID == page.profileID)}),
              let url = page.web.url ?? page.requestedURL, QuickBrowseRouting.host(for:url) != nil else { throw LinkRoutingError.contextChanged }
        let tab = BrowserCore.Tab(title:page.web.title ?? url.host ?? "Page",url:url.absoluteString)
        candidate.session.spaces[index].tabs.append(tab)
        return PreservedPrimaryPeek(page:page,tabID:tab.id)
    }
    func publishPreservedPeek(_ preserved: PreservedPrimaryPeek?) {
        guard let preserved else { return }
        peekPages.removeValue(forKey:.primary); preserved.page.observations = []
        preserved.page.web.removeFromSuperview(); registerView(preserved.page.web,for:preserved.tabID,profile:preserved.page.profileID)
    }
    func linkSpaceIndex(_ destination: ResolvedLinkDestination, in candidate: inout BrowserDocument) throws -> Int {
        switch destination {
        case .space(let id, let profile):
            guard let index = candidate.session.spaces.firstIndex(where:{$0.id == id && (isPrivate || $0.effectiveProfileID == profile)}) else { throw LinkRoutingError.unavailableDestination }; return index
        case .newSpace(let profile):
            var target = Space(name:profiles.first(where:{$0.id == profile})?.name ?? "Personal",tabs:[]); target.profileID = profile
            candidate.session.spaces.append(target); return candidate.session.spaces.count - 1
        case .quick: throw LinkRoutingError.unavailableDestination
        }
    }
    func insertLinkTab(_ tab: BrowserCore.Tab, at index: Int, in candidate: inout BrowserDocument) -> [UUID] {
        var discard: [UUID] = []
        if candidate.session.spaces[index].tabs.count == 1, let blank = candidate.session.spaces[index].tabs.first, blank.url.isEmpty && !blank.pinned {
            discard = [blank.id]; candidate.session.spaces[index].tabs = []
        }
        candidate.session.spaces[index].tabs.append(tab); candidate.session.spaces[index].selected = tab.id
        candidate.session.activateSpace(candidate.session.spaces[index].id); return discard
    }
    @discardableResult func openRoutedExternal(_ url: URL) throws -> ExternalLinkDestination {
        guard !isPrivate else { throw BrowserWindowOwnerError.privateDispatch }
        let decision = try linkDecision(for:url)
        if case .quick(let profile) = decision.destination { return .quick(try openQuickPage(url:url,profileID:profile)) }
        var candidate = makeDocument()
        let preserved = try preservePrimaryPeek(in:&candidate)
        let index = try linkSpaceIndex(decision.destination,in:&candidate)
        let tab = BrowserCore.Tab(title:url.host ?? "Page",url:url.absoluteString)
        let discard = insertLinkTab(tab,at:index,in:&candidate), targetID = candidate.session.spaces[index].id
        try commitQuickDocument(candidate,discarding:discard,beforePublish:{
            self.publishPreservedPeek(preserved); self.splitID = nil; self.activePaneID = nil
        })
        return .space(targetID)
    }
    @discardableResult func restoreArchivedRouted(_ id: UUID, profileID: UUID) throws -> UUID {
        try requireLinkOpening()
        let owner = isPrivate ? BrowserProfile.defaultID : profileID; try requireQuickProfile(owner)
        var candidate = makeDocument(), records = candidate.library(for:owner)
        guard let position = records.archive.firstIndex(where:{$0.id == id}), case var tab = records.archive[position],
              let url = URL(string:tab.url), QuickBrowseRouting.host(for:url) != nil else { throw QuickBrowseError.missing }
        let decision = try linkDecision(for:url,ownerProfileID:owner,preferredSpaceID:tab.archivedSpaceID,useExternalDefault:false)
        records.archive.remove(at:position); candidate.setLibrary(records,for:owner)
        tab.id = UUID(); tab.lastAccessed = Date(); tab.pinned = false; tab.favorite = nil; tab.folder = nil; tab.homeURL = nil; tab.pinnedTitle = nil; tab.archiveSource = nil; tab.archivedSpaceID = nil
        if case .quick(let target) = decision.destination {
            var targetRecords = candidate.library(for:target)
            let existing = targetRecords.quickPages?.first(where:{$0.tab.url == tab.url || $0.requestedURL == tab.url})
            if existing == nil { targetRecords.quickPages = (targetRecords.quickPages ?? []) + [QuickPage(tab:tab,intendedSpaceID:nil)] }
            candidate.setLibrary(targetRecords,for:target); try commitQuickDocument(candidate)
            let result = existing?.id ?? tab.id; startArchiveTimer(); quickPageRequested?(result); return result
        }
        let preserved = try preservePrimaryPeek(in:&candidate), index = try linkSpaceIndex(decision.destination,in:&candidate)
        let discard = insertLinkTab(tab,at:index,in:&candidate)
        try commitQuickDocument(candidate,discarding:discard,beforePublish:{ self.publishPreservedPeek(preserved); self.splitID = nil; self.activePaneID = nil })
        return tab.id
    }
    @discardableResult func performPeekPromotion(_ request: PeekPromotionRequest, allowProfileChange: Bool = false) throws -> UUID {
        let current = try preparePeekPromotion(in:request.context,to:request.explicitSpaceID)
        guard current.lifetimeID == request.lifetimeID, current.web === request.web, current.documentID === request.documentID,
              current.url == request.url, current.sourceProfileID == request.sourceProfileID, current.sourceSpaceID == request.sourceSpaceID,
              current.decision == request.decision, let page = peekPages[request.context] else { throw LinkRoutingError.contextChanged }
        let targetProfile = current.decision.destination.profileID, crossing = targetProfile != page.profileID
        guard !crossing || allowProfileChange else { throw QuickBrowseError.consentRequired }
        var candidate = makeDocument()
        let tab = BrowserCore.Tab(title:page.web.title ?? current.url.host ?? "Page",url:current.url.absoluteString)
        let preserving: PreservedPrimaryPeek?, discard: [UUID]
        if case .quick(let owner) = current.decision.destination {
            var records = candidate.library(for:owner)
            records.quickPages = (records.quickPages ?? []) + [QuickPage(tab:tab,intendedSpaceID:page.spaceID)]
            candidate.setLibrary(records,for:owner); preserving = nil; discard = []
        } else {
            preserving = try preservePrimaryPeek(in:&candidate,excluding:request.context)
            let index = try linkSpaceIndex(current.decision.destination,in:&candidate); discard = insertLinkTab(tab,at:index,in:&candidate)
        }
        if !isPrivate {
            var records = candidate.library(for:targetProfile); records.record(title:tab.title,url:tab.url); candidate.setLibrary(records,for:targetProfile)
        }
        try commitQuickDocument(candidate,discarding:discard,beforePublish:{
            self.publishPreservedPeek(preserving)
            if crossing { self.closePeek(in:request.context) }
            else {
                self.peekPages.removeValue(forKey:request.context); page.observations = []
                page.web.removeFromSuperview(); self.registerView(page.web,for:tab.id,profile:targetProfile)
            }
            if case .quick = current.decision.destination {} else { self.splitID = nil; self.activePaneID = nil }
        })
        if !crossing { loadSiteIcon(page.web) }
        if case .quick = current.decision.destination { startArchiveTimer(); quickPageRequested?(tab.id) }
        return tab.id
    }
}
