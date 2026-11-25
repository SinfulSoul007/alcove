import AppKit
import WebKit

/// Cooperates with WebKit's temporary ownership of a real website view.
/// The document stays alive; only its intended AppKit host changes.
@MainActor final class WebsiteFullscreen {
    private weak var web: WKWebView?
    private weak var store: BrowserStore?
    private weak var intendedHost: EdgeToEdgeWebHost?
    private var profileID: UUID?
    private var presentationID: NSUUID?
    private var observation: NSKeyValueObservation?

    // Retain the restoration host only during the native presentation. SwiftUI
    // may replace it while WebKit still needs its placeholder to return the view.
    private var restorationHost: EdgeToEdgeWebHost?
    private weak var originWindow: NSWindow?
    private(set) var isBorrowed = false

    init(web: WKWebView) {
        self.web = web
        observation = web.observe(\.fullscreenState, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.stateChanged() }
        }
    }

    var logicalWindow: NSWindow? {
        isBorrowed ? originWindow : intendedHost?.window
    }

    private var isCurrent: Bool {
        guard let web, let store, let profileID, let presentationID,
              !store.isShuttingDown, web.navigationDelegate === store,
              store.profileID(for: web) == profileID,
              store.presentationIdentity(for: web) === presentationID,
              !store.profileUnavailable(profileID) else { return false }
        return true
    }

    func bind(store: BrowserStore, host: EdgeToEdgeWebHost) {
        guard let web, web.navigationDelegate === store,
              let profile = store.profileID(for: web) else { return }
        self.store = store
        profileID = profile
        presentationID = store.presentationIdentity(for: web)
        intendedHost = host
        reconcileRestoration()
    }

    /// Called before any AppKit reparenting, including repeated SwiftUI updates.
    func deferMount(in host: EdgeToEdgeWebHost) -> Bool {
        intendedHost = host
        guard let web else { return false }
        return isBorrowed || web.fullscreenState != .notInFullscreen
    }

    func viewDidMove() {
        reconcileRestoration()
    }

    private func stateChanged() {
        guard let web else { return }
        if web.fullscreenState != .notInFullscreen {
            if !isBorrowed {
                restorationHost = (web.superview as? EdgeToEdgeWebHost) ?? intendedHost
                originWindow = restorationHost?.window ?? web.window
                isBorrowed = true
            }
        } else {
            reconcileRestoration()
        }
    }

    private func reconcileRestoration() {
        guard isBorrowed, let web, web.fullscreenState == .notInFullscreen,
              let restorationHost, web.superview === restorationHost else { return }
        // State and view-move notifications can arrive in either order. Only
        // reconcile once WebKit has actually returned its borrowed view.
        isBorrowed = false
        self.restorationHost = nil
        originWindow = nil
        guard isCurrent, let store, let intendedHost else { return }
        WebPane(webView: web, store: store).mount(in: intendedHost)
        intendedHost.needsLayout = true
        intendedHost.layoutSubtreeIfNeeded()
    }
}
