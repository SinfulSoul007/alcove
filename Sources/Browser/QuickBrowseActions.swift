import WebKit
import BrowserCore

struct QuickActionSnapshot {
    let id: UUID
    let profileID: UUID
    let url: String
    let viewID: ObjectIdentifier?
}

extension BrowserStore {
    var primaryPeekView: WKWebView? { peekParentQuickID == nil ? peekView : nil }
    func isFocusedWebsite(_ web: WKWebView) -> Bool {
        guard !isShuttingDown, let window = web.window,
              window.isKeyWindow || window.attachedSheet?.isKeyWindow == true,
              let profile = profileID(for: web), !profileUnavailable(profile) else { return false }
        if let context = quickContext(for: web) {
            if peekParentQuickID == context.id, let peekView { return web === peekView }
            return views[context.id] === web
        }
        guard presentedPanel == nil, !commandVisible, !onboardingVisible else { return false }
        if let primaryPeekView { return web === primaryPeekView && peekSpaceID == space.id }
        return web === currentView
    }
    func focusProfileSpace(_ profileID: UUID) throws {
        let profile = isPrivate ? BrowserProfile.defaultID : profileID
        try requireQuickProfile(profile)
        if let target = session.spaces.first(where: { isPrivate || $0.effectiveProfileID == profile }) { selectSpace(target.id); return }
        var candidate = makeDocument()
        var target = Space(name: profiles.first { $0.id == profile }?.name ?? "Personal")
        target.profileID = profile; candidate.session.spaces.append(target); candidate.session.selectedSpace = target.id
        try commitQuickDocument(candidate, beforePublish: { self.closePrimaryPeek(); self.splitID = nil; self.activePaneID = nil })
    }
    func bookmarkWebsite(_ web: WKWebView) throws {
        guard !isPrivate else { throw ProfileError.privateMode }
        guard let profile = profileID(for: web), let url = web.url, QuickBrowseRouting.host(for: url) != nil else { throw QuickBrowseError.missing }
        try requireQuickProfile(profile)
        var candidate = makeDocument(); var records = candidate.library(for: profile)
        records.bookmark(title: web.title ?? url.absoluteString, url: url.absoluteString); candidate.setLibrary(records, for: profile)
        try commitQuickDocument(candidate); message = "Bookmark saved."
    }
    func quickActionSnapshot(_ id: UUID) -> QuickActionSnapshot? {
        guard let profile = quickProfileID(id), let page = quickPage(id) else { return nil }
        return QuickActionSnapshot(id: id, profileID: profile, url: page.tab.url, viewID: views[id].map(ObjectIdentifier.init))
    }
    func matchesQuickAction(_ snapshot: QuickActionSnapshot) -> Bool {
        !isShuttingDown && quickProfileID(snapshot.id) == snapshot.profileID && !profileUnavailable(snapshot.profileID)
            && quickPage(snapshot.id)?.tab.url == snapshot.url && views[snapshot.id].map(ObjectIdentifier.init) == snapshot.viewID
    }
    func openExternalPage(_ url: URL) throws -> ExternalLinkDestination {
        guard !isPrivate else { throw BrowserWindowOwnerError.privateDispatch }
        guard QuickBrowseRouting.host(for: url) != nil else { throw QuickBrowseError.invalidAddress }
        let available = Set(profiles.filter { !profileUnavailable($0.id) }.map(\.id))
        guard let profile = QuickBrowseRouting.profile(for: url, choices: preferences.quickDomainChoices ?? [], available: available, fallback: activeProfileID) else { throw ProfileError.pending }
        try requireQuickProfile(profile)
        if preferences.quickBrowseExternalLinks ?? true { return .quick(try openQuickPage(url: url, profileID: profile)) }
        // The opt-out creates its Space/tab in a single durable transition.
        var candidate = makeDocument()
        let index: Int
        if activeProfileID == profile { index = spaceIndex }
        else if let found = candidate.session.spaces.firstIndex(where: { $0.effectiveProfileID == profile }) { index = found }
        else {
            var target = Space(name: profiles.first { $0.id == profile }?.name ?? "Personal", tabs: [])
            target.profileID = profile; candidate.session.spaces.append(target); index = candidate.session.spaces.count - 1
        }
        let tab = BrowserCore.Tab(title: url.host ?? "Page", url: url.absoluteString)
        var discard: [UUID] = []
        if candidate.session.spaces[index].tabs.count == 1, let blank = candidate.session.spaces[index].tabs.first, blank.url.isEmpty && !blank.pinned {
            discard = [blank.id]; candidate.session.spaces[index].tabs = []
        }
        candidate.session.spaces[index].tabs.append(tab); candidate.session.spaces[index].selected = tab.id
        let spaceID = candidate.session.spaces[index].id; candidate.session.selectedSpace = spaceID
        try commitQuickDocument(candidate, discarding: discard, beforePublish: {
            self.closePrimaryPeek(); self.splitID = nil; self.activePaneID = nil
        })
        return .space(spaceID)
    }
    func bookmarkQuickPage(_ id: UUID) throws {
        guard !isPrivate else { throw ProfileError.privateMode }
        guard let profile = quickProfileID(id), let page = quickPage(id), let url = URL(string: page.tab.url), QuickBrowseRouting.host(for: url) != nil else { throw QuickBrowseError.missing }
        try requireQuickProfile(profile)
        var candidate = makeDocument(); var records = candidate.library(for: profile)
        records.bookmark(title: page.tab.title, url: page.tab.url); candidate.setLibrary(records, for: profile)
        try commitQuickDocument(candidate); message = "Bookmark saved."
    }
    @discardableResult func restoreQuickArchiveInSpace(_ id: UUID, profileID: UUID) throws -> UUID {
        let profile = isPrivate ? BrowserProfile.defaultID : profileID
        try requireQuickProfile(profile)
        var candidate = makeDocument(); var records = candidate.library(for: profile)
        guard let archived = records.archive.firstIndex(where: { $0.id == id && $0.archiveSource == "quickBrowse" }) else { throw QuickBrowseError.missing }
        var tab = records.archive.remove(at: archived)
        tab.id = UUID(); tab.archiveSource = nil; tab.lastAccessed = Date()
        tab.pinned = false; tab.favorite = nil; tab.folder = nil; tab.homeURL = nil; tab.pinnedTitle = nil
        candidate.setLibrary(records, for: profile)
        let index: Int
        if activeProfileID == profile { index = spaceIndex }
        else if let found = candidate.session.spaces.firstIndex(where: { $0.effectiveProfileID == profile }) { index = found }
        else {
            var target = Space(name: profiles.first { $0.id == profile }?.name ?? "Personal", tabs: [])
            target.profileID = profile; candidate.session.spaces.append(target); index = candidate.session.spaces.count - 1
        }
        var discard: [UUID] = []
        if candidate.session.spaces[index].tabs.count == 1, let blank = candidate.session.spaces[index].tabs.first, blank.url.isEmpty && !blank.pinned {
            discard = [blank.id]; candidate.session.spaces[index].tabs = []
        }
        candidate.session.spaces[index].tabs.append(tab); candidate.session.spaces[index].selected = tab.id
        candidate.session.selectedSpace = candidate.session.spaces[index].id
        try commitQuickDocument(candidate, discarding: discard, beforePublish: {
            self.closePrimaryPeek(); self.splitID = nil; self.activePaneID = nil
        })
        return tab.id
    }
}
