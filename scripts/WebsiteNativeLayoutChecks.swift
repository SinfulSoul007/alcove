import AppKit
import SwiftUI
import WebKit
import CryptoKit

extension WebsiteFullscreenChecks {
    /// Actual visible BrowserUI startup and resizing, without website fullscreen.
    /// Fresh processes distinguish production behavior from sizing controls.
    @available(macOS 15.4, *) @MainActor
    static func exerciseNativeLayout(base: URL, kind: String, owned: OwnedWebsiteStores,
                                     controllers: OwnedExtensionControllers) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alcove-native-layout-" + UUID().uuidString)
        let isPrivate = kind != "layout-normal-production"
        let fixtureKey = SymmetricKey(size: .bits256)
        var keyReads = 0
        let store = BrowserStore(isPrivate: isPrivate, dataRoot: root, keyProvider: { _ in
            keyReads += 1; return fixtureKey
        })
        store.finishOnboarding(); store.preferences.automaticUpdateChecks = false
        if kind == "layout-no-motion-production" {
            var appearance = store.appearance; appearance.animationsEnabled = false; store.appearance = appearance
        }
        if kind == "layout-collapsed-production" { store.sidebarVisible = false }
        let normalProfile: UUID?
        if isPrivate { normalProfile = nil }
        else {
            let profile = try store.createProfile(name: "Owned native layout profile")
            normalProfile = profile; try owned.register(profile)
            if let controller = store.profiles.first(where: { $0.id == profile })?.extensionControllerID {
                try controllers.register(controller)
            }
        }
        let id = store.newTab(url: base.appendingPathComponent("page-no-media"))
        if kind == "layout-single-tab-production" {
            for other in store.space.tabs.map(\.id) where other != id { store.close(other) }
        }
        let web = store.view(for: id)
        if let normalProfile {
            check(store.profileID(for: web) == normalProfile && web.configuration.websiteDataStore.identifier == normalProfile,
                  "Normal native layout uses its registered disposable named profile")
        }
        let app = AppDelegate(), owner = app.makeOwner(store)
        app.normalOwner = owner
        var preparedChrome: NativeWindowChrome?
        let window: NSWindow
        print("FULLSCREEN_LAYOUT_PHASE", kind, "mount")
        if ["layout-production", "layout-normal-production", "layout-no-motion-production", "layout-collapsed-production", "layout-single-tab-production"].contains(kind) {
            app.openPrimary(owner)
            guard let primary = app.primaryOwners.first(where: { $0.value === owner })?.key else {
                throw Failure.fixture("actual production layout window")
            }
            window = primary
        } else {
            let control = ExtensionCommandWindow(contentRect: NSRect(x: 0, y: 0, width: 1260, height: 820),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            control.isReleasedWhenClosed = false
            control.titlebarAppearsTransparent = true; control.titleVisibility = .hidden
            control.minSize = NSSize(width: 800, height: 540)
            control.extensionStore = store; control.extensionCommandSource = { [weak store] in store?.currentView }
            if kind == "layout-preconfigured-control" {
                preparedChrome = NativeWindowChrome()
                preparedChrome?.attach(to: control)
            }
            let browser = BrowserUI(store: store).environmentObject(app.updates)
            if kind == "layout-content-minimum-control" {
                let hosting = NSHostingView(rootView: browser.frame(minWidth: 800, minHeight: 540))
                hosting.safeAreaRegions = []; hosting.sizingOptions = [.minSize]
                control.contentView = hosting
            } else {
                let hosting = NSHostingView(rootView: browser)
                hosting.safeAreaRegions = []
                hosting.sizingOptions = kind == "layout-minimum-control" ? [.minSize] : []
                control.contentView = hosting
            }
            window = control
        }
        defer {
            window.performClose(nil); window.contentView = nil; window.close()
            owner.shutdown(); store.shutdown()
            if isPrivate {
                check(keyReads == 0 && !FileManager.default.fileExists(atPath: store.sessionURL.path),
                      "Native layout fixtures never read a metadata key or save a private session")
            } else {
                check(keyReads > 0 && FileManager.default.fileExists(atPath: store.sessionURL.path),
                      "Normal layout fixtures use their injected key and disposable saved session")
            }
            try? FileManager.default.removeItem(at: root)
            withExtendedLifetime(preparedChrome) {}
        }
        print("FULLSCREEN_LAYOUT_CONTEXT", kind, "private", isPrivate, "tabs", store.space.tabs.count,
              "animations", store.appearance.animationsEnabled, "sidebar", store.sidebarVisible)
        print("FULLSCREEN_LAYOUT_PHASE", kind, "show")
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        try await wait("visible native layout source") {
            guard window.isVisible, web.window === window else { return false }
            return (try? await web.evaluateJavaScript("document.visibilityState==='visible'&&document.getElementById('draft')!==null")) as? Bool == true
        }
        print("FULLSCREEN_LAYOUT_PHASE", kind, "ready")
        _ = try await web.evaluateJavaScript("document.getElementById('draft').value='native layout draft';window.ownedLayoutToken=73;true")
        let document = store.documentIdentity(for: web)
        check(window.toolbarStyle == .unifiedCompact && window.toolbar != nil,
              "The visible browser root uses its actual native compact window chrome")
        print("FULLSCREEN_LAYOUT_INITIAL_METRICS", kind, "frame", window.frame.size, "minimum", window.minSize,
              "contentMinimum", window.contentMinSize, "web", web.bounds.size)
        check(window.minSize.width >= 800 && window.minSize.height >= 540,
              "Visible browser startup retains its configured usable minimum after SwiftUI content installation")
        guard let screenBounds = (window.screen ?? NSScreen.main)?.visibleFrame, screenBounds.width >= 800, screenBounds.height >= 600 else {
            throw Failure.fixture("adequate native layout display")
        }
        print("FULLSCREEN_LAYOUT_SCREEN", screenBounds)
        for size in [NSSize(width: 1000, height: 640), NSSize(width: 800, height: 600), NSSize(width: 950, height: 620)] {
            let target = NSSize(width: min(size.width, screenBounds.width), height: min(size.height, screenBounds.height))
            print("FULLSCREEN_LAYOUT_PHASE", kind, "resize", target)
            window.setFrame(NSRect(origin: screenBounds.origin, size: target), display: true)
            window.contentView?.layoutSubtreeIfNeeded()
            let fitted = await effect {
                abs(window.frame.width - target.width) < 1 && abs(window.frame.height - target.height) < 1 &&
                    web.window === window && web.bounds.width > 80 && web.bounds.height > 80
            }
            print("FULLSCREEN_LAYOUT_METRICS", kind, "target", target, "frame", window.frame.size,
                  "minimum", window.minSize, "web", web.bounds.size, "mounted", web.window === window, "fitted", fitted)
            check(fitted,
                  "Native browser resizing gives the requested window size and a usable website at \(Int(target.width))×\(Int(target.height))")
        }
        print("FULLSCREEN_LAYOUT_PHASE", kind, "sidebar-hide")
        store.sidebarVisible = false
        let hidden = await effect { window.contentView?.needsLayout == false }
        print("FULLSCREEN_LAYOUT_PHASE", kind, "sidebar-show-theme")
        store.sidebarVisible = true; store.setTheme(.midnight)
        let visible = await effect { web.window === window && web.bounds.width > 80 && web.bounds.height > 80 }
        let draft = (try? await web.evaluateJavaScript("document.getElementById('draft').value==='native layout draft'&&window.ownedLayoutToken===73")) as? Bool
        check(hidden && visible && store.views[id] === web && store.documentIdentity(for: web) === document && draft == true,
              "Visible native resizing, sidebar changes and theming preserve the exact page and unsaved form")
        check(window.minSize.width >= 800 && window.minSize.height >= 540,
              "Sidebar and theme updates preserve the browser's usable resize limit")
        print("FULLSCREEN_LAYOUT_CASE_COMPLETED", kind)
    }
}
