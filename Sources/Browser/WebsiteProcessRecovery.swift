import WebKit

@MainActor final class WebsiteProcessRecovery {
    weak var store: BrowserStore?
    weak var web: WKWebView?
    let profileID: UUID
    let document: NSUUID
    let presentation: NSUUID
    let address: URL?

    init(store: BrowserStore, web: WKWebView, profileID: UUID, address: URL?) {
        self.store = store; self.web = web; self.profileID = profileID; self.address = address
        document = store.documentIdentity(for: web)
        presentation = store.presentationIdentity(for: web)
    }
    var isCurrent: Bool {
        guard let store, let web, !store.isShuttingDown, web.navigationDelegate === store,
              store.profileID(for: web) == profileID, !store.profileUnavailable(profileID),
              store.documentIdentity(for: web) === document,
              store.presentationIdentity(for: web) === presentation else { return false }
        return store.websiteProcessRecoveries[ObjectIdentifier(web)] === self
    }
    func reload() {
        guard isCurrent, let store, let web else { return }
        store.clearWebsiteProcessRecovery(for: web)
        web.reload()
    }
}

extension BrowserStore {
    func websiteProcessRecovery(for web: WKWebView) -> WebsiteProcessRecovery? {
        guard let recovery = websiteProcessRecoveries[ObjectIdentifier(web)], recovery.isCurrent else { return nil }
        return recovery
    }
    func clearWebsiteProcessRecovery(for web: WKWebView) {
        let key = ObjectIdentifier(web)
        if websiteProcessRecoveries[key] != nil { websiteProcessRecoveries.removeValue(forKey: key) }
    }
    func websiteAddress(for web: WKWebView) -> URL? {
        if let url = web.url { return url }
        if let id = views.first(where: { $0.value === web })?.key,
           let value = tab(id)?.url, !value.isEmpty { return URL(string: value) }
        return peekState(for: web)?.requestedURL
    }
    var sidebarAddressURL: URL? {
        if let web = currentView { return websiteAddress(for: web) }
        guard let id = focusedID, let value = tab(id)?.url, !value.isEmpty else { return nil }
        return URL(string: value)
    }
}
