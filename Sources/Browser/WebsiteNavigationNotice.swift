import WebKit

@MainActor final class WebsiteNavigationNotice {
    weak var web: WKWebView?
    let document: NSUUID
    let text: String

    init(web: WKWebView, document: NSUUID, text: String) {
        self.web = web; self.document = document; self.text = text
    }
}

extension BrowserStore {
    func reportNavigationFailure(_ error: Error, from web: WKWebView) {
        guard !isShuttingDown, web.navigationDelegate === self,
              let profile = profileID(for: web), !profileUnavailable(profile),
              websiteProcessRecovery(for: web) == nil else { return }
        let text = error.localizedDescription
        message = text
        navigationFailureNotice = WebsiteNavigationNotice(web: web, document: documentIdentity(for: web), text: text)
    }

    func dismissNavigationFailure(for web: WKWebView) {
        guard let notice = navigationFailureNotice, notice.web === web,
              notice.document === documentIdentity(for: web), message == notice.text else { return }
        message = nil
    }
}
