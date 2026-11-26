import AppKit
import SwiftUI
import WebKit
import CryptoKit

extension WebsiteFullscreenChecks {
    /// Actual visible BrowserUI startup and resizing, without website fullscreen.
    /// Fresh processes distinguish production behavior from sizing controls.
    @MainActor static func exerciseNativeLayout(base: URL, kind: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alcove-native-layout-" + UUID().uuidString)
        var keyReads = 0
        let store = BrowserStore(isPrivate: true, dataRoot: root, keyProvider: { _ in
            keyReads += 1; return SymmetricKey(size: .bits256)
        })
        store.finishOnboarding(); store.preferences.automaticUpdateChecks = false
        let id = store.newTab(url: base.appendingPathComponent("page-no-media"))
        let web = store.view(for: id)
        let app = AppDelegate(), owner = app.makeOwner(store)
        app.normalOwner = owner
        var preparedChrome: NativeWindowChrome?
        let window: NSWindow
        if kind == "layout-production" {
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
            let hosting = NSHostingView(rootView: BrowserUI(store: store).environmentObject(app.updates))
            hosting.safeAreaRegions = []
            hosting.sizingOptions = kind == "layout-minimum-control" ? [.minSize] : []
            control.contentView = hosting
            window = control
        }
        defer {
            window.performClose(nil); window.contentView = nil; window.close()
            owner.shutdown(); store.shutdown()
            check(keyReads == 0 && !FileManager.default.fileExists(atPath: store.sessionURL.path),
                  "Native layout fixtures never read a metadata key or save a private session")
            try? FileManager.default.removeItem(at: root)
            withExtendedLifetime(preparedChrome) {}
        }
        print("FULLSCREEN_LAYOUT_CONTEXT", kind, "private", true)
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        try await wait("visible native layout source") {
            guard window.isVisible, web.window === window else { return false }
            return (try? await web.evaluateJavaScript("document.visibilityState==='visible'&&document.getElementById('draft')!==null")) as? Bool == true
        }
        _ = try await web.evaluateJavaScript("document.getElementById('draft').value='native layout draft';window.ownedLayoutToken=73;true")
        let document = store.documentIdentity(for: web)
        check(window.toolbarStyle == .unifiedCompact && window.toolbar != nil,
              "The visible browser root uses its actual native compact window chrome")
        print("FULLSCREEN_LAYOUT_INITIAL_METRICS", kind, "frame", window.frame.size, "minimum", window.minSize,
              "contentMinimum", window.contentMinSize, "web", web.bounds.size)
        for size in [NSSize(width: 1260, height: 820), NSSize(width: 800, height: 600), NSSize(width: 1100, height: 720)] {
            window.setFrame(NSRect(origin: window.frame.origin, size: size), display: true)
            window.contentView?.layoutSubtreeIfNeeded()
            let fitted = await effect {
                abs(window.frame.width - size.width) < 1 && abs(window.frame.height - size.height) < 1 &&
                    web.window === window && web.bounds.width > 80 && web.bounds.height > 80
            }
            print("FULLSCREEN_LAYOUT_METRICS", kind, "target", size, "frame", window.frame.size,
                  "minimum", window.minSize, "web", web.bounds.size, "mounted", web.window === window, "fitted", fitted)
            check(fitted,
                  "Native browser resizing gives the requested window size and a usable website at \(Int(size.width))×\(Int(size.height))")
        }
        store.sidebarVisible = false
        let hidden = await effect { window.contentView?.needsLayout == false }
        store.sidebarVisible = true; store.setTheme(.midnight)
        let visible = await effect { web.window === window && web.bounds.width > 80 && web.bounds.height > 80 }
        let draft = (try? await web.evaluateJavaScript("document.getElementById('draft').value==='native layout draft'&&window.ownedLayoutToken===73")) as? Bool
        check(hidden && visible && store.views[id] === web && store.documentIdentity(for: web) === document && draft == true,
              "Visible native resizing, sidebar changes and theming preserve the exact page and unsaved form")
        print("FULLSCREEN_LAYOUT_CASE_COMPLETED", kind)
    }
}
