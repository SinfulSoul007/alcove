import AppKit
import WebKit
import CryptoKit
import BrowserCore

@MainActor final class SiteSearchProbeWeb: WKWebView {
    var fixtureURL = URL(string: "http://127.0.0.1:9/original")!
    var requests: [URLRequest] = []
    override var url: URL? { fixtureURL }
    override func load(_ request: URLRequest) -> WKNavigation? {
        requests.append(request); if let url = request.url { fixtureURL = url }; return nil
    }
}
final class SiteSearchKeyReads { var count = 0 }
@MainActor final class SiteSearchStoreFixture {
    let root: URL, key: SymmetricKey, store: BrowserStore, profile: UUID, web: SiteSearchProbeWeb
    let reads = SiteSearchKeyReads()
    init(isPrivate: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Alcove.SiteSearchStore.\(UUID())")
        key = SymmetricKey(size: .bits256)
        let key = key, reads = reads
        store = BrowserStore(isPrivate: isPrivate, dataRoot: root, keyProvider: { _ in reads.count += 1; return key })
        store.onboardingVisible = false
        profile = isPrivate ? BrowserProfile.defaultID : try store.createProfile(name: "Owned search fixture")
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        if !isPrivate { store.namedDataStores[profile] = configuration.websiteDataStore }
        web = SiteSearchProbeWeb(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        store.registerView(web, for: store.selectedID!, profile: profile)
    }
    func anotherWeb(_ id: UUID, profile: UUID? = nil) -> SiteSearchProbeWeb {
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        let web = SiteSearchProbeWeb(frame: self.web.frame, configuration: configuration)
        store.registerView(web, for: id, profile: profile ?? self.profile); return web
    }
    func close() { store.shutdown(); try? FileManager.default.removeItem(at: root) }
}
