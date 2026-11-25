import AppKit
import WebKit
import SwiftUI

@MainActor final class ReaderSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    typealias State = ReaderLoadState.Phase
    @Published private var loadState = ReaderLoadState()
    var state: State { loadState.phase }
    @Published private(set) var searchVisible = false
    @Published private(set) var searchFocusRequest = 0
    @Published private(set) var searchResult: Bool?
    @Published var searchText = "" { didSet { if searchText != oldValue { searchGeneration = UUID(); searchResult = nil } } }
    private var searchGeneration = UUID()
    @Published var theme = ReaderTheme.sepia { didSet { updateStyle() } }
    @Published var sansSerif = false { didSet { updateStyle() } }
    @Published var textSize = 20.0 { didSet { updateStyle() } }
    @Published var lineWidth = 720.0 { didSet { updateStyle() } }
    weak var store: BrowserStore?
    weak var source: WKWebView?
    weak var window: NSWindow?
    weak var overlay: ReaderOverlay?
    let profileID: UUID, document: NSUUID, presentation: NSUUID, url: URL
    let reader: WKWebView
    private var timeout: Task<Void, Never>?
    private var closing: NSObjectProtocol?
    private var sourceURL: NSKeyValueObservation?
    private(set) var title = "Reader"

    init(store: BrowserStore, source: WKWebView, window: NSWindow, profile: UUID, url: URL) {
        self.store = store; self.source = source; self.window = window; self.profileID = profile; self.url = url
        document = store.documentIdentity(for: source); presentation = store.presentationIdentity(for: source)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        // Deliberately do not call configureExtensions or install any message handlers.
        reader = WKWebView(frame: .zero, configuration: configuration)
        reader.allowsBackForwardNavigationGestures = false
        reader.allowsLinkPreview = false
        super.init()
        reader.navigationDelegate = self; reader.uiDelegate = self
    }
    deinit { timeout?.cancel(); if let closing { NotificationCenter.default.removeObserver(closing) } }
    var isCurrent: Bool {
        guard state != .closed, let store, let source, let window,
              store.readerSessions[ObjectIdentifier(source)] === self,
              !store.isShuttingDown, source.window === window, source.navigationDelegate === store,
              store.profileID(for: source) == profileID, !store.profileUnavailable(profileID), source.url == url,
              store.documentIdentity(for: source) === document,
              store.presentationIdentity(for: source) === presentation else { return false }
        return true
    }
    func start() {
        guard isCurrent, let source, let window else { return }
        closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        sourceURL = source.observe(\.url) { [weak self] _, _ in
            Task { @MainActor in guard let self, !self.isCurrent else { return }; self.dismiss() }
        }
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            guard let self, self.isCurrent, self.state == .loading else { return }
            self.fail(.failed)
        }
        do {
            let script = try ReaderResources.extractionScript()
            source.callAsyncJavaScript(script, arguments: [:], in: nil, in: .world(name: "AlcoveReaderExtraction")) { [weak self] result in
                guard let self, self.isCurrent, self.state == .loading else { return }
                switch result {
                case .failure: self.fail(.failed)
                case .success(let value):
                    guard let article = value as? [String: Any] else { self.fail(.unavailable); return }
                    guard let html = article["html"] as? String, !html.isEmpty, html.utf8.count <= 2000000 else {
                        let error = article["error"] as? String
                        self.fail(error == "unsupported" ? .unsupported : error == "tooLarge" ? .tooLarge : error == "failed" ? .failed : .unavailable); return
                    }
                    self.title = String((article["title"] as? String ?? "Article").prefix(1000))
                    let byline = String((article["byline"] as? String ?? "").prefix(500))
                    let site = String((article["site"] as? String ?? self.url.host ?? "").prefix(300))
                    let direction = article["direction"] as? String == "rtl" ? "rtl" : "ltr"
                    guard self.loadState.beginDocument() else { return }
                    self.reader.loadHTMLString(ReaderDocument.html(title: self.title, byline: byline, site: site, direction: direction, content: html), baseURL: nil)
                }
            }
        } catch { fail(.resources) }
    }
    private func fail(_ failure: ReaderFailure) {
        timeout?.cancel(); timeout = nil
        guard isCurrent else { dismiss(); return }
        guard loadState.fail(failure.message) else { return }
        reader.stopLoading()
    }
    func dismiss(restoringFocus: Bool = false) {
        guard state != .closed else { return }
        let source = source, window = window
        dismissFind(); loadState.close(); timeout?.cancel(); timeout = nil; sourceURL = nil
        if let closing { NotificationCenter.default.removeObserver(closing); self.closing = nil }
        if let source, store?.readerSessions[ObjectIdentifier(source)] === self {
            store?.readerSessions.removeValue(forKey: ObjectIdentifier(source))
            source.setAccessibilityHidden(false)
            if let host = source.superview as? EdgeToEdgeWebHost { host.removeReader(for: source) }
            else { overlay?.removeFromSuperview() }
            store?.objectWillChange.send()
        } else { overlay?.removeFromSuperview() }
        reader.stopLoading(); reader.navigationDelegate = nil; reader.uiDelegate = nil; reader.loadHTMLString("", baseURL: nil)
        if restoringFocus, let source, source.window === window { window?.makeFirstResponder(source) }
    }
    func requestFind() { guard isCurrent, state == .ready else { return }; searchVisible = true; searchFocusRequest += 1 }
    func dismissFind() { searchVisible = false; searchGeneration = UUID(); searchResult = nil }
    func find(backwards: Bool = false) {
        guard isCurrent, state == .ready, searchVisible, !searchText.isEmpty else { searchResult = nil; return }
        let generation = UUID(); searchGeneration = generation
        let configuration = WKFindConfiguration(); configuration.wraps = true; configuration.backwards = backwards; configuration.caseSensitive = false
        reader.find(searchText, configuration: configuration) { [weak self] result in
            guard let self, self.isCurrent, self.state == .ready, self.searchVisible, self.searchGeneration == generation else { return }
            self.searchResult = result.matchFound
        }
    }
    func updateStyle() {
        guard isCurrent, state == .ready else { return }
        let palette = theme.colors
        let script: String
        do { script = try ReaderResources.styleScript() } catch { fail(.resources); return }
        reader.callAsyncJavaScript(script, arguments: ["paper": palette.0, "ink": palette.1, "muted": palette.2, "link": palette.3,
            "size": min(30, max(14, textSize)), "width": min(960, max(480, lineWidth)),
            "font": sansSerif ? "-apple-system, BlinkMacSystemFont, sans-serif" : "Georgia, Charter, serif"], in: nil, in: .defaultClient) { _ in }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard isCurrent, state == .loading, webView === reader, loadState.finishDocument() else { return }
        timeout?.cancel(); timeout = nil; updateStyle()
        guard isCurrent, state == .ready else { return }
        if let source, let window, window.isKeyWindow, window.attachedSheet == nil,
           store?.isVisibleWebsite(source) == true, reader.window === window {
            window.makeFirstResponder(reader)
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { if isCurrent { fail(.failed) } }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { if isCurrent { fail(.failed) } }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { if isCurrent { fail(.failed) } }
    func openLink(_ destination: URL, modifiers: NSEvent.ModifierFlags = [], opensNewPage: Bool = false) {
        guard isCurrent, state == .ready, ["https", "http"].contains(destination.scheme?.lowercased() ?? ""),
              destination.user == nil, destination.password == nil, let source, let store else { return }
        dismiss(restoringFocus: true)
        if modifiers.contains(.shift) { store.openPeek(destination, from: source) }
        else if opensNewPage || modifiers.contains(.command) {
            // Use a fresh normal website configuration, never the inert renderer's
            // configuration or an extension controller attached to Reader itself.
            store.createPopup(from: source, configuration: WKWebViewConfiguration(), requestedURL: destination)?.load(URLRequest(url: destination))
        } else { source.load(URLRequest(url: destination)) }
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.navigationType == .linkActivated, let destination = action.request.url { openLink(destination, modifiers: action.modifierFlags, opensNewPage: true) }
        return nil
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.navigationType == .linkActivated {
            decisionHandler(.cancel)
            if let destination = action.request.url { openLink(destination, modifiers: action.modifierFlags, opensNewPage: action.targetFrame == nil || action.buttonNumber == 2) }
            return
        }
        // Only our one local HTML document may load. No downloads, frames, external
        // redirects or script-origin navigations are allowed inside Reader.
        decisionHandler(loadState.isLoadingDocument && action.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
    }
}

extension BrowserStore {
    func readerSession(for web: WKWebView) -> ReaderSession? { readerSessions[ObjectIdentifier(web)] }
    func canToggleReader(for web: WKWebView) -> Bool {
        !isShuttingDown && web.navigationDelegate === self && profileID(for: web).map { !profileUnavailable($0) } == true
            && !extensionOriginPopups.contains(web) && ["http", "https"].contains(web.url?.scheme?.lowercased() ?? "")
            && websiteProtectionTicket(for: web) == nil
    }
    @objc func toggleReader(_ web: WKWebView) {
        if let session = readerSession(for: web) { session.dismiss(restoringFocus: true); return }
        guard canToggleReader(for: web), isVisibleWebsite(web), let window = web.window, let profile = profileID(for: web), let url = web.url, window.attachedSheet == nil else {
            message = ReaderFailure.unsupported.message; return
        }
        guard !web.isLoading else { message = "Wait for this page to finish loading, then try Reader again."; return }
        let session = ReaderSession(store: self, source: web, window: window, profile: profile, url: url)
        readerSessions[ObjectIdentifier(web)] = session
        if let host = web.superview as? EdgeToEdgeWebHost { host.setReader(store: self, webView: web) }
        // Loading and unavailable states must not leave keystrokes editing or
        // scrolling the covered original page. Ready Reader takes focus below.
        if window.isKeyWindow { window.makeFirstResponder(nil) }
        web.setAccessibilityHidden(true); objectWillChange.send(); session.start()
    }
    func cancelReader(for web: WKWebView) { readerSession(for: web)?.dismiss() }
    func cancelAllReaders() { for session in Array(readerSessions.values) { session.dismiss() } }
}
