import WebKit
import BrowserCore

extension BrowserStore {
    func canDuplicateSidebarTab(_ id: UUID) -> Bool {
        duplicateSource(id) != nil
    }

    @discardableResult
    func duplicateSidebarTab(_ id: UUID) -> UUID? {
        guard let source = duplicateSource(id) else { return nil }
        let history = source.web.flatMap { web in
            !web.isLoading && web.backForwardList.currentItem?.url == source.url ? web.interactionState : nil
        }
        var copy = BrowserCore.Tab(title: source.tab.title, url: source.url.absoluteString)
        copy.customTitle = source.tab.customTitle

        let destination = spaceIndex
        let ordered = session.spaces[destination].tabs
        let location = ordered.firstIndex { $0.id == id && !$0.pinned }.map { $0 + 1 }
            ?? ordered.firstIndex { !$0.pinned && !$0.url.isEmpty }
            ?? ordered.endIndex
        session.spaces[destination].tabs.insert(copy, at: location)
        guard tab(copy.id) != nil else { return nil }
        select(copy.id)
        _ = view(for: copy.id, restoringInteractionState: history, retaining: id)
        return copy.id
    }

    private func duplicateSource(_ id: UUID) -> (tab: BrowserCore.Tab, url: URL, web: WKWebView?)? {
        let profile = activeProfileID
        guard !isShuttingDown, !awaitingInitialMetadata, extensionPopupProfileID == nil,
              !profileUnavailable(profile), profileID(for: id) == profile,
              let tab = space.tabs.first(where: { $0.id == id }) ?? favorites.first(where: { $0.id == id }) else { return nil }

        // Read another window's history without claiming or moving its page.
        let owner = windowGroup?.stores.first { $0.viewProfileIDs[id] == profile } ?? self
        let web = owner.viewProfileIDs[id] == profile ? owner.views[id] : nil
        guard let url = web?.backForwardList.currentItem?.url ?? URL(string: tab.url),
              QuickBrowseRouting.host(for: url) != nil else { return nil }
        return (tab, url, web)
    }
}
