import SwiftUI
import WebKit
import BrowserCore

enum PeekContext: Hashable { case primary, quick(UUID) }

@MainActor final class PeekState {
    let web: WKWebView
    let profileID: UUID
    var spaceID: UUID?
    var observations: [NSKeyValueObservation] = []
    init(web: WKWebView, profileID: UUID, spaceID: UUID?) {
        self.web = web; self.profileID = profileID; self.spaceID = spaceID
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
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self; web.uiDelegate = self; web.allowsBackForwardNavigationGestures = true
        let page = PeekState(web: web, profileID: profile, spaceID: targetSpace)
        let changed: () -> Void = { [weak self, weak web] in
            Task { @MainActor in guard let self, let web, self.peekContext(for: web) != nil else { return }; self.revision += 1 }
        }
        page.observations = [web.observe(\.url) { _, _ in changed() }, web.observe(\.isLoading) { _, _ in changed() },
                             web.observe(\.estimatedProgress) { _, _ in changed() },
                             web.observe(\.canGoBack) { _, _ in changed() }, web.observe(\.canGoForward) { _, _ in changed() },
                             web.observe(\.cameraCaptureState) { _, _ in changed() }, web.observe(\.microphoneCaptureState) { _, _ in changed() }]
        peekPages[context] = page
        web.load(URLRequest(url: url))
    }
    func closePrimaryPeek() { closePeek(in: .primary) }
    func closeQuickPeek(_ id: UUID) { closePeek(in: .quick(id)) }
    func closeAllPeeks() { for context in Array(peekPages.keys) { closePeek(in: context) } }
    func closePeeks(forProfile profileID: UUID) {
        for (context, page) in peekPages where page.profileID == profileID { closePeek(in: context) }
    }
    func closePeek(in context: PeekContext) {
        guard let page = peekPages.removeValue(forKey: context) else { return }
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
        do { _ = try promotePeek(in: context) } catch { message = error.localizedDescription }
    }
    @discardableResult func promotePeek(in context: PeekContext, to destination: UUID? = nil, allowProfileChange: Bool = false) throws -> UUID {
        guard let page = peekPages[context], let url = page.web.url, QuickBrowseRouting.host(for: url) != nil else { throw QuickBrowseError.missing }
        let web = page.web; let owner = page.profileID
        try requireQuickProfile(owner)
        var candidate = makeDocument(); let index: Int
        if let destination {
            guard let found = candidate.session.spaces.firstIndex(where: { $0.id == destination }) else { throw ProfileError.missing }
            index = found
        } else if let found = candidate.session.spaces.firstIndex(where: { $0.id == page.spaceID && (isPrivate || $0.effectiveProfileID == owner) })
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
            if crossing { self.closePeek(in: context) }
            else {
                self.peekPages.removeValue(forKey: context); page.observations = []
                web.removeFromSuperview(); self.registerView(web, for: tab.id, profile: targetProfile)
            }
            self.closePrimaryPeek(); self.splitID = nil; self.activePaneID = nil
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
                Button { store.closePrimaryPeek() } label: { Image(systemName: "xmark") }.help("Close Peek")
                Spacer()
                Text(store.primaryPeekView?.url?.host ?? "Loading…").font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer()
                Button("Open in Tab") { store.expandPeek(in: .primary) }
            }.buttonStyle(.plain).padding(14).background(.regularMaterial)
            if let web = store.primaryPeekView { WebPane(webView: web) }
        }.background(.background).clipShape(RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.12))).shadow(color: .black.opacity(0.4), radius: 35, y: 15)
    }
}
