import WebKit
import BrowserCore

struct QuickActionSnapshot {
    let id: UUID
    let profileID: UUID
    let url: String
    let viewID: ObjectIdentifier?
}
enum QuickPageNavigation { case back, forward, reload, stop }

extension BrowserStore {
    func foregroundQuickView(_ id: UUID) -> WKWebView? {
        guard !isShuttingDown, let profile = quickProfileID(id), !profileUnavailable(profile) else { return nil }
        return quickPeekView(id) ?? views[id]
    }
    func performQuickNavigation(_ id: UUID, action: QuickPageNavigation) {
        guard let web = foregroundQuickView(id) else { return }
        switch action {
        case .back: web.goBack()
        case .forward: web.goForward()
        case .reload: web.reload()
        case .stop: web.stopLoading()
        }
    }
    func navigateForegroundQuickPage(_ id: UUID, input: String, selection: SiteSearch? = nil, context: SearchInputContext? = nil) throws {
        if let context {
            guard case .quick(let pageID, _, _) = context, pageID == id, matchesSearchInputContext(context) else { throw SearchInputError.contextChanged }
        } else if selection != nil { throw SearchInputError.contextChanged }
        guard let profile = quickProfileID(id) else { throw QuickBrowseError.missing }
        try requireQuickProfile(profile)
        let url = try resolveSearchInput(input, selection: selection)
        if let peek = quickPeekView(id) {
            guard QuickBrowseRouting.host(for: url) != nil else { throw QuickBrowseError.invalidAddress }
            touchQuickPage(id); peek.load(URLRequest(url: url))
        } else { try navigateQuickPage(id, input: url.absoluteString) }
    }
    func isFocusedWebsite(_ web: WKWebView) -> Bool {
        guard let window = web.window, window.isKeyWindow || window.attachedSheet?.isKeyWindow == true else { return false }
        return isVisibleWebsite(web)
    }
    func isVisibleWebsite(_ web: WKWebView) -> Bool {
        guard !isShuttingDown, web.window != nil,
              let profile = profileID(for: web), !profileUnavailable(profile) else { return false }
        if let context = quickContext(for: web) {
            if let peek = quickPeekView(context.id) { return web === peek }
            return views[context.id] === web
        }
        guard presentedPanel == nil, !commandVisible, !onboardingVisible else { return false }
        if let primaryPeekView { return web === primaryPeekView && peekPages[.primary]?.spaceID == space.id }
        return web === currentView
    }
    func focusProfileSpace(_ profileID: UUID) throws {
        let profile = isPrivate ? BrowserProfile.defaultID : profileID
        try requireQuickProfile(profile)
        if let target = session.spaces.first(where: { isPrivate || $0.effectiveProfileID == profile }) { selectSpace(target.id); return }
        var candidate = makeDocument()
        var target = Space(name: profiles.first { $0.id == profile }?.name ?? "Personal")
        target.profileID = profile; candidate.session.spaces.append(target); candidate.session.activateSpace(target.id)
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
        try openRoutedExternal(url)
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
        try restoreArchivedRouted(id, profileID: profileID)
    }
}
