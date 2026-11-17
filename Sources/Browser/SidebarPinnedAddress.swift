import AppKit
import BrowserCore
import WebKit

private enum PinnedAddressError: LocalizedError {
    case unavailable, unsupportedCurrentAddress, invalidAddress, addressChanged

    var errorDescription: String? {
        switch self {
        case .unavailable: "This tab’s pinned address is no longer available."
        case .unsupportedCurrentAddress: "This page’s address cannot be kept in a new tab."
        case .invalidAddress: "Enter a complete HTTP or HTTPS address."
        case .addressChanged: "The pinned URL changed. Open the editor again to update it."
        }
    }
}

extension BrowserStore {
    struct PinnedAddressEdit {
        let tabID: UUID
        let profile: UUID
        let originalHome: String?
        let displayedAddress: String
    }

    private struct PinnedAddress {
        let tab: BrowserCore.Tab
        let profile: UUID
        let home: URL?
        let current: URL?
        let isAwayFromHome: Bool
        let owner: BrowserStore
        let web: WKWebView?
    }

    func canReturnToPinnedAddress(_ id: UUID) -> Bool {
        pinnedAddress(for: id)?.isAwayFromHome == true
    }

    func canKeepPageWhileReturningToPinnedAddress(_ id: UUID) -> Bool {
        guard canModifyLocalMetadata, !profileDataOperationInProgress, let target = pinnedAddress(for: id),
              target.isAwayFromHome, let current = target.current else { return false }
        return QuickBrowseRouting.host(for: current) != nil
    }

    func canEditPinnedAddress(_ id: UUID) -> Bool {
        (try? beginPinnedAddressEdit(id)) != nil
    }

    func canUseCurrentAddressAsPinned(_ id: UUID) -> Bool {
        guard let target = pinnedAddress(for: id), (try? requireSpaceProfile(target.profile)) != nil,
              let current = target.current, current != target.home else { return false }
        return QuickBrowseRouting.host(for: current) != nil
    }

    func beginPinnedAddressEdit(_ id: UUID) throws -> PinnedAddressEdit {
        guard let target = pinnedAddress(for: id) else { throw PinnedAddressError.unavailable }
        try requireSpaceProfile(target.profile)
        return PinnedAddressEdit(tabID: id, profile: target.profile, originalHome: target.tab.homeURL,
                                 displayedAddress: target.home?.absoluteString ?? target.current?.absoluteString ?? "")
    }

    func setPinnedAddress(_ snapshot: PinnedAddressEdit, to address: String) throws {
        guard let target = pinnedAddress(for: snapshot.tabID), target.profile == snapshot.profile else {
            throw PinnedAddressError.unavailable
        }
        try requireSpaceProfile(target.profile)
        guard target.tab.homeURL == snapshot.originalHome else { throw PinnedAddressError.addressChanged }
        guard let home = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = QuickBrowseRouting.host(for: home) else { throw PinnedAddressError.invalidAddress }
        guard home != target.home else { return }

        var pin = target.tab
        pin.homeURL = home.absoluteString
        pin.pinnedTitle = home == target.current ? (target.web?.title ?? pin.title) : host
        if target.web == nil, !target.isAwayFromHome {
            pin.url = home.absoluteString
            pin.title = pin.pinnedTitle ?? host
        }
        var candidate = makeDocument()
        if let space = candidate.session.spaces.firstIndex(where: { $0.tabs.contains { $0.id == pin.id } }),
           let tab = candidate.session.spaces[space].tabs.firstIndex(where: { $0.id == pin.id }) {
            candidate.session.spaces[space].tabs[tab] = pin
        }
        updatePinnedFavorite(pin, profile: target.profile, in: &candidate)
        try commitQuickDocument(candidate)
    }

    func useCurrentAddressAsPinned(_ id: UUID) throws {
        let snapshot = try beginPinnedAddressEdit(id)
        guard let address = pinnedAddress(for: id)?.current else { throw PinnedAddressError.invalidAddress }
        try setPinnedAddress(snapshot, to: address.absoluteString)
    }

    func requestPinnedAddressEdit(_ id: UUID) {
        do {
            let snapshot = try beginPinnedAddressEdit(id)
            let alert = NSAlert()
            alert.messageText = "Edit Pinned URL"
            let field = NSTextField(string: snapshot.displayedAddress)
            field.placeholderString = "https://example.com"
            field.frame = NSRect(x: 0, y: 0, width: 330, height: 24)
            alert.accessoryView = field
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            try setPinnedAddress(snapshot, to: field.stringValue)
        } catch { message = error.localizedDescription }
    }

    func requestUseCurrentAddressAsPinned(_ id: UUID) {
        do { try useCurrentAddressAsPinned(id) }
        catch { message = error.localizedDescription }
    }

    func requestReturnToPinnedAddress(_ id: UUID, keepingCurrentPage: Bool = false) {
        do { try returnToPinnedAddress(id, keepingCurrentPage: keepingCurrentPage) }
        catch { message = error.localizedDescription }
    }

    @discardableResult
    func returnToPinnedAddress(_ id: UUID, keepingCurrentPage: Bool = false) throws -> UUID? {
        guard let target = pinnedAddress(for: id), target.isAwayFromHome,
              let home = target.home, let current = target.current else { throw PinnedAddressError.unavailable }
        if keepingCurrentPage {
            try requireSpaceProfile(target.profile)
            guard QuickBrowseRouting.host(for: current) != nil else { throw PinnedAddressError.unsupportedCurrentAddress }
            return try keepCurrentPage(target, home: home, current: current)
        }
        selectAny(id)
        guard focusedID == id else { throw PinnedAddressError.unavailable }
        try navigateExtensionTab(id, to: home, profileID: target.profile)
        return nil
    }

    private func pinnedAddress(for id: UUID) -> PinnedAddress? {
        let profile = activeProfileID
        let localTab = space.tabs.first(where: { $0.id == id })
        guard !isShuttingDown, !awaitingInitialMetadata, extensionPopupProfileID == nil,
              !profileUnavailable(profile), profileID(for: id) == profile,
              let visible = localTab ?? favorites.first(where: { $0.id == id }),
              visible.pinned else { return nil }

        let tab = localTab ?? self.tab(id) ?? visible
        let home = tab.homeURL.flatMap { URL(string: $0) }.flatMap { QuickBrowseRouting.host(for: $0) == nil ? nil : $0 }

        let owner = windowGroup?.stores.first { $0.views[id] != nil } ?? self
        let web = owner.views[id]
        if let web {
            guard owner.viewProfileIDs[id] == profile, !owner.extensionOriginPopups.contains(web) else { return nil }
        }
        let committed = web?.backForwardList.currentItem
        let current = (committed?.url ?? web?.url ?? URL(string: tab.url)).flatMap { $0.scheme == nil ? nil : $0 }
        let isAway = home != nil && current != nil && current != home && committed?.initialURL != home
        return PinnedAddress(tab: tab, profile: profile, home: home, current: current,
                             isAwayFromHome: isAway, owner: owner, web: web)
    }

    private func updatePinnedFavorite(_ pin: BrowserCore.Tab, profile: UUID, in candidate: inout BrowserDocument) {
        guard pin.favorite == true else { return }
        var library = candidate.library(for: profile)
        var favorites = library.favoriteTabs ?? self.favorites(for: profile)
        if let index = favorites.firstIndex(where: { $0.id == pin.id }) { favorites[index] = pin }
        else { favorites.append(pin) }
        library.favoriteTabs = favorites
        candidate.setLibrary(library, for: profile)
    }

    private func keepCurrentPage(_ target: PinnedAddress, home: URL, current: URL) throws -> UUID {
        var pin = target.tab
        pin.url = home.absoluteString
        pin.title = pin.pinnedTitle ?? home.host ?? "Pinned tab"
        let continued = BrowserCore.Tab(title: target.web?.title ?? target.tab.title, url: current.absoluteString)
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
        updatePinnedFavorite(pin, profile: target.profile, in: &candidate)

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
