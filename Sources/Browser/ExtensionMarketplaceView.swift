import SwiftUI
import WebKit
import BrowserCore

/// A separate WebKit view for discovery. The native review button is the only
/// way a listing can request an install, using the existing verified transport.
@MainActor
final class ExtensionMarketplaceBrowser: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: WKWebView
    @Published private(set) var error: String?
    @Published private var revision = 0
    private var observations: [NSKeyValueObservation] = []
    private var hasCommittedPage = false

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        observations.append(webView.observe(\.url) { [weak self] _, _ in self?.changed() })
        observations.append(webView.observe(\.isLoading) { [weak self] _, _ in self?.changed() })
        observations.append(webView.observe(\.canGoBack) { [weak self] _, _ in self?.changed() })
        observations.append(webView.observe(\.canGoForward) { [weak self] _, _ in self?.changed() })
        goHome()
    }

    nonisolated private func changed() {
        Task { @MainActor [weak self] in self?.revision &+= 1 }
    }

    var listing: ExtensionStoreLocation? {
        guard hasCommittedPage, !webView.isLoading, error == nil, let url = webView.url else { return nil }
        return ExtensionMarketplace.listing(at: url)
    }

    func goHome() {
        hasCommittedPage = false
        error = nil
        webView.load(URLRequest(url: ExtensionMarketplace.home))
        revision &+= 1
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let frame = action.targetFrame else { decisionHandler(.cancel); return }
        let allowed = !action.shouldPerformDownload &&
            (!frame.isMainFrame || action.request.url.map(ExtensionMarketplace.allows) == true)
        decisionHandler(allowed ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let allowed = response.canShowMIMEType &&
            (!response.isForMainFrame || response.response.url.map(ExtensionMarketplace.allows) == true)
        decisionHandler(allowed ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        hasCommittedPage = false
        error = nil
        revision &+= 1
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        hasCommittedPage = webView.url.map(ExtensionMarketplace.allows) == true
        revision &+= 1
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showFailure(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showFailure(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        hasCommittedPage = false
        error = "Chrome Web Store stopped responding."
    }

    private func showFailure(_ failure: Error) {
        let native = failure as NSError
        guard native.domain != NSURLErrorDomain || native.code != NSURLErrorCancelled else { return }
        hasCommittedPage = false
        error = "Chrome Web Store couldn’t load. \(failure.localizedDescription)"
    }
}

struct ExtensionMarketplaceView: View {
    @ObservedObject var browser: ExtensionMarketplaceBrowser
    let busy: Bool
    let openInstalled: () -> Void
    let review: (ExtensionStoreLocation) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: openInstalled) {
                    Label("Installed Extensions", systemImage: "chevron.left")
                }.disabled(busy)
                Spacer()
                Button { browser.webView.goBack() } label: { Image(systemName: "arrow.left") }
                    .accessibilityLabel("Back").disabled(busy || !browser.webView.canGoBack)
                Button { browser.webView.goForward() } label: { Image(systemName: "arrow.right") }
                    .accessibilityLabel("Forward").disabled(busy || !browser.webView.canGoForward)
                Button(action: browser.goHome) { Image(systemName: "house") }
                    .accessibilityLabel("Chrome Web Store home").disabled(busy)
                Button("Review Extension") {
                    if let listing = browser.listing { review(listing) }
                }.buttonStyle(.borderedProminent).disabled(busy || browser.listing == nil)
                    .help("Review the current listing’s permissions and install it in Alcove")
            }.padding(.horizontal, 16).padding(.vertical, 10)
            if browser.webView.isLoading { ProgressView().progressViewStyle(.linear) }
            Divider()
            if let error = browser.error {
                VStack(spacing: 12) {
                    Text(error).multilineTextAlignment(.center)
                    Button("Reload Chrome Web Store", action: browser.goHome).disabled(busy)
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MarketplaceWebView(webView: browser.webView).allowsHitTesting(!busy)
            }
        }
    }
}

private struct MarketplaceWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> EdgeToEdgeWebHost {
        let host = EdgeToEdgeWebHost()
        host.setContent(webView)
        return host
    }
    func updateNSView(_ view: EdgeToEdgeWebHost, context: Context) {}
}
