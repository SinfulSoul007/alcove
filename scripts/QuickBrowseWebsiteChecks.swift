import AppKit
import Darwin
import WebKit
import CryptoKit
import BrowserCore

enum QuickWebsiteError: Error { case fixtureMissing, timedOut }
@MainActor final class ResponsePolicyProbe: NSObject, WKNavigationDelegate {
    weak var store: BrowserStore?
    let unowned: WKWebView
    var unownedPolicy: WKNavigationResponsePolicy?
    init(store: BrowserStore) {
        self.store = store
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        unowned = WKWebView(frame: .zero, configuration: config)
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let store else { decisionHandler(.cancel); return }
        store.webView(webView, decidePolicyFor: action, decisionHandler: decisionHandler)
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard let store else { decisionHandler(.cancel); return }
        store.webView(unowned, decidePolicyFor: response) { self.unownedPolicy = $0 }
        store.webView(webView, decidePolicyFor: response, decisionHandler: decisionHandler)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { store?.webView(webView, didFinish: navigation) }
}

@main struct QuickBrowseWebsiteChecks {
    @MainActor static func ready(_ web: WKWebView, url: URL) async throws {
        let data = try JSONSerialization.data(withJSONObject: [url.absoluteString])
        let quoted = String(decoding: data, as: UTF8.self).dropFirst().dropLast()
        for _ in 0..<1000 {
            if (try? await web.evaluateJavaScript("window.alcoveFixtureReady === true && location.href === \(quoted)")) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw QuickWebsiteError.timedOut
    }
    @MainActor static func main() async throws {
        _ = NSApplication.shared; setbuf(stdout, nil)
        let owned = try OwnedWebsiteStores()
        if CommandLine.arguments.contains("--cleanup-owned-stores") { exit(await owned.cleanup() ? 0 : 1) }
        guard await owned.cleanup() else { exit(1) }
        var failures = 0
        func check(_ value: Bool, _ name: String) { print("\(value ? "PASS" : "FAIL"): \(name)"); if !value { failures += 1 } }
        guard let address = ProcessInfo.processInfo.environment["ALCOVE_PROFILE_FIXTURE_URL"], let fixture = URL(string: address) else { throw QuickWebsiteError.fixtureMissing }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256)
        let store = BrowserStore(dataRoot: root, keyProvider: { _ in key })
        let a = try store.createProfile(name: "Quick A"); let spaceA = store.space.id; try owned.register(a)
        let initial = URL(string: "redirect?context=Quick-A", relativeTo: fixture)!.absoluteURL
        let landing = URL(string: "?context=Quick-A", relativeTo: fixture)!.absoluteURL
        let quickA = try store.openQuickPage(url: initial, profileID: a, intendedSpaceID: spaceA)
        var webA: WKWebView? = store.view(for: quickA)
        webA!.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        var probe: ResponsePolicyProbe? = ResponsePolicyProbe(store: store); webA!.navigationDelegate = probe
        try await ready(webA!, url: landing)
        check(probe!.unownedPolicy == .cancel, "A real stale response cannot navigate or start a download from an unowned page")
        let repeated = try store.openQuickPage(url: initial, profileID: a)
        check(repeated == quickA && store.views[quickA] === webA, "Repeating a real redirected external URL retains its existing live page")
        _ = try await webA!.evaluateJavaScript("document.cookie='alcove_quick=A; path=/; SameSite=Lax'; localStorage.setItem('alcove_quick','A'); true")
        let b = try store.createProfile(name: "Quick B"); try owned.register(b); let tabB = store.selectedID!
        let urlB = URL(string: "?context=Quick-B", relativeTo: fixture)!.absoluteURL
        store.update(tabB) { $0.url = urlB.absoluteString }
        var webB: WKWebView? = store.view(for: tabB); try await ready(webB!, url: urlB)
        check((try await webB!.evaluateJavaScript("document.cookie === '' && localStorage.getItem('alcove_quick') === null")) as? Bool == true, "A Quick Browse account is isolated from another profile on the same actual website")
        _ = try await webB!.evaluateJavaScript("document.cookie='alcove_quick=B; path=/; SameSite=Lax'; localStorage.setItem('alcove_quick','B'); true")
        let next = URL(string: "?context=Quick-A-next", relativeTo: fixture)!.absoluteURL
        try store.navigateQuickPage(quickA, input: next.absoluteString); try await ready(webA!, url: next)
        let requestCount: Any? = try await withCheckedThrowingContinuation { continuation in
            webA!.callAsyncJavaScript("const response = await fetch('/__count?path=' + encodeURIComponent('/?context=Quick-A-next')); return (await response.json()).count", arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let value): continuation.resume(returning: value)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
        check((requestCount as? Int) == 1, "Quick address submission sends exactly one navigation request")
        _ = try await webA!.evaluateJavaScript("window.alcoveHandoffToken='quick-form-token';const input=document.createElement('input');input.id='unsaved';input.value='keep my unsaved form';document.body.appendChild(input);document.body.style.height='5000px';window.scrollTo(0,900);true")
        let backCount = webA!.backForwardList.backList.count
        _ = try store.promoteQuickPage(quickA, to: spaceA)
        let retainedForm = (try await webA!.evaluateJavaScript("window.alcoveHandoffToken === 'quick-form-token' && document.getElementById('unsaved').value === 'keep my unsaved form'")) as? Bool == true
        check(store.views[quickA] === webA && retainedForm, "Same-profile handoff preserves a real document and unsaved form without reloading")
        check(webA!.backForwardList.backList.count == backCount && backCount > 0 && webA!.url == next, "Same-profile handoff preserves its real navigation history and location")
        check((try await webA!.evaluateJavaScript("Math.round(window.scrollY) === 900")) as? Bool == true, "Same-profile handoff preserves the actual scroll position")
        let sourceURL = URL(string: "?context=Quick-A-source", relativeTo: fixture)!.absoluteURL
        let source = try store.openQuickPage(url: sourceURL, profileID: a, intendedSpaceID: spaceA)
        var sourceWeb: WKWebView? = store.view(for: source); try await ready(sourceWeb!, url: sourceURL)
        let independentPrimaryURL = URL(string: "?context=independent-primary", relativeTo: fixture)!.absoluteURL
        store.openPeek(independentPrimaryURL, from: webA!)
        var independentPrimary: WKWebView? = store.primaryPeekView; try await ready(independentPrimary!, url: independentPrimaryURL)
        _ = try await independentPrimary!.evaluateJavaScript("window.independentForm='primary';true")
        let independentAURL = URL(string: "?context=independent-A", relativeTo: fixture)!.absoluteURL
        store.openPeek(independentAURL, from: sourceWeb!)
        var independentA: WKWebView? = store.quickPeekView(source); try await ready(independentA!, url: independentAURL)
        _ = try await independentA!.evaluateJavaScript("window.independentForm='quick-A';true")
        _ = try await sourceWeb!.evaluateJavaScript("window.coveredParentForm='keep this form';true")
        let peekNextURL = URL(string: "?context=independent-A-next", relativeTo: fixture)!.absoluteURL
        independentA!.load(URLRequest(url: peekNextURL)); try await ready(independentA!, url: peekNextURL)
        store.performQuickNavigation(source, action: .back); try await ready(independentA!, url: independentAURL)
        check(store.foregroundQuickView(source) === independentA && sourceWeb!.url == sourceURL, "Compact navigation and shortcut resolution use the visible Peek's distinct history")
        store.performQuickNavigation(source, action: .forward); try await ready(independentA!, url: peekNextURL)
        _ = try await independentA!.evaluateJavaScript("window.peekReloadToken='discard on reload';true")
        store.performQuickNavigation(source, action: .reload); try await ready(independentA!, url: peekNextURL)
        let initialReloadState = (try? await independentA!.evaluateJavaScript("window.peekReloadToken === undefined")) as? Bool == true
        let parentBeforeReloadWait = (try? await sourceWeb!.evaluateJavaScript("window.coveredParentForm === 'keep this form'")) as? Bool == true
        var peekReloaded = false
        for _ in 0..<1000 {
            if (try? await independentA!.evaluateJavaScript("window.alcoveFixtureReady === true && window.peekReloadToken === undefined")) as? Bool == true { peekReloaded = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        if !initialReloadState { print("INFO: Reload initially exposed the old Peek document; covered parent form intact: \(parentBeforeReloadWait).") }
        let parentFormKept = (try await sourceWeb!.evaluateJavaScript("window.coveredParentForm === 'keep this form'")) as? Bool == true
        check(peekReloaded && parentFormKept && sourceWeb!.url == sourceURL, "Reloading the visible quick Peek preserves its covered parent's real unsaved form")
        let peekAddressURL = URL(string: "?context=independent-A-address", relativeTo: fixture)!.absoluteURL
        try store.navigateForegroundQuickPage(source, input: peekAddressURL.absoluteString); try await ready(independentA!, url: peekAddressURL)
        check(sourceWeb!.url == sourceURL && store.quickPage(source)?.tab.url == sourceURL.absoluteString, "Entering an address for a visible Peek navigates only that preview and preserves the quick parent's saved location")
        _ = try await independentA!.evaluateJavaScript("window.independentForm='quick-A';true")
        let otherQuick = try store.openQuickPage(url: urlB, profileID: b)
        var otherQuickWeb: WKWebView? = store.view(for: otherQuick); try await ready(otherQuickWeb!, url: urlB)
        let independentBURL = URL(string: "?context=independent-B", relativeTo: fixture)!.absoluteURL
        store.openPeek(independentBURL, from: otherQuickWeb!)
        var independentB: WKWebView? = store.quickPeekView(otherQuick); try await ready(independentB!, url: independentBURL)
        _ = try await independentB!.evaluateJavaScript("window.independentForm='quick-B';true")
        let beforeIndependentFailure = try Data(contentsOf: store.sessionURL)
        store.vault = MetadataStore(url: root, key: key)
        var independentCloseRejected = false
        do { try store.closeQuickPage(source) } catch { independentCloseRejected = true }
        let afterIndependentFailure = try Data(contentsOf: store.sessionURL)
        check(independentCloseRejected && beforeIndependentFailure == afterIndependentFailure && store.quickPeekView(source) === independentA && store.quickPeekView(otherQuick) === independentB && store.primaryPeekView === independentPrimary, "A failed quick close preserves all three independent native Peek contexts and prior ciphertext")
        store.unlockLocalData(keyProvider: { key })
        for _ in 0..<500 where store.unlocking { try await Task.sleep(for: .milliseconds(10)) }
        let quickBAfterUnlock = (try? await independentB!.evaluateJavaScript("window.independentForm === 'quick-B'")) as? Bool == true
        check(store.savingEnabled && store.primaryPeekView === independentPrimary && store.quickPeekView(source) === independentA && store.quickPeekView(otherQuick) === independentB && quickBAfterUnlock, "Unlock retains every independently owned Peek rather than only the most recently opened preview")
        let primaryFormKept = (try? await independentPrimary!.evaluateJavaScript("window.independentForm === 'primary'")) as? Bool == true
        let quickAFormKept = (try? await independentA!.evaluateJavaScript("window.independentForm === 'quick-A'")) as? Bool == true
        check(primaryFormKept && quickAFormKept && store.profileID(for: independentPrimary!) == a && store.profileID(for: independentA!) == a, "Opening independent Peeks in two quick windows preserves the primary and first quick window's real forms and ownership")
        store.webViewDidClose(independentB!)
        let quickAAfterClose = (try? await independentA!.evaluateJavaScript("window.independentForm === 'quick-A'")) as? Bool == true
        check(quickAAfterClose && store.profileID(for: independentA!) == a, "Closing one quick Peek cannot destroy another window's live form")
        store.openPeek(independentPrimaryURL, from: webA!)
        independentPrimary = store.primaryPeekView; try await ready(independentPrimary!, url: independentPrimaryURL)
        _ = try store.promoteQuickPage(otherQuick)
        check(store.activeProfileID == b && store.primaryPeekView == nil, "Promoting another profile's quick page dismisses an unrelated primary Peek before showing the destination account")
        let quickAAfterHandoff = (try? await independentA!.evaluateJavaScript("window.independentForm === 'quick-A'")) as? Bool == true
        check(store.profileID(for: independentA!) == a && quickAAfterHandoff, "A handoff into the main window preserves an unrelated quick window's live Peek")
        store.webViewDidClose(independentA!); store.webViewDidClose(independentPrimary!)
        independentPrimary = nil; independentA = nil; independentB = nil; otherQuickWeb = nil
        try store.assignProfile(b, to: spaceA)
        let peekURL = URL(string: "?context=Quick-A-peek", relativeTo: fixture)!.absoluteURL
        store.openPeek(peekURL, from: sourceWeb!)
        var peek: WKWebView? = store.quickPeekView(source); try await ready(peek!, url: peekURL)
        // expandPeek is now a window-bound UI request; mount this owned real page without showing a window.
        let peekWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [], backing: .buffered, defer: false)
        peekWindow.isReleasedWhenClosed = false
        let peekHost = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600)); peekWindow.contentView = peekHost
        peekHost.addSubview(peek!)
        _ = try await peek!.evaluateJavaScript("window.alcovePeekToken='peek-form-token';const input=document.createElement('input');input.id='peek-unsaved';input.value='keep the peek form';document.body.appendChild(input);true")
        let beforeFailedPeek = try Data(contentsOf: store.sessionURL)
        store.vault = MetadataStore(url: root, key: key); store.expandPeek(in: .quick(source))
        let afterFailedPeek = try Data(contentsOf: store.sessionURL)
        check(!store.savingEnabled && store.quickPeekView(source) === peek && store.activeProfileID == b && beforeFailedPeek == afterFailedPeek, "A failed Peek handoff preserves the live form and original metadata before native teardown")
        store.unlockLocalData(keyProvider: { key })
        for _ in 0..<500 where store.unlocking { try await Task.sleep(for: .milliseconds(10)) }
        let recoveredPeekForm = (try? await peek!.evaluateJavaScript("window.alcovePeekToken === 'peek-form-token' && document.getElementById('peek-unsaved')?.value === 'keep the peek form'")) as? Bool == true
        check(store.savingEnabled && store.quickPeekView(source) === peek && recoveredPeekForm, "Unlock preserves a real still-owned Peek form after a failed handoff")
        if store.quickPeekView(source) == nil {
            store.openPeek(peekURL, from: sourceWeb!); peek = store.quickPeekView(source); try await ready(peek!, url: peekURL)
            peekHost.addSubview(peek!)
            _ = try await peek!.evaluateJavaScript("window.alcovePeekToken='peek-form-token';const input=document.createElement('input');input.id='peek-unsaved';input.value='keep the peek form';document.body.appendChild(input);true")
        }
        var atomicPeekExposure = false
        store.quickPagesDidChange = {
            if let id = store.selectedID, store.profileID(for: id) == a { atomicPeekExposure = store.view(for: id) === peek }
        }
        store.expandPeek(in: .quick(source)); store.quickPagesDidChange = nil
        let adoptedID = store.selectedID!; var adoptedPeek: WKWebView? = store.view(for: adoptedID)
        try await ready(adoptedPeek!, url: peekURL)
        check(store.activeProfileID == a && adoptedPeek === peek && atomicPeekExposure, "Quick Peek promotes into its captured profile with its live page installed before publication")
        check((try await adoptedPeek!.evaluateJavaScript("window.alcovePeekToken === 'peek-form-token' && document.getElementById('peek-unsaved')?.value === 'keep the peek form'")) as? Bool == true, "Promoting Quick Peek preserves its real unsaved form")
        check((try await adoptedPeek!.evaluateJavaScript("document.cookie === 'alcove_quick=A' && localStorage.getItem('alcove_quick') === 'A'")) as? Bool == true, "Promoting Quick Peek cannot inherit whichever other profile became active")
        try store.changeQuickProfile(source, to: b, rememberHost: true, allowReload: true)
        var crossed: WKWebView? = store.view(for: source); try await ready(crossed!, url: sourceURL)
        let crossedAccount = (try await crossed!.evaluateJavaScript("document.cookie === 'alcove_quick=B' && localStorage.getItem('alcove_quick') === 'B'")) as? Bool == true
        check(crossed !== sourceWeb && crossedAccount, "An explicit quick-profile change reloads with the destination account without copying cookies")
        let privateRoot = root.appendingPathComponent("private")
        let privateStore = BrowserStore(isPrivate: true, dataRoot: privateRoot, keyProvider: { _ in fatalError("Private quick website requested metadata key") })
        let privateURL = URL(string: "?context=Quick-private", relativeTo: fixture)!.absoluteURL
        let privateID = try privateStore.openQuickPage(url: privateURL, profileID: a)
        var privateWeb: WKWebView? = privateStore.view(for: privateID); try await ready(privateWeb!, url: privateURL)
        check((try await privateWeb!.evaluateJavaScript("document.cookie === '' && localStorage.getItem('alcove_quick') === null")) as? Bool == true, "A real private quick page cannot read either normal profile's account")
        _ = try await privateWeb!.evaluateJavaScript("window.privateHandoffToken='private-only';true")
        _ = try privateStore.promoteQuickPage(privateID)
        let retainedPrivate = (try await privateWeb!.evaluateJavaScript("window.privateHandoffToken === 'private-only'")) as? Bool == true
        check(privateStore.views[privateID] === privateWeb && retainedPrivate && !FileManager.default.fileExists(atPath: privateRoot.path), "Private handoff preserves its document without creating normal metadata")
        let clearAURL = URL(string: "?context=clear-peek-A", relativeTo: fixture)!.absoluteURL
        store.openPeek(clearAURL, from: adoptedPeek!)
        var clearingPeekA: WKWebView? = store.primaryPeekView; try await ready(clearingPeekA!, url: clearAURL)
        let clearBURL = URL(string: "?context=clear-peek-B", relativeTo: fixture)!.absoluteURL
        store.openPeek(clearBURL, from: crossed!)
        var clearingPeekB: WKWebView? = store.quickPeekView(source); try await ready(clearingPeekB!, url: clearBURL)
        _ = try await clearingPeekB!.evaluateJavaScript("window.clearIsolationForm='keep B';true")
        try await store.clearProfileData(a)
        let bPeekKept = (try? await clearingPeekB!.evaluateJavaScript("window.clearIsolationForm === 'keep B'")) as? Bool == true
        check(store.primaryPeekView == nil && store.quickPeekView(source) === clearingPeekB && bPeekKept, "Actual profile clearing closes all of its own Peek contexts and preserves another profile's live preview form")
        store.webViewDidClose(clearingPeekB!); clearingPeekA = nil; clearingPeekB = nil
        let untouchedB = (try await webB!.evaluateJavaScript("document.cookie === 'alcove_quick=B' && localStorage.getItem('alcove_quick') === 'B'")) as? Bool == true
        check(store.quickPages(for: a).isEmpty && untouchedB, "Actual website clearing closes only the chosen profile's quick pages and preserves the other account")
        for space in store.session.spaces where space.effectiveProfileID == a { try store.assignProfile(BrowserProfile.defaultID, to: space.id) }
        let deletionURL = URL(string: "?context=Quick-delete", relativeTo: fixture)!.absoluteURL
        let deletionID = try store.openQuickPage(url: deletionURL, profileID: a)
        var deletionWeb: WKWebView? = store.view(for: deletionID); try await ready(deletionWeb!, url: deletionURL)
        webA = nil; sourceWeb = nil; peek = nil; adoptedPeek = nil; deletionWeb = nil; probe = nil
        try await store.deleteProfile(a)
        check(!(await WKWebsiteDataStore.allDataStoreIdentifiers).contains(a) && store.quickProfileID(source) == b, "Deleting an unused profile with a live quick page actually removes only its named WebKit store")
        peekWindow.contentView = nil; peekWindow.close()
        store.shutdown(); privateStore.shutdown(); crossed = nil; webB = nil; privateWeb = nil
        let clock = ContinuousClock(); let deadline = clock.now.advanced(by: .seconds(5))
        while store.closingPages.contains(where: { $0.webView != nil }) && clock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        store.namedDataStores.removeAll()
        if !(await owned.cleanup()) { failures += 1 }
        exit(failures == 0 ? 0 : 1)
    }
}
