import SwiftUI
import WebKit
import BrowserCore

extension BrowserStore {
    func openPeek(_ url: URL, from source: WKWebView? = nil) {
        let ownerProfile: UUID; let ownerSpace: UUID?; let parent: UUID?
        if let source {
            guard let profile = profileID(for: source), !profileUnavailable(profile) else { return }
            let context = quickContext(for: source); let space = spaceID(for: source)
            guard space != nil || context != nil else { return }
            ownerProfile = profile; ownerSpace = space; parent = context?.id
        } else { ownerProfile = activeProfileID; ownerSpace = space.id; parent = nil }
        closePeek()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = websiteDataStore(forProfile: ownerProfile)
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self; web.uiDelegate = self; web.allowsBackForwardNavigationGestures = true
        peekView = web; peekProfileID = ownerProfile; peekSpaceID = ownerSpace; peekParentQuickID = parent
        let changed: () -> Void = { [weak self, weak web] in
            Task { @MainActor in guard let self, let web, self.peekView === web else { return }; self.revision += 1 }
        }
        peekObservations = [web.observe(\.url) { _, _ in changed() }, web.observe(\.isLoading) { _, _ in changed() },
                            web.observe(\.cameraCaptureState) { _, _ in changed() }, web.observe(\.microphoneCaptureState) { _, _ in changed() }]
        web.load(URLRequest(url: url))
    }
    func closePrimaryPeek() { if peekParentQuickID == nil { closePeek() } }
    func canRetainPeek(in document: BrowserDocument) -> Bool {
        guard !isPrivate, let web = peekView, let profile = peekProfileID,
              document.profiles?.contains(where: { $0.id == profile && !$0.isPendingDeletion && !$0.isPendingClear }) == true else { return false }
        let dataStore = web.configuration.websiteDataStore
        guard dataStore.isPersistent, dataStore.identifier == (profile == BrowserProfile.defaultID ? nil : profile) else { return false }
        if let parent = peekParentQuickID { return document.library(for: profile).quickPages?.contains(where: { $0.id == parent }) == true }
        return document.session.spaces.contains(where: { $0.id == peekSpaceID && $0.effectiveProfileID == profile })
    }
    func closePeek() {
        if let web = peekView {
            if let profile = peekProfileID { closingPages.append(ClosingProfilePage(web, profileID: profile)) }
            web.navigationDelegate = nil; web.uiDelegate = nil; web.stopLoading(); web.loadHTMLString("", baseURL: nil); web.removeFromSuperview()
        }
        peekView = nil; peekObservations = []; peekProfileID = nil; peekSpaceID = nil; peekParentQuickID = nil
    }
    func expandPeek() {
        do { _ = try promotePeek() } catch { message = error.localizedDescription }
    }
    @discardableResult func promotePeek(to destination: UUID? = nil, allowProfileChange: Bool = false) throws -> UUID {
        guard let web = peekView, let owner = peekProfileID, let url = web.url, QuickBrowseRouting.host(for: url) != nil else { throw QuickBrowseError.missing }
        try requireQuickProfile(owner)
        var candidate = makeDocument(); var index: Int
        if let destination {
            guard let found = candidate.session.spaces.firstIndex(where: { $0.id == destination }) else { throw ProfileError.missing }
            index = found
        } else if let found = candidate.session.spaces.firstIndex(where: { $0.id == peekSpaceID && (isPrivate || $0.effectiveProfileID == owner) })
            ?? candidate.session.spaces.firstIndex(where: { isPrivate || $0.effectiveProfileID == owner }) { index = found }
        else {
            var target = Space(name: profiles.first(where: { $0.id == owner })?.name ?? "Personal", tabs: []); target.profileID = owner
            candidate.session.spaces.append(target); index = candidate.session.spaces.count - 1
        }
        let targetProfile = isPrivate ? BrowserProfile.defaultID : candidate.session.spaces[index].effectiveProfileID
        try requireQuickProfile(targetProfile)
        let crossing = owner != targetProfile
        guard !crossing || allowProfileChange else { throw QuickBrowseError.consentRequired }
        let tab = BrowserCore.Tab(title: web.title ?? url.host ?? "Page", url: url.absoluteString)
        var discard: [UUID] = []
        if candidate.session.spaces[index].tabs.count == 1, let blank = candidate.session.spaces[index].tabs.first, blank.url.isEmpty && !blank.pinned {
            discard.append(blank.id); candidate.session.spaces[index].tabs = []
        }
        candidate.session.spaces[index].tabs.append(tab); candidate.session.spaces[index].selected = tab.id
        candidate.session.selectedSpace = candidate.session.spaces[index].id
        if !isPrivate {
            var records = candidate.library(for: targetProfile); records.record(title: tab.title, url: tab.url); candidate.setLibrary(records, for: targetProfile)
        }
        try commitQuickDocument(candidate, discarding: discard, beforePublish: {
            if crossing { self.closePeek() }
            else {
                self.peekView = nil; self.peekObservations = []; self.peekProfileID = nil; self.peekSpaceID = nil; self.peekParentQuickID = nil
                web.removeFromSuperview(); self.registerView(web, for: tab.id, profile: targetProfile)
            }
            self.splitID = nil; self.activePaneID = nil
        })
        if !crossing { loadSiteIcon(web) }
        return tab.id
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
