import AppKit
import WebKit
import BrowserCore

/// A source lifetime, rather than a mutable current Space or a retained native view.
@MainActor final class BoostEditSource {
    weak var store: BrowserStore?
    weak var web: WKWebView?
    weak var window: NSWindow?
    let profileID: UUID
    let host: String
    let url: URL
    let documentID: NSUUID
    let inputContext: SearchInputContext
    private var closed = false
    private var closing: NSObjectProtocol?

    init(store: BrowserStore, web: WKWebView) throws {
        guard store.isVisibleWebsite(web), web.navigationDelegate === store,
              let window = web.window, let profile = store.profileID(for: web),
              store.matchesBoostWebsiteDataStore(web, profileID: profile),
              let url = web.url, let origin = WebOrigin(url),
              let context = store.searchInputContext(quickID: store.quickContext(for: web)?.id) else { throw BoostError.stale }
        self.store = store; self.web = web; self.window = window
        profileID = profile; host = origin.host; self.url = url
        documentID = store.documentIdentity(for: web); inputContext = context
        closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.closed = true
                if self.store?.boostPicker?.source === self { self.store?.cancelBoostPicker() }
            }
        }
    }
    deinit { if let closing { NotificationCenter.default.removeObserver(closing) } }
    func matches(_ owner: BrowserStore) -> Bool {
        guard store === owner, !closed, !owner.isShuttingDown, let web, let window,
              web.window === window, web.navigationDelegate === owner, !owner.profileUnavailable(profileID),
              owner.profileID(for: web) == profileID, owner.documentIdentity(for: web) === documentID,
              owner.matchesBoostWebsiteDataStore(web, profileID: profileID),
              web.url == url, web.url.flatMap(WebOrigin.init)?.host == host,
              owner.matchesSearchInputContext(inputContext) else { return false }
        return true
    }
}

@MainActor final class BoostJavaScriptRequest {
    let source: BoostEditSource
    let boostID: UUID
    let scriptHash: String
    let host: String
    var consumed = false
    init(source: BoostEditSource, boost: SiteBoost) {
        self.source = source; boostID = boost.id; scriptHash = boost.scriptHash; host = boost.content.host
    }
}
