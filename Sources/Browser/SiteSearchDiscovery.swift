import WebKit
import BrowserCore

struct SiteSearchDiscoveryPage: Hashable {
    let webView: ObjectIdentifier
    let window: ObjectIdentifier
    let document: UUID
    let url: URL
    let context: SearchInputContext
}

struct AdvertisedSiteSearch {
    let page: SiteSearchDiscoveryPage
    let descriptorURL: URL
}

extension BrowserStore {
    private var siteSearchSourceView: WKWebView? { primaryPeekView ?? currentView }

    var siteSearchDiscoveryPage: SiteSearchDiscoveryPage? {
        guard presentedPanel == .siteSearch, canEditSiteSearches, !onboardingVisible, extensionPopupProfileID == nil,
              let web = siteSearchSourceView, let window = web.window, !web.isLoading,
              profileID(for: web) == activeProfileID, let context = searchInputContext(), let url = web.url, WebOrigin(url) != nil,
              url.user == nil, url.password == nil else { return nil }
        return SiteSearchDiscoveryPage(webView: ObjectIdentifier(web), window: ObjectIdentifier(window),
                                       document: documentIdentity(for: web) as UUID, url: url, context: context)
    }

    func discoverSiteSearch(on page: SiteSearchDiscoveryPage) async -> AdvertisedSiteSearch? {
        guard siteSearchDiscoveryPage == page, let web = siteSearchSourceView else { return nil }
        let links = try? await web.callAsyncJavaScript("""
            const links = document.head?.querySelectorAll('link[rel~="search" i][href]') ?? [];
            return Array.from(links).filter(link => link.type.toLowerCase() === 'application/opensearchdescription+xml')
                .slice(0, 16).map(link => link.getAttribute('href').slice(0, 8193));
            """, contentWorld: .defaultClient) as? [String]
        guard !Task.isCancelled, siteSearchDiscoveryPage == page,
              let address = links?.lazy.compactMap({ OpenSearchDescription.advertisedURL($0, on: page.url) }).first else { return nil }
        return AdvertisedSiteSearch(page: page, descriptorURL: address)
    }

    func loadSiteSearchDraft(_ advertisement: AdvertisedSiteSearch) async throws -> SiteSearch {
        try Task.checkCancellation()
        let page = advertisement.page
        guard siteSearchDiscoveryPage == page, let web = siteSearchSourceView else { throw SearchInputError.contextChanged }
        let encoded = try? await web.callAsyncJavaScript("""
            const controller = new AbortController();
            const timer = setTimeout(() => controller.abort(), 5000);
            try {
                const response = await fetch(address, { mode: 'same-origin', credentials: 'omit', cache: 'no-store',
                    referrerPolicy: 'no-referrer', redirect: 'error', signal: controller.signal });
                if (!response.ok || response.redirected || !response.body || Number(response.headers.get('content-length')) > limit) return null;
                const reader = response.body.getReader();
                const bytes = new Uint8Array(limit);
                let length = 0;
                while (true) {
                    const { done, value } = await reader.read();
                    if (done) break;
                    if (length + value.length > limit) return null;
                    bytes.set(value, length);
                    length += value.length;
                }
                let text = '';
                for (let index = 0; index < length; index += 8192)
                    text += String.fromCharCode(...bytes.subarray(index, Math.min(index + 8192, length)));
                return btoa(text);
            } finally {
                clearTimeout(timer);
                controller.abort();
            }
            """, arguments: ["address": advertisement.descriptorURL.absoluteString, "limit": OpenSearchDescription.maximumBytes], contentWorld: .defaultClient) as? String
        try Task.checkCancellation()
        guard siteSearchDiscoveryPage == page else { throw SearchInputError.contextChanged }
        guard let encoded, let data = Data(base64Encoded: encoded) else { throw SiteSearchDiscoveryError.unreadable }
        return try OpenSearchDescription.siteSearch(from: data, at: advertisement.descriptorURL, keyword: suggestedSiteSearchKeyword(for: page.url))
    }

    private func suggestedSiteSearchKeyword(for url: URL) -> String {
        let host = WebOrigin(url)?.host ?? ""
        let domain = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let label = domain.split(separator: ".").first?.prefix(24) ?? ""
        let base = label.isEmpty || domain.hasPrefix("[") ? "site" : String(label)
        let existing = Set(siteSearchCatalog.entries.map(\.keyword))
        var keyword = base
        var number = 1
        while existing.contains(keyword) {
            number += 1
            keyword = "\(base)-\(number)"
        }
        return keyword
    }

    private enum SiteSearchDiscoveryError: LocalizedError {
        case unreadable
        var errorDescription: String? { "Alcove couldn’t read the search description from this site." }
    }
}
