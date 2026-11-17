import AppKit
import BrowserCore
import WebKit

private enum PinnedAddressError: LocalizedError {
    case unavailable, unsupportedCurrentAddress

    var errorDescription: String? {
        switch self {
        case .unavailable: "This tab’s pinned address is no longer available."
        case .unsupportedCurrentAddress: "This page’s address cannot be kept in a new tab."
        }
    }
}

extension BrowserStore {
    private struct PinnedAddress {
        let tab: BrowserCore.Tab
        let profile: UUID
        let home: URL
        let current: URL
        let owner: BrowserStore
        let web: WKWebView?
    }

    func canReturnToPinnedAddress(_ id: UUID) -> Bool {
        pinnedAddress(for: id) != nil
    }

    func canKeepPageWhileReturningToPinnedAddress(_ id: UUID) -> Bool {
        guard canModifyLocalMetadata, !profileDataOperationInProgress, let target = pinnedAddress(for: id) else { return false }
        return QuickBrowseRouting.host(for: target.current) != nil
    }

    func requestReturnToPinnedAddress(_ id: UUID, keepingCurrentPage: Bool = false) {
        do { try returnToPinnedAddress(id, keepingCurrentPage: keepingCurrentPage) }
        catch { message = error.localizedDescription }
    }

    @discardableResult
    func returnToPinnedAddress(_ id: UUID, keepingCurrentPage: Bool = false) throws -> UUID? {
        guard let target = pinnedAddress(for: id) else { throw PinnedAddressError.unavailable }
        if keepingCurrentPage {
            try requireSpaceProfile(target.profile)
            guard QuickBrowseRouting.host(for: target.current) != nil else { throw PinnedAddressError.unsupportedCurrentAddress }
            return try keepCurrentPage(target)
        }
        selectAny(id)
        guard focusedID == id else { throw PinnedAddressError.unavailable }
        try navigateExtensionTab(id, to: target.home, profileID: target.profile)
        return nil
    }

    private func pinnedAddress(for id: UUID) -> PinnedAddress? {
        let profile = activeProfileID
        guard !isShuttingDown, !awaitingInitialMetadata, extensionPopupProfileID == nil,
              !profileUnavailable(profile), profileID(for: id) == profile,
              let tab = space.tabs.first(where: { $0.id == id }) ?? favorites.first(where: { $0.id == id }),
              tab.pinned, let address = tab.homeURL, let home = URL(string: address),
              QuickBrowseRouting.host(for: home) != nil else { return nil }

        let owner = windowGroup?.stores.first { $0.views[id] != nil } ?? self
        let web = owner.views[id]
        if let web {
            guard owner.viewProfileIDs[id] == profile, !owner.extensionOriginPopups.contains(web) else { return nil }
        }
        let committed = web?.backForwardList.currentItem
        guard let current = committed?.url ?? web?.url ?? URL(string: tab.url),
              current != home, committed?.initialURL != home else { return nil }
        return PinnedAddress(tab: tab, profile: profile, home: home, current: current, owner: owner, web: web)
    }

    private func keepCurrentPage(_ target: PinnedAddress) throws -> UUID {
        var pin = target.tab
        pin.url = target.home.absoluteString
        pin.title = pin.pinnedTitle ?? target.home.host ?? "Pinned tab"
        let continued = BrowserCore.Tab(title: target.web?.title ?? target.tab.title, url: target.current.absoluteString)
        var candidate = makeDocument()
        let destination = spaceIndex
        let id = pin.id
        if let index = candidate.session.spaces[destination].tabs.firstIndex(where: { $0.id == id }) {
            candidate.session.spaces[destination].tabs[index] = pin
        } else {
            if let other = candidate.session.spaces.first(where: { $0.tabs.contains(where: { $0.id == id }) }) {
                candidate.session.close(id, in: other.id)
            }
            candidate.session.spaces[destination].tabs.append(pin)
        }
        let tabs = candidate.session.spaces[destination].tabs
        let todayStart = tabs.firstIndex { !$0.pinned && !$0.url.isEmpty } ?? tabs.endIndex
        candidate.session.spaces[destination].tabs.insert(continued, at: todayStart)
        candidate.session.spaces[destination].selected = id
        if pin.favorite == true {
            var library = candidate.library(for: target.profile)
            var favorites = library.favoriteTabs ?? self.favorites(for: target.profile)
            if let index = favorites.firstIndex(where: { $0.id == id }) { favorites[index] = pin }
            else { favorites.append(pin) }
            library.favoriteTabs = favorites
            candidate.setLibrary(library, for: target.profile)
        }

        var retained: (web: WKWebView, icon: NSImage?)?
        try commitQuickDocument(candidate, beforePublish: {
            retained = target.owner.takeRegisteredView(id, transferringTo: self)
        })
        if let retained {
            registerView(retained.web, for: continued.id, profile: target.profile)
            if let icon = retained.icon { siteIcons[continued.id] = icon }
            extensionHosting?.sourceDocumentChanged(retained.web)
            if target.owner !== self { target.owner.revision += 1 }
        }
        select(id)
        _ = view(for: id, retaining: continued.id)
        revision += 1
        return continued.id
    }
}
