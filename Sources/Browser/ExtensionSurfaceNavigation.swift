import WebKit
import BrowserCore

extension BrowserStore {
    /// Called only by an authorized extension tab API or an existing extension
    /// document leaving its origin. Ordinary website requests retain engine WAR checks.
    func navigateExtensionSurface(_ web:WKWebView,to url:URL,profileID:UUID) throws {
        if let id = views.first(where:{$0.value === web})?.key {try navigateExtensionTab(id,to:url,profileID:profileID);return}
        try requireQuickProfile(profileID)
        guard let context = peekContext(for:web),let page = peekPages[context],page.web === web,page.profileID == profileID else {throw ExtensionHostError.stale}
        if extensionOriginPopups.contains(web),["http","https"].contains(url.scheme?.lowercased() ?? "") {throw ExtensionHostError.unsupportedWebsitePopup}
        if extensionOriginPopups.contains(web),url.absoluteString == "about:blank" {web.load(URLRequest(url:url));return}
        let isExtension = url.scheme?.lowercased() == "webkit-extension",wasExtension = web.url?.scheme?.lowercased() == "webkit-extension"
        let configuration:WKWebViewConfiguration?
        if isExtension {
            guard let value = extensionHosting?.configuration(for:url,profileID:profileID) else {throw isPrivate ? ExtensionHostError.unsupportedPrivatePage : ExtensionHostError.stale}
            configuration = value
        } else {configuration = nil}
        guard isExtension != wasExtension || (isExtension && web.url?.host != url.host) else {web.load(URLRequest(url:url));return}
        let destination = configuration ?? WKWebViewConfiguration()
        destination.websiteDataStore = websiteDataStore(forProfile:profileID)
        destination.preferences.javaScriptCanOpenWindowsAutomatically = false
        configureExtensions(destination,profileID:profileID)
        let replacement = WKWebView(frame:web.frame,configuration:destination)
        let next = PeekState(id:page.id,web:replacement,profileID:profileID,spaceID:page.spaceID,requestedURL:url)
        closePeek(in:context);peekPages[context] = next;installPeek(next)
        replacement.load(URLRequest(url:url));revision += 1;extensionHosting?.refresh()
    }
}
