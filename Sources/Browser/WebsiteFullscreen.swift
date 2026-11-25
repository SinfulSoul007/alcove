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
    private weak var presentationWindow: NSWindow?
    private var capturedPresentationWindow = false
    private(set) var isBorrowed = false
    private var reconciliationScheduled = false
    private var presentationGeneration = UUID()
    private var exitRequest: ExitRequest?
    private var exitRequestStarted = false
    private var exitTimeout: Task<Void, Never>?

    @MainActor private struct ExitWaiter {
        weak var presentation: WebsiteFullscreen?
        weak var store: BrowserStore?
        weak var web: WKWebView?
        weak var window: NSWindow?
        let profileID: UUID
        let presentationID: NSUUID
        let generation: UUID
        let completion: @MainActor (Bool) -> Void

        var isCurrent: Bool {
            guard let presentation, !presentation.isBorrowed, presentation.presentationGeneration == generation,
                  let store, let web, let window, window.isVisible, window.isKeyWindow, NSApp.isActive,
                  !store.isShuttingDown, web.navigationDelegate === store,
                  store.profileID(for: web) == profileID, !store.profileUnavailable(profileID),
                  store.presentationIdentity(for: web) === presentationID, web.window === window else { return false }
            return true
        }
    }

    @MainActor private final class ExitRequest {
        var waiters: [ExitWaiter] = []
        private var finished = false
        private weak var presentation: WebsiteFullscreen?
        private weak var window: NSWindow?
        private weak var preferredWindow: NSWindow?
        private let beganInForeground: Bool
        private var focusChanged = false
        private var focusObservations: [NSObjectProtocol] = []
        private var focusMonitor: Any?

        init(presentation: WebsiteFullscreen, window: NSWindow) {
            self.presentation = presentation; self.window = window
            beganInForeground = NSApp.isActive && (window.isKeyWindow || presentation.presentationWindow?.isKeyWindow == true)
            focusObservations.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, !self.finished, let changed = notification.object as? NSWindow,
                          changed !== self.window, changed !== self.presentation?.presentationWindow else { return }
                    self.focusChanged = true; self.preferredWindow = changed
                }
            })
            focusObservations.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.focusChanged = true; self?.preferredWindow = nil }
            })
            // A deliberate return to the source supersedes the earlier window
            // choice. Observe only event ownership; never retain input contents.
            focusMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
                MainActor.assumeIsolated {
                    if let self, self.focusChanged,
                       event.window === self.window || event.window === self.presentation?.presentationWindow {
                        self.preferredWindow = nil
                    }
                }
                return event
            }
        }

        func finish(restored: Bool) {
            guard !finished else { return }
            finished = true
            let canContinue = beganInForeground && !focusChanged && NSApp.isActive
            focusObservations.forEach(NotificationCenter.default.removeObserver); focusObservations.removeAll()
            if let focusMonitor { NSEvent.removeMonitor(focusMonitor); self.focusMonitor = nil }
            // WebKit may make the source window key at the end of its exit.
            // Preserve a newer explicit choice without activating the app or
            // surfacing a closed/minimized window. Every request finishes here,
            // including the retained failure deadline, so tracking is removed.
            if focusChanged, NSApp.isActive, window?.isKeyWindow == true,
               let preferredWindow, preferredWindow.isVisible, !preferredWindow.isMiniaturized {
                preferredWindow.makeKeyAndOrderFront(nil)
            }
            let captured = waiters; waiters.removeAll()
            // Revalidate each callback after the previous one: closing a tab or
            // changing its owner must revoke later work from that old context.
            for waiter in captured { waiter.completion(restored && canContinue && waiter.isCurrent) }
        }
    }

    init(web: WKWebView) {
        self.web = web
        observation = web.observe(\.fullscreenState, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.stateChanged() }
        }
    }

    var logicalWindow: NSWindow? {
        isBorrowed ? originWindow : intendedHost?.window
    }

    var currentSource: WKWebView? { isBorrowed && isCurrent ? web : nil }

    func matches(_ window: NSWindow) -> Bool {
        guard currentSource != nil else { return false }
        if presentationWindow === window { return true }
        return originWindow === window && (window.isKeyWindow || presentationWindow?.isKeyWindow == true)
    }

    /// True permits work only in the still-current, foreground source context.
    /// False cancels stale actions, even when native restoration itself succeeded.
    func exit(completion: @escaping @MainActor (Bool) -> Void) {
        guard let web, let store, let window = logicalWindow, let profileID, let presentationID else {
            completion(false); return
        }
        let waiter = ExitWaiter(presentation: self, store: store, web: web, window: window,
                                profileID: profileID, presentationID: presentationID,
                                generation: presentationGeneration, completion: completion)
        guard isBorrowed || web.fullscreenState != .notInFullscreen else { completion(waiter.isCurrent); return }
        if let exitRequest { exitRequest.waiters.append(waiter) }
        else {
            let request = ExitRequest(presentation: self, window: window); request.waiters.append(waiter); exitRequest = request
            // The deadline cancels a failed operation; it never declares native
            // restoration complete. Retain the waiters even if the page dies.
            exitTimeout = Task { @MainActor [weak self, request] in
                do { try await Task.sleep(for: .seconds(12)) } catch { return }
                if let self { self.finishExitRequest(request, restored: false) }
                else { request.finish(restored: false) }
            }
        }
        requestExitIfPossible()
    }

    private func requestExitIfPossible() {
        guard let request = exitRequest, !exitRequestStarted, let web,
              web.fullscreenState == .inFullscreen else { return }
        exitRequestStarted = true
        web.callAsyncJavaScript("""
            if (document.fullscreenElement) await Document.prototype.exitFullscreen.call(document);
            return true;
            """, arguments: [:], in: nil, in: .defaultClient) { [weak self, request] result in
            MainActor.assumeIsolated {
                if case .failure = result {
                    if let self { self.finishExitRequest(request, restored: false) }
                    else { request.finish(restored: false) }
                }
            }
        }
    }

    private func finishExitRequest(_ request: ExitRequest, restored: Bool) {
        guard exitRequest === request else { request.finish(restored: false); return }
        exitRequest = nil; exitRequestStarted = false
        exitTimeout?.cancel(); exitTimeout = nil
        request.finish(restored: restored)
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
        scheduleReconciliation()
    }

    /// Called before any AppKit reparenting, including repeated SwiftUI updates.
    func deferMount(in host: EdgeToEdgeWebHost) -> Bool {
        intendedHost = host
        guard let web else { return false }
        return isBorrowed || web.fullscreenState != .notInFullscreen
    }

    func viewDidMove() {
        capturePresentationWindow()
        scheduleReconciliation()
    }

    func hostSubviewWillChange() { scheduleReconciliation() }

    private func capturePresentationWindow() {
        guard isBorrowed, !capturedPresentationWindow, let web,
              web.fullscreenState != .notInFullscreen,
              let window = web.window, window !== originWindow else { return }
        presentationWindow = window
        capturedPresentationWindow = true
    }

    private func stateChanged() {
        guard let web else { return }
        if web.fullscreenState != .notInFullscreen {
            if !isBorrowed {
                presentationGeneration = UUID()
                restorationHost = (web.superview as? EdgeToEdgeWebHost) ?? intendedHost
                originWindow = restorationHost?.window ?? web.window
                isBorrowed = true
                restorationHost?.trackFullscreenRestoration(self)
            }
            capturePresentationWindow()
            requestExitIfPossible()
        } else {
            scheduleReconciliation()
        }
    }

    private func scheduleReconciliation() {
        guard isBorrowed, !reconciliationScheduled else { return }
        reconciliationScheduled = true
        // These notifications can occur inside AppKit's add/removeSubview.
        // Never reparent recursively before that native operation has returned.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reconciliationScheduled = false
            self.reconcileRestoration()
        }
    }

    private func reconcileRestoration() {
        guard isBorrowed, let web, web.fullscreenState == .notInFullscreen,
              let restorationHost, web.superview === restorationHost,
              !capturedPresentationWindow || presentationWindow?.isVisible != true else { return }
        // State and view-move notifications can arrive in either order. Only
        // reconcile once WebKit has actually returned its borrowed view.
        isBorrowed = false
        restorationHost.untrackFullscreenRestoration(self)
        self.restorationHost = nil
        originWindow = nil
        presentationWindow = nil
        capturedPresentationWindow = false
        if isCurrent, let store, let intendedHost {
            WebPane(webView: web, store: store).mount(in: intendedHost)
            intendedHost.needsLayout = true
            intendedHost.layoutSubtreeIfNeeded()
        }
        if let exitRequest { finishExitRequest(exitRequest, restored: true) }
    }
}
