import AppKit
import SwiftUI
import WebKit
import CryptoKit

/// Characterization controls use the real components, with the same live page.
/// They localize layout notices; they cannot qualify the complete BrowserUI.
@MainActor private struct NativeLayoutComponentRoot: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var chrome: NativeWindowChrome
    @StateObject private var reveal = SidebarRevealController()
    let web: WKWebView
    let kind: String

    var body: some View {
        Group {
            if kind == "layout-ignored-safe-area-control" {
                GeometryReader { _ in
                    componentContent.frame(maxWidth: .infinity, maxHeight: .infinity).ignoresSafeArea()
                }
            } else if ["layout-progress-control", "layout-content-frame-control"].contains(kind) {
                VStack(spacing: 0) {
                    Color.clear.frame(height: max(0, chrome.pageTopInset - 8))
                    if kind == "layout-progress-control" {
                        ProgressView(value: web.estimatedProgress).progressViewStyle(.linear)
                            .tint(.purple).frame(height: 2)
                    }
                    WebPane(webView: web, store: store)
                }
                .background(store.activeTheme.isDark ? Color(red: 0.095, green: 0.09, blue: 0.12) : .white)
                .clipShape(RoundedRectangle(cornerRadius: store.appearance.cornerRadius))
                .padding(8).padding(.leading, store.sidebarVisible ? 260 : 0)
            } else if kind == "layout-full-sidebar-control" {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        if store.sidebarVisible {
                            BrowserSidebar(store: store, chrome: chrome, reveal: reveal, width: 260,
                                           windowHeight: geometry.size.height, motion: nil,
                                           interactionBlocked: false, resizing: false).frame(width: 260)
                        }
                        WebPane(webView: web, store: store).padding(8)
                    }
                }
            } else if kind == "layout-store-sheet-control" {
                componentContent.sheet(item: Binding(get: {
                    store.presentedPanel == .spaces ? nil : store.presentedPanel
                }, set: { next in
                    if next != nil || store.presentedPanel != .spaces { store.presentedPanel = next }
                })) { _ in Text("Owned layout fixture panel") }
            } else if kind == "layout-tracking-control" {
                componentContent.overlay(alignment: .leading) {
                    SidebarTracking(controller: reveal, region: .edge, enabled: !store.sidebarVisible).frame(width: 8)
                }
                .onAppear { reveal.setEnabled(!store.sidebarVisible) }
                .onChange(of: store.sidebarVisible) { _, value in reveal.setEnabled(!value) }
            } else if kind == "layout-chrome-feedback-control" { chromeFeedback }
            else { componentContent }
        }
        .background { store.activeTheme.surface }
        .foregroundStyle(store.activeTheme.ink)
        .preferredColorScheme(store.activeTheme.isDark ? .dark : .light)
        .background {
            if kind == "layout-chrome-reader-control" { NativeChromeReader(chrome: chrome) }
        }
    }

    private var componentContent: some View {
        HStack(spacing: 0) {
            if store.sidebarVisible {
                sidebar.frame(width: 260)
            }
            WebPane(webView: web, store: store).padding(8)
        }
    }

    /// Match the production feedback path: measured toolbar dimensions drive
    /// the page clearance and two mounted pinned/collapsed navigation readers.
    private var chromeFeedback: some View {
        GeometryReader { _ in
            ZStack(alignment: .leading) {
                WebPane(webView: web, store: store).padding(8)
                    .padding(.top, max(0, (store.sidebarVisible ? chrome.pageTopInset : max(chrome.height, chrome.pageTopInset)) - 8))
                    .padding(.leading, store.sidebarVisible ? 260 : 0)
                HStack {
                    Color.clear.frame(width: max(0, chrome.leadingEdge - 17))
                    Text("Show Sidebar"); Spacer(minLength: 0)
                }.frame(height: store.sidebarVisible ? 0 : chrome.height).clipped()
                    .background(NativeChromeReader(chrome: chrome))
                    .frame(maxHeight: .infinity, alignment: .top)
                    .opacity(store.sidebarVisible ? 0 : 1)
                VStack {
                    Text("Navigation").frame(height: chrome.height)
                        .background(NativeChromeReader(chrome: chrome))
                    Spacer(minLength: 0)
                }.frame(width: 260)
                    .offset(x: store.sidebarVisible ? 0 : -276)
                    .opacity(store.sidebarVisible ? 1 : 0)
            }
        }
    }

    @ViewBuilder private var sidebar: some View {
        let tabs = store.space.tabs.filter { !$0.url.isEmpty }
        if kind == "layout-resize-grip-control" {
            Color.clear.overlay(alignment: .trailing) {
                SidebarResizeHandle(interactionEnabled: store.sidebarVisible, width: 260,
                                    canInteract: { store.sidebarVisible },
                                    onBegin: { reveal.beginResize() }, onDrag: { _ in },
                                    onEnd: { reveal.endResize() }, onCancel: { reveal.endResize() },
                                    onReset: {}, onSetWidth: { _ in },
                                    onFocusChange: { reveal.setKeyboardFocus($0) }).frame(width: 6)
            }
        } else if kind == "layout-native-menus-control" {
            HStack {
                Menu {
                    Button("Manage Spaces…") { store.showSpacesManager() }
                    Menu("Theme") {
                        ForEach(SidebarTheme.allCases) { choice in Button(choice.name) { store.setTheme(choice) } }
                    }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 20)
                Menu {
                    Button("Settings…") { store.settingsVisible = true }
                    ForEach(store.session.spaces) { space in Button(space.name) { store.selectSpace(space.id) } }
                } label: { Image(systemName: "plus").font(.system(size: 15)) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 20)
            }
        } else if kind == "layout-address-controls-control" {
            HStack {
                ReaderControl(store: store, web: web)
                ExtensionControls(store: store, web: web).frame(width: 22, height: 26)
            }
        } else if kind == "layout-tracking-control" {
            Color.clear
                .background(SidebarTracking(controller: reveal, region: .panel,
                                            enabled: !store.sidebarVisible && reveal.revealed))
                .modifier(SidebarSpaceSwipeRegion(spaces: .init(current: store.space.id, previous: nil, next: nil),
                                                 reveal: reveal, enabled: true, motion: nil,
                                                 select: { store.selectSpace($0) }))
        } else if kind == "layout-sidebar-saved-control" {
            SidebarSavedTabs(store: store, theme: store.activeTheme, appearance: store.appearance,
                             motion: nil, height: 120, layout: store.sidebarLists.saved, collapsed: false)
        } else if kind == "layout-sidebar-row-control", let tab = tabs.first {
            SidebarTabRow(tab: tab, spaceID: store.space.id, store: store,
                          theme: store.activeTheme, appearance: store.appearance, motion: nil)
        } else if kind == "layout-sidebar-scroll-control" {
            SidebarTabScrollView(positions: sidebarTabPositions(tabs), focusedTab: store.focusedID,
                                 theme: store.activeTheme, motion: nil) {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(tabs) { tab in
                        SidebarTabRow(tab: tab, spaceID: store.space.id, store: store,
                                      theme: store.activeTheme, appearance: store.appearance, motion: nil)
                            .sidebarTabScrollTarget(tab.id)
                    }
                }.padding(.horizontal, 8)
            }
        } else { Color.clear }
    }
}

extension WebsiteFullscreenChecks {
    /// Actual visible BrowserUI startup and resizing, without website fullscreen.
    /// Fresh processes distinguish production behavior from sizing controls.
    @available(macOS 15.4, *) @MainActor
    static func exerciseNativeLayout(base: URL, kind: String, owned: OwnedWebsiteStores,
                                     controllers: OwnedExtensionControllers) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alcove-native-layout-" + UUID().uuidString)
        let suiteName = "Alcove.NativeLayout." + UUID().uuidString
        let sidebarDefaults = kind == "layout-isolated-defaults-control" ? UserDefaults(suiteName: suiteName) : nil
        if let sidebarDefaults, let saved = UserDefaults.standard.object(forKey: "sidebarWidth") {
            sidebarDefaults.set(saved, forKey: "sidebarWidth")
        }
        defer { sidebarDefaults?.removePersistentDomain(forName: suiteName) }
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
            let componentControl = ["layout-web-content-control", "layout-chrome-reader-control",
                                    "layout-sidebar-row-control", "layout-sidebar-scroll-control",
                                    "layout-sidebar-saved-control", "layout-chrome-feedback-control",
                                    "layout-native-menus-control", "layout-address-controls-control",
                                    "layout-tracking-control", "layout-store-sheet-control",
                                    "layout-full-sidebar-control", "layout-progress-control",
                                    "layout-content-frame-control", "layout-resize-grip-control",
                                    "layout-ignored-safe-area-control"].contains(kind)
            if kind == "layout-preconfigured-control" || componentControl {
                preparedChrome = NativeWindowChrome()
                preparedChrome?.attach(to: control)
            }
            let browser = BrowserUI(store: store, sidebarDefaults: sidebarDefaults).environmentObject(app.updates)
            if componentControl, let preparedChrome {
                let component = NativeLayoutComponentRoot(store: store, chrome: preparedChrome, web: web, kind: kind)
                    .environmentObject(app.updates)
                let hosting = NSHostingView(rootView: component.frame(minWidth: 800, minHeight: 540))
                hosting.safeAreaRegions = []; hosting.sizingOptions = [.minSize]
                control.contentView = hosting
            } else if ["layout-content-minimum-control", "layout-isolated-defaults-control"].contains(kind) {
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
        print("FULLSCREEN_LAYOUT_FOCUS", kind, "show", window.firstResponder.map { String(describing: type(of: $0)) } ?? "none")
        try await wait("visible native layout source") {
            guard window.isVisible, web.window === window else { return false }
            return (try? await web.evaluateJavaScript("document.visibilityState==='visible'&&document.getElementById('draft')!==null")) as? Bool == true
        }
        print("FULLSCREEN_LAYOUT_PHASE", kind, "ready")
        print("FULLSCREEN_LAYOUT_FOCUS", kind, "ready", window.firstResponder.map { String(describing: type(of: $0)) } ?? "none")
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
