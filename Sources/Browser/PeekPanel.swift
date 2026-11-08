import SwiftUI
import WebKit
import BrowserCore

extension BrowserStore {
    func openPeek(_ url: URL, from source: WKWebView? = nil) {
        let ownerProfile: UUID; let ownerSpace: UUID
        if let source {
            guard let profile = profileID(for: source), let space = spaceID(for: source) else { return }
            ownerProfile = profile; ownerSpace = space
        } else { ownerProfile = activeProfileID; ownerSpace = space.id }
        closePeek()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = websiteDataStore(forProfile: ownerProfile)
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self; web.uiDelegate = self; web.allowsBackForwardNavigationGestures = true
        peekView = web; peekProfileID = ownerProfile; peekSpaceID = ownerSpace
        peekObservations = [web.observe(\.url) { [weak self] _, _ in Task { @MainActor in self?.revision += 1 } }]
        web.load(URLRequest(url: url))
    }
    func closePeek() {
        peekView?.navigationDelegate = nil; peekView?.uiDelegate = nil; peekView?.stopLoading(); peekView = nil; peekObservations = []; peekProfileID = nil; peekSpaceID = nil
    }
    func expandPeek() {
        guard let url = peekView?.url, ["http", "https"].contains(url.scheme ?? "") else { return }
        let owner = peekSpaceID; closePeek(); newTab(url: url, in: owner)
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
                const response = await fetch(url.href, {credentials: 'omit', referrerPolicy: 'no-referrer', cache: 'no-store'});
                const blob = await response.blob();
                if (!response.ok || blob.size > 262144) return null;
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
                Button { store.closePeek() } label: { Image(systemName: "xmark") }.help("Close Peek")
                Spacer()
                Text(store.peekView?.url?.host ?? "Loading…").font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer()
                Button("Open in Tab") { store.expandPeek() }
            }.buttonStyle(.plain).padding(14).background(.regularMaterial)
            if let web = store.peekView { WebPane(webView: web) }
        }.background(.background).clipShape(RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.12))).shadow(color: .black.opacity(0.4), radius: 35, y: 15)
    }
}
