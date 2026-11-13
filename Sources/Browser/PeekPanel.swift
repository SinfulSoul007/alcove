import SwiftUI
import WebKit
import BrowserCore

enum PeekContext: Hashable { case primary, quick(UUID) }

@MainActor final class PeekState {
    let id:UUID
    let web: WKWebView
    let profileID: UUID
    var spaceID: UUID?
    let requestedURL: URL?
    var observations: [NSKeyValueObservation] = []
    init(id:UUID = UUID(),web: WKWebView, profileID: UUID, spaceID: UUID?, requestedURL: URL? = nil) {
        self.id = id;self.web = web; self.profileID = profileID; self.spaceID = spaceID; self.requestedURL = requestedURL
    }
}

extension BrowserStore {
    var primaryPeekView: WKWebView? { peekPages[.primary]?.web }
    func quickPeekView(_ id: UUID) -> WKWebView? { peekPages[.quick(id)]?.web }
    func peekContext(for web: WKWebView) -> PeekContext? { peekPages.first { $0.value.web === web }?.key }
    func peekState(for web: WKWebView) -> PeekState? { peekPages.values.first { $0.web === web } }
    func openPeek(_ url: URL, from source: WKWebView? = nil) {
        let profile: UUID; let targetSpace: UUID?; let context: PeekContext
        if let source {
            guard let owner = profileID(for: source), !profileUnavailable(owner) else { return }
            let quick = quickContext(for: source); targetSpace = spaceID(for: source)
            guard targetSpace != nil || quick != nil else { return }
            profile = owner; context = quick.map { .quick($0.id) } ?? .primary
        } else {
            guard !profileUnavailable(activeProfileID) else { return }
            profile = activeProfileID; targetSpace = space.id; context = .primary
        }
        closePeek(in: context)
        let config = WKWebViewConfiguration(); config.websiteDataStore = websiteDataStore(forProfile: profile)
        configureExtensions(config,profileID:profile)
        let web = WKWebView(frame: .zero, configuration: config)
        let page = PeekState(web: web, profileID: profile, spaceID: targetSpace, requestedURL: url)
        peekPages[context] = page;installPeek(page)
        web.load(URLRequest(url: url))
    }
    func installPeek(_ page:PeekState) {
        let web = page.web
        web.navigationDelegate = self; web.uiDelegate = self; web.allowsBackForwardNavigationGestures = true
        let changed: () -> Void = { [weak self, weak web] in
            Task { @MainActor in guard let self, let web, self.peekContext(for: web) != nil else { return }; self.revision += 1 }
        }
        page.observations = [web.observe(\.url) { _, _ in changed() }, web.observe(\.isLoading) { _, _ in changed() },
                             web.observe(\.estimatedProgress) { _, _ in changed() },
                             web.observe(\.canGoBack) { _, _ in changed() }, web.observe(\.canGoForward) { _, _ in changed() },
                             web.observe(\.cameraCaptureState) { _, _ in changed() }, web.observe(\.microphoneCaptureState) { _, _ in changed() }]
        BoostRuntime.install(on: web)
    }
    func closePrimaryPeek() { closePeek(in: .primary) }
    func closeQuickPeek(_ id: UUID) { closePeek(in: .quick(id)) }
    func closeAllPeeks() { for context in Array(peekPages.keys) { closePeek(in: context) } }
    func closePeeks(forProfile profileID: UUID) {
        for (context, page) in peekPages where page.profileID == profileID { closePeek(in: context) }
    }
    func closePeek(in context: PeekContext) {
        guard let page = peekPages.removeValue(forKey: context) else { return }
        invalidateDocumentIdentity(for: page.web); BoostRuntime.forget(page.web)
        closingPages.append(ClosingProfilePage(page.web, profileID: page.profileID))
        page.observations = []
        page.web.navigationDelegate = nil; page.web.uiDelegate = nil; page.web.stopLoading()
        page.web.loadHTMLString("", baseURL: nil); page.web.removeFromSuperview()
    }
    /// Reconcile against the candidate after durable ownership hooks, before publication.
    func reconcilePeeks(in document: BrowserDocument, resetting spaceID: UUID? = nil, recovering: Bool = false) {
        for (context, page) in peekPages {
            let profile = page.profileID
            if !isPrivate && document.profiles?.contains(where: { $0.id == profile && !$0.isPendingDeletion && !$0.isPendingClear }) != true {
                closePeek(in: context); continue
            }
            if recovering {
                let storage = page.web.configuration.websiteDataStore
                guard storage.isPersistent, storage.identifier == (profile == BrowserProfile.defaultID ? nil : profile) else { closePeek(in: context); continue }
            }
            switch context {
            case .quick(let parent):
                guard document.library(for: profile).quickPages?.contains(where: { $0.id == parent }) == true else { closePeek(in: context); continue }
                if !document.session.spaces.contains(where: { $0.id == page.spaceID && (isPrivate || $0.effectiveProfileID == profile) }) { page.spaceID = nil }
            case .primary:
                guard page.spaceID != spaceID || spaceID == nil,
                      document.session.spaces.contains(where: { $0.id == page.spaceID && (isPrivate || $0.effectiveProfileID == profile) }) else { closePeek(in: context); continue }
            }
        }
    }
    func adoptQuickPeek(_ id: UUID, into spaceID: UUID) {
        closePrimaryPeek()
        guard let page = peekPages.removeValue(forKey: .quick(id)) else { return }
        page.spaceID = spaceID; page.web.removeFromSuperview(); peekPages[.primary] = page
    }
    func expandPeek(in context: PeekContext) {
        requestExpandPeek(in: context)
    }
    @discardableResult func promotePeek(in context: PeekContext, to destination: UUID? = nil, allowProfileChange: Bool = false) throws -> UUID {
        try performPeekPromotion(preparePeekPromotion(in: context, to: destination), allowProfileChange: allowProfileChange)
    }
    func loadSiteIcon(_ web: WKWebView) {
        guard let id = views.first(where: { $0.value === web })?.key, let url = web.url, ["http", "https"].contains(url.scheme ?? "") else { return }
        // Rasterize within WebKit's process, using only same-origin icon URLs.
        // The result is bounded PNG data and stays in this window's memory.
        web.callAsyncJavaScript("""
            try {
                const candidate = document.querySelector('link[rel~="icon"]');
                let url = new URL(candidate ? candidate.href : '/favicon.ico', location.href);
                if (url.origin !== location.origin) url = new URL('/favicon.ico', location.href);
                const controller = new AbortController();
                const timeout = setTimeout(() => controller.abort(), 2000);
                let blob;
                try {
                    const response = await fetch(url.href, {credentials: 'omit', referrerPolicy: 'no-referrer', cache: 'no-store', redirect: 'error', signal: controller.signal});
                    if (!response.ok || Number(response.headers.get('content-length')) > 262144) return null;
                    blob = await response.blob();
                } finally { clearTimeout(timeout); controller.abort(); }
                if (blob.size > 262144) return null;
                const bitmap = await createImageBitmap(blob);
                const canvas = document.createElement('canvas'); canvas.width = 32; canvas.height = 32;
                canvas.getContext('2d').drawImage(bitmap, 0, 0, 32, 32); bitmap.close();
                return canvas.toDataURL('image/png');
            } catch (_) { return null; }
            """, arguments: [:], in: nil, in: .defaultClient) { [weak self, weak web] result in
                guard let self, let web, web.url == url, self.views[id] === web,
                      case .success(let value) = result, let dataURL = value as? String, dataURL.count < 32768,
                      dataURL.hasPrefix("data:image/png;base64,"), let data = Data(base64Encoded: String(dataURL.dropFirst(22))), let image = NSImage(data: data) else { return }
                self.siteIcons[id] = image
            }
    }
}

struct PeekPanel: View {
    @ObservedObject var store: BrowserStore
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { store.closePrimaryPeek() } label: { Image(systemName: "xmark") }.help("Close Peek")
                Spacer()
                Text(store.primaryPeekView?.url?.host ?? "Loading…").font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer()
                Button(store.peekOpenTitle(in: .primary)) { store.expandPeek(in: .primary) }
            }.buttonStyle(.plain).padding(14).background(.regularMaterial)
            if let web = store.primaryPeekView { WebPane(webView: web) }
        }.background(.background).clipShape(RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.12))).shadow(color: .black.opacity(0.4), radius: 35, y: 15)
    }
}
