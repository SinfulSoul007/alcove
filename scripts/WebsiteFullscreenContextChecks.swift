import AppKit
import SwiftUI
import WebKit
import CryptoKit
import BrowserCore

extension WebsiteFullscreenChecks {
    @available(macOS 15.4, *) @MainActor
    static func exerciseContext(base: URL, context: String, isPrivate: Bool,
                                owned: OwnedWebsiteStores, controllers: OwnedExtensionControllers) async throws {
        let label = "\(isPrivate ? "private" : "regular") \(context)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alcove-fullscreen-context-" + UUID().uuidString)
        let store = BrowserStore(isPrivate: isPrivate, dataRoot: root,
                                 keyProvider: { _ in SymmetricKey(data: Data(repeating: 47, count: 32)) })
        let owner = BrowserWindowOwner(store: store)
        let lease = try owner.acquirePrimary()
        defer { owner.release(lease); store.shutdown(); try? FileManager.default.removeItem(at: root) }
        let profile: UUID
        if isPrivate { profile = BrowserProfile.defaultID }
        else {
            profile = try store.createProfile(name: "Owned fullscreen context")
            try owned.register(profile)
            for item in store.profiles where item.id == profile {
                if let controller = item.extensionControllerID { try controllers.register(controller) }
            }
        }
        store.finishOnboarding()
        let primaryID = store.newTab(url: base.appendingPathComponent("page"))
        let primary = store.view(for: primaryID)
        let rootHost = EdgeToEdgeWebHost(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        let primaryWindow = NSWindow(contentRect: rootHost.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        primaryWindow.isReleasedWhenClosed = false
        primaryWindow.title = "Alcove owned \(label)"
        primaryWindow.contentView = rootHost
        defer { primaryWindow.contentView = nil; primaryWindow.close() }
        WebPane(webView: primary, store: store).mount(in: rootHost)
        primaryWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        var web = primary
        var window = primaryWindow
        var quick: QuickBrowseWindowController?
        defer { quick?.window?.performClose(nil) }
        switch context {
        case "tab": break
        case "split":
            let other = store.newTab(url: base.appendingPathComponent("page"))
            store.select(primaryID)
            guard store.openInSplit(other), let layout = store.splitLayout else { throw Failure.fixture("split layout") }
            let split = NativeBrowserSplit(layout: layout, size: rootHost.frame.size,
                onResize: { store.rememberSplitPaneSizes(for: $0, lengths: $1) },
                pane: { WebPane(webView: store.view(for: $0), store: store) })
            let hosting = NSHostingView(rootView: split)
            hosting.sizingOptions = []; primaryWindow.contentView = hosting; hosting.layoutSubtreeIfNeeded()
            store.focusPane(primaryID)
        case "peek":
            store.openPeek(base.appendingPathComponent("page"), from: primary)
            guard let peek = store.primaryPeekView else { throw Failure.fixture("primary Peek") }
            web = peek
            let peekHost = EdgeToEdgeWebHost(frame: rootHost.bounds.insetBy(dx: 60, dy: 40))
            rootHost.addSubview(peekHost)
            WebPane(webView: web, store: store).mount(in: peekHost)
        case "quick", "quick-peek":
            let page = try store.openQuickPage(url: base.appendingPathComponent("page"), profileID: profile, intendedSpaceID: store.space.id)
            let controller = try QuickBrowseWindowController(owner: owner, pageID: page, requestPrimary: {}, requestProfiles: {}, didClose: {})
            quick = controller; controller.surface()
            guard let quickWeb = controller.activeWebView, let quickWindow = controller.window else { throw Failure.fixture("Quick Browse") }
            web = quickWeb; window = quickWindow
            if context == "quick-peek" {
                store.openPeek(base.appendingPathComponent("page"), from: quickWeb)
                guard let peek = store.quickPeekView(page) else { throw Failure.fixture("Quick Peek") }
                web = peek
            }
        default: throw Failure.fixture("unknown context")
        }
        defer { web.closeAllMediaPresentations(completionHandler: nil) }
        try await wait("\(label) actual host") { web.window === window && web.superview is EdgeToEdgeWebHost }
        try await wait("\(label) document and decoded video") {
            guard !web.isLoading else { return false }
            return (try? await web.evaluateJavaScript("document.getElementById('video')?.readyState>=2")) as? Bool == true
        }
        guard let host = web.superview as? EdgeToEdgeWebHost else { throw Failure.fixture("website host") }
        check(web.configuration.preferences.isElementFullscreenEnabled,
              "\(label): production page configuration enables fullscreen")
        check(store.profileID(for: web) == profile && web.navigationDelegate === store,
              "\(label): actual source belongs to the expected store and profile")
        _ = try await web.evaluateJavaScript("document.getElementById('draft').value='owned context draft';window.ownedDocumentToken=crypto.randomUUID();history.pushState({owned:true},'','#owned');scrollTo(0,320);true")
        let document = store.documentIdentity(for: web)
        let snapshot = "JSON.stringify({token:window.ownedDocumentToken,draft:document.getElementById('draft').value,scroll:scrollY,history:history.length,href:location.href})"
        let before = try await web.evaluateJavaScript(snapshot) as? String
        for target in ["element", "video"] {
            residency("before \(label) \(target)", web: web, host: host, window: window)
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            try await wait("\(label) foreground") { window.isKeyWindow && NSApp.isActive }
            if target == "video" {
                _ = try await web.callAsyncJavaScript("await document.getElementById('video').play();return true;", contentWorld: .page)
            }
            try await enter(web, target: target)
            let presentation = web.window
            check(presentation != nil && presentation !== window && web.superview !== host,
                  "\(label) \(target): real fullscreen uses WebKit's separate window")
            check((web as? SplitDropWebView)?.websiteFullscreen?.logicalWindow === window,
                  "\(label) \(target): logical browser window survives physical fullscreen reparenting")
            host.setFrameSize(NSSize(width: max(300, host.frame.width - 25), height: max(250, host.frame.height - 20)))
            WebPane(webView: web, store: store).mount(in: host); host.layoutSubtreeIfNeeded()
            check(web.window === presentation && web.superview !== host && web.fullscreenState == .inFullscreen,
                  "\(label) \(target): live remount and resize preserve WebKit's presentation")
            try await leave(web)
            do { try await wait("\(label) restored source") { web.superview === host && web.window === window } }
            catch { residency("failed \(label) \(target)", web: web, host: host, window: window); throw error }
            host.layoutSubtreeIfNeeded()
            check(web.frame == host.bounds && web.bounds.width > 0 && web.bounds.height > 0,
                  "\(label) \(target): restored viewport fits its actual host")
            check(store.documentIdentity(for: web) === document && store.profileID(for: web) == profile,
                  "\(label) \(target): source document and profile remain unchanged")
            check((try await web.evaluateJavaScript(snapshot) as? String) == before,
                  "\(label) \(target): actual draft, token, scroll and history survive")
        }
        print("FULLSCREEN_CONTEXT_COMPLETED", label)
    }

    @available(macOS 15.4, *) @MainActor
    static func exerciseContexts(base: URL) async throws {
        let owned = try OwnedWebsiteStores(), controllers = try OwnedExtensionControllers()
        guard await controllers.cleanup(), await owned.cleanup() else { throw Failure.fixture("owned recovery") }
        for isPrivate in [false, true] {
            for context in ["tab", "split", "peek", "quick", "quick-peek"] {
                do { try await exerciseContext(base: base, context: context, isPrivate: isPrivate, owned: owned, controllers: controllers) }
                catch { failures += 1; print("FULLSCREEN_CONTEXT_ERROR", context, "private", isPrivate, error) }
            }
        }
        let extensionCleanup = await controllers.cleanup(), websiteCleanup = await owned.cleanup()
        check(extensionCleanup && websiteCleanup, "All test-owned extension and website stores are released and erased")
        print("FULLSCREEN_CONTEXT_CLEANUP", extensionCleanup, websiteCleanup)
    }
}
