import SwiftUI
import WebKit
import BrowserCore

final class EdgeToEdgeWebHost: NSView {
    func setContent(_ view: NSView) {
        guard subviews.first !== view else { fitContent();return }
        for old in subviews { old.removeFromSuperview() }
        // SwiftUI can replace a split pane between AppKit layout passes. Give WebKit
        // its actual viewport immediately so its remote drawing surface cannot stay zero-sized.
        view.translatesAutoresizingMaskIntoConstraints = true
        view.autoresizingMask = [.width,.height];addSubview(view);fitContent()
        func removeTitlebarInset(_ view: NSView) {
            if let scroll = view as? NSScrollView { scroll.automaticallyAdjustsContentInsets = false; scroll.contentInsets = .init(top: 0, left: 0, bottom: 0, right: 0) }
            for child in view.subviews { removeTitlebarInset(child) }
        }
        removeTitlebarInset(view)
    }
    private func fitContent() {if let view = subviews.first,view.frame != bounds {view.frame = bounds}}
    override func layout() {super.layout();fitContent()}
    override var safeAreaInsets: NSEdgeInsets { .init(top: 0, left: 0, bottom: 0, right: 0) }
}
struct WebPane: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> EdgeToEdgeWebHost {
        let host = EdgeToEdgeWebHost()
        host.setContent(webView)
        return host
    }
    func updateNSView(_ nsView: EdgeToEdgeWebHost, context: Context) { nsView.setContent(webView) }
}

struct BrowserUI: View {
    @ObservedObject var store: BrowserStore
    @EnvironmentObject private var updates: UpdateController
    @AppStorage("sidebarWidth") private var sidebarWidth = 236.0
    @StateObject private var reveal = SidebarRevealController()
    @StateObject private var chrome = NativeWindowChrome()
    @State private var resize = SidebarResizeState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    init(store: BrowserStore, sidebarDefaults: UserDefaults? = nil) {
        self.store = store
        _sidebarWidth = AppStorage(wrappedValue: 236.0, "sidebarWidth", store: sidebarDefaults)
    }
    var sidebarInteractionBlocked: Bool {
        store.commandVisible || store.onboardingVisible || store.primaryPeekView != nil || store.presentedPanel != nil
    }
    var sheetPanel: Binding<BrowserPanel?> {
        Binding(get:{ store.presentedPanel == .spaces ? nil : store.presentedPanel },set:{ next in
            if next != nil || store.presentedPanel != .spaces { store.presentedPanel = next }
        })
    }
    var theme: AppearanceTheme { store.activeTheme }
    var appearance: AppearanceSettings { store.appearance }
    var motion: Animation? { reduceMotion || !appearance.animationsEnabled ? nil : .spring(response: 0.28, dampingFraction: 0.88) }
    var pins: [BrowserCore.Tab] { store.space.tabs.filter { $0.pinned && $0.favorite != true } }
    var today: [BrowserCore.Tab] { store.space.tabs.filter { !$0.pinned && !$0.url.isEmpty } }
    @ViewBuilder var body: some View {
        if store.awaitingInitialMetadata { MetadataStartupView(store: store) }
        else { browserBody }
    }
    private var browserBody: some View {
        GeometryReader { geometry in
            let width = SidebarSizing.width(saved: resize.temporaryWidth ?? sidebarWidth, windowWidth: geometry.size.width)
            let managerShown = store.presentedPanel == .spaces
            let managerWidth = max(0,min(geometry.size.width - 16,min(900,max(520,geometry.size.width * 0.62))))
            let shown = store.sidebarVisible || reveal.revealed
            let floatingAllowed = !store.sidebarVisible && !sidebarInteractionBlocked
            ZStack(alignment: .leading) {
                // Keep web content and sidebar mounted; transitions change layout, not view ownership.
                content.padding(8).padding(.leading, managerShown ? managerWidth : (store.sidebarVisible ? width : 0))
                    .animation(resize.temporaryWidth == nil ? motion : nil, value: store.sidebarVisible)
                    .animation(motion,value:managerShown)
                HStack(spacing: 7) {
                    Color.clear.frame(width: max(0, chrome.leadingEdge - 17)).allowsHitTesting(false)
                    mini("sidebar.left", "Show Sidebar") { store.sidebarVisible = true }
                    Spacer(minLength: 0)
                }.padding(.horizontal, 10).frame(height: store.sidebarVisible ? 0 : chrome.height).clipped()
                    .background(NativeChromeReader(chrome: chrome))
                    .frame(maxHeight: .infinity, alignment: .top)
                    .opacity(store.sidebarVisible ? 0 : 1)
                    .allowsHitTesting(!store.sidebarVisible).accessibilityHidden(store.sidebarVisible)
                sidebar(width: width, windowHeight: geometry.size.height).frame(width: width)
                    .background(theme.gradient)
                    .background(SidebarTracking(controller: reveal, region: .panel, enabled: floatingAllowed && shown))
                    .clipShape(RoundedRectangle(cornerRadius: store.sidebarVisible ? 0 : appearance.cornerRadius + 4))
                    .shadow(color: .black.opacity(!store.sidebarVisible && shown ? 0.25 : 0), radius: 20, x: 8, y: 0)
                    .overlay(alignment: .trailing) {
                        SidebarResizeHandle(interactionEnabled: !sidebarInteractionBlocked && shown, width: width,
                                            canInteract: { !sidebarInteractionBlocked && (store.sidebarVisible || reveal.revealed) }, onBegin: {
                            reveal.beginResize()
                            resize.begin(at: SidebarSizing.width(saved: sidebarWidth, windowWidth: geometry.size.width))
                        }, onDrag: { resize.drag(by: $0, windowWidth: geometry.size.width) }, onEnd: {
                            if let value = resize.finish() { sidebarWidth = value }
                            reveal.endResize()
                        }, onCancel: {
                            resize.cancel(); reveal.endResize()
                        }, onReset: { resize.cancel(); sidebarWidth = 236; reveal.endResize() }, onSetWidth: { value in
                            resize.cancel(); sidebarWidth = value; reveal.endResize()
                        }, onFocusChange: { reveal.setKeyboardFocus($0) }).frame(width: 6)
                    }
                    .offset(x: shown ? 0 : -width - 16)
                    .opacity(shown ? 1 : 0)
                    .allowsHitTesting(shown).accessibilityHidden(!shown)
                    .animation(motion, value: shown)
                SidebarTracking(controller: reveal, region: .edge, enabled: floatingAllowed).frame(width: 8)
                if store.primaryPeekView != nil {
                    Color.black.opacity(0.35).ignoresSafeArea().onTapGesture { store.closePrimaryPeek() }
                    PeekPanel(store: store).frame(width: min(1000, geometry.size.width - 96), height: geometry.size.height - 96).frame(maxWidth: .infinity, maxHeight: .infinity).transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.98)))
                }
                if store.commandVisible {
                    Color.black.opacity(0.25).ignoresSafeArea().onTapGesture { store.commandVisible = false }
                    CommandPanel(store: store, availableHeight: geometry.size.height - min(140, geometry.size.height * 0.18) - 40).frame(width: min(600, geometry.size.width - 64)).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(.top, min(140, geometry.size.height * 0.18)).transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : -8)))
                }
                if let picker = store.boostPicker, case .primary = picker.source.inputContext {
                    BoostPickerBanner(store: store, session: picker).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(.top, chrome.height + 10).padding(.trailing, 18)
                }
                if managerShown {
                    SpacesPanel(store:store,topInset:chrome.height).frame(width:managerWidth).frame(maxHeight:.infinity)
                        .transition(reduceMotion ? .opacity : .move(edge:.leading).combined(with:.opacity))
                }
                if let message = store.message,!managerShown {
                    VStack { Spacer(); BrowserStatusBanner(store:store,message:message).shadow(radius:10).padding(24) }.frame(maxWidth:.infinity)
                }
                if store.onboardingVisible { OnboardingView(store: store).transition(.opacity).zIndex(10) }
            }
            .background(theme.gradient).foregroundStyle(theme.ink)
            .frame(maxWidth: .infinity, maxHeight: .infinity).ignoresSafeArea()
            .preferredColorScheme(theme.isDark ? .dark : .light)
            .animation(motion, value: store.commandVisible)
            .animation(motion, value: store.primaryPeekView != nil)
            .onAppear { reveal.setEnabled(floatingAllowed) }
            .onChange(of: floatingAllowed) { _, value in reveal.setEnabled(value) }
            .onChange(of: store.sidebarVisible) { _, _ in resize.cancel(); reveal.endResize() }
            .sheet(item: sheetPanel) { panel in
                switch panel {
                case .library: LibraryPanel(store: store, availableHeight: geometry.size.height - 40)
                case .settings: SettingsPanel(store: store, availableHeight: geometry.size.height - 40)
                case .siteSearch: SiteSearchPanel(store: store, availableHeight: geometry.size.height - 40)
                case .links: LinkRoutingPanel(store: store, availableHeight: geometry.size.height - 40)
                case .boosts: BoostPanel(store: store, availableHeight: geometry.size.height - 40)
                case .appearance:
                    if store.canModifyLocalMetadata { AppearancePanel(store: store, availableHeight: geometry.size.height - 40) }
                    else { lockedAppearancePanel }
                case .spaces: EmptyView()
                case .profiles: ProfilesPanel(store: store, availableHeight: geometry.size.height - 40)
                case .updates: UpdatesPanel(controller: updates, channel: Binding(get: { UpdateChannel(rawValue: store.preferences.updateChannel ?? "preview") ?? .preview }, set: { guard store.canModifyLocalMetadata else { return }; store.preferences.updateChannel = $0.rawValue; store.save() }), availableHeight: geometry.size.height - 40, canModifyChannel: store.canModifyLocalMetadata, onClose: { store.presentedPanel = nil })
                }
            }
        }
    }
    @ViewBuilder private var spaceProfileMenu: some View {
        if store.isPrivate { Text("Private · Temporary website storage") }
        else {
            Menu("Profile: \(store.activeProfile.name)") {
                ForEach(store.profiles) { profile in
                    Button { store.requestAssignProfile(profile.id, to: store.space.id) } label: {
                        if profile.id == store.activeProfileID { Label(profile.name, systemImage: "checkmark") }
                        else { Text(profile.name) }
                    }.disabled(!store.canManageProfiles || store.profileUnavailable(profile.id) || store.profileUnavailable(store.activeProfileID) || profile.id == store.activeProfileID)
                }
                Divider()
                Button("Manage Profiles…") { store.profilesVisible = true }
            }
        }
    }
    private var lockedAppearancePanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("Appearance").font(.title2.bold()); Spacer(); Button("Done") { store.appearanceVisible = false }.keyboardShortcut(.cancelAction) }
            Text("Unlock local data to save changes to your Space and appearance.").foregroundStyle(.secondary)
            Button(store.unlocking ? "Unlocking…" : "Unlock Local Data…") { store.unlockLocalData() }.disabled(store.unlocking)
        }.padding(24).frame(width: 560)
    }
    private var content: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: store.sidebarVisible ? 0 : max(0, chrome.height - 8)).accessibilityHidden(true)
            if !store.savingEnabled && !store.isPrivate {
                HStack { Text("Local saving is paused. Your existing data is preserved."); Spacer(); Button(store.unlocking ? "Unlocking…" : "Unlock") { store.unlockLocalData() }.disabled(store.unlocking) }.font(.system(size: 11)).padding(9).background(Color.orange.opacity(0.18))
            }
            if store.isPrivate { Text("PRIVATE WINDOW · History is not saved. Downloads stay on disk.").font(.system(size: 10)).foregroundStyle(.white).frame(maxWidth: .infinity).padding(6).background(.indigo) }
            if store.findVisible { FindBar(store: store) }
            if let web = store.currentView, web.isLoading { ProgressView(value: web.estimatedProgress).progressViewStyle(.linear).tint(.purple).frame(height: 2) }
            HSplitView { pane(store.selectedID); if let split = store.splitID { pane(split) } }
        }.background(theme.isDark ? Color(red: 0.095, green: 0.09, blue: 0.12) : .white)
            .clipShape(RoundedRectangle(cornerRadius: appearance.cornerRadius))
    }
    private func sidebar(width: Double, windowHeight: Double) -> some View {
        let columns = appearance.columns(for: width)
        let favoriteRows = Double((store.favorites.count + columns - 1) / columns)
        // Reserve chrome, both section headers and the footer before dividing the scrollable space.
        let pool = max(0, windowHeight - chrome.height - 197 - (store.favorites.isEmpty ? 0 : 8))
        let favoritesHeight = min(max(0, favoriteRows * 55 - 7), min(224, pool * 0.30))
        let savedRows = Double(pins.count) * (appearance.rowHeight + 3) + Double(store.space.folderNames.count) * 36 + 8
        let pinnedHeight = min(max(32, savedRows), min(260, (pool - favoritesHeight) * 0.5))
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Color.clear.frame(width: max(0, chrome.leadingEdge - 17)).allowsHitTesting(false)
                mini("sidebar.left", "Hide Sidebar") { store.sidebarVisible = false }
                mini("arrow.left", "Back") { store.currentView?.goBack() }.disabled(store.currentView?.canGoBack != true)
                mini("arrow.right", "Forward") { store.currentView?.goForward() }.disabled(store.currentView?.canGoForward != true)
                mini(store.currentView?.isLoading == true ? "xmark" : "arrow.clockwise", "Reload / Stop") { if store.currentView?.isLoading == true { store.currentView?.stopLoading() } else { store.currentView?.reload() } }
            }.padding(.horizontal, 10).frame(height: chrome.height)
                .background(NativeChromeReader(chrome: chrome))
            Button { store.showCommand() } label: {
                HStack {
                    if store.currentView?.url?.scheme == "https" && store.currentView?.hasOnlySecureContent == true { Image(systemName: "lock.fill").font(.system(size: 9)).opacity(0.5) }
                    Text(store.currentView?.url?.host ?? "Search or Enter URL…").font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 0)
                }.padding(.horizontal, 12).frame(height: 36).background(theme.tile, in: RoundedRectangle(cornerRadius: 10))
            }.buttonStyle(.plain).padding(.horizontal, 8).padding(.bottom, 8)
            if !store.favorites.isEmpty {
                ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: columns), spacing: 7) {
                    ForEach(store.favorites) { tab in
                        Button { store.selectAny(tab.id) } label: {
                            SiteBadge(url: tab.homeURL ?? tab.url, large: true, image: appearance.showFavicons ? store.siteIcons[tab.id] : nil).frame(maxWidth: .infinity).frame(height: 48).background(store.focusedID == tab.id ? theme.selected : theme.tile, in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain).help(tab.pinnedTitle ?? tab.title).onDrag { NSItemProvider(object: tab.id.uuidString as NSString) }.contextMenu { TabFolderDestinations(store: store, tabID: tab.id, spaceID: store.space.id); Button("Remove from Favorites") { store.toggleFavorite(tab.id) }.disabled(!store.canModifyLocalMetadata); Button("Remove from Sidebar") { store.removeFromSidebar(tab.id) }.disabled(!store.canModifyLocalMetadata) }
                    }
                }
                }.frame(height: favoritesHeight).accessibilityLabel("Favorites").padding(.horizontal, 8).padding(.bottom, 8).onDrop(of: [.text], delegate: TabDrop(store: store, section: .favorites))
            }
            HStack {
                Text(store.space.name.isEmpty ? "Space" : store.space.name).font(.system(size: 12, weight: .semibold)).opacity(0.5)
                Spacer()
                Menu {
                    Button("Manage Spaces…") { store.showSpacesManager() }
                    Button("Rename Space…") { store.requestRenameSpace(store.space.id) }.disabled(!store.canManageSpace(store.space.id))
                    Button("New Space…") { store.requestNewSpace() }.disabled(!store.canModifyLocalMetadata || store.profileDataOperationInProgress || (!store.isPrivate && store.profileUnavailable(store.activeProfileID)))
                    Button("Customize…") { store.appearanceVisible = true }.disabled(!store.canModifyLocalMetadata)
                    Button("Boost This Site…") { do { try store.requestBoostEditor(for: store.primaryPeekView ?? store.currentView) } catch { store.message = error.localizedDescription } }
                    Menu("Theme") { ForEach(SidebarTheme.allCases) { choice in Button(choice.name) { withAnimation(motion) { store.setTheme(choice) } } } }.disabled(!store.canModifyLocalMetadata)
                    Button("Split View") { store.toggleSplit() }
                    Button("Bookmark Page") { store.addBookmark() }.disabled(store.isPrivate || !store.savingEnabled || store.profileUnavailable(store.activeProfileID))
                    spaceProfileMenu
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 20).accessibilityLabel("Space settings")
            }.padding(.horizontal, 16).frame(height: 36)
            SidebarSavedTabs(store: store, theme: theme, appearance: appearance, motion: motion, height: pinnedHeight)
            Rectangle().fill(theme.ink.opacity(0.12)).frame(height: 1).padding(.horizontal, 18).padding(.vertical, 6)
            HStack {
                Text("Today").font(.system(size: 11, weight: .semibold)).opacity(0.5)
                Spacer(minLength: 4)
                if !today.isEmpty { Button("Clear") { for tab in today { store.close(tab.id) } }.font(.system(size: 10)).buttonStyle(.plain).opacity(0.4).help("Close Today tabs") }
                Button { store.showCommand(new: true) } label: { Label("New Tab", systemImage: "plus").font(.system(size: 12)).opacity(0.5) }.buttonStyle(.plain)
            }.padding(.horizontal, 18).frame(height: 32).onDrop(of: [.text], delegate: TabDrop(store: store, section: .today))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) { ForEach(today) { row($0) } }.padding(.horizontal, 8)
            }.accessibilityLabel("Today tabs").onDrop(of: [.text], delegate: TabDrop(store: store, section: .today))
            HStack(spacing: 10) {
                mini("archivebox", "Library") { store.libraryVisible = true }
                if updates.offer != nil { mini("arrow.down.circle.fill", "An Alcove update is available") { store.updatesVisible = true }.foregroundStyle(theme.accent) }
                Spacer(minLength: 0)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(Array(store.session.spaces.enumerated()), id: \.element.id) { index, space in
                                Button { store.selectSpace(space.id) } label: {
                                    Image(systemName: space.icon ?? SpaceSymbol.defaultName(at:index)).font(.system(size: 11)).opacity(store.session.selectedSpace == space.id ? 1 : 0.3).frame(width: 19, height: 26)
                                }.buttonStyle(.plain).help(store.isPrivate ? space.name : "\(space.name) · \(store.profiles.first(where: { $0.id == space.effectiveProfileID })?.name ?? "Profile")").id(space.id)
                                    .onDrag { NSItemProvider(object:("alcove-space:" + space.id.uuidString) as NSString) }
                                    .onDrop(of:[.text],delegate:SpaceDrop(store:store,target:space.id))
                                    .contextMenu { SpaceActionItems(store:store,spaceID:space.id) }
                            }
                        }.frame(minHeight: 26)
                    }.onChange(of: store.session.selectedSpace) { _, id in proxy.scrollTo(id, anchor: .center) }
                        .onChange(of:store.session.spaces.map(\.id)) { _,_ in proxy.scrollTo(store.session.selectedSpace,anchor:.center) }
                }
                Spacer(minLength: 0)
                Menu { Button("Manage Spaces…") { store.showSpacesManager() }; Button("Recently Deleted Spaces") { store.showSpacesManager(deleted:true) }; spaceProfileMenu; Button("New Space…") { store.requestNewSpace() }.disabled(!store.canModifyLocalMetadata || store.profileDataOperationInProgress || (!store.isPrivate && store.profileUnavailable(store.activeProfileID))); Button("Settings…") { store.settingsVisible = true }; Button("Customize…") { store.appearanceVisible = true }.disabled(!store.canModifyLocalMetadata); ForEach(store.session.spaces) { s in Button(s.name) { store.selectSpace(s.id) } } } label: { Image(systemName: "plus").font(.system(size: 15)) }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 20).accessibilityLabel("More Spaces and settings")
            }.padding(.horizontal, 14).frame(height: 42)
        }.padding(.bottom, 4)
    }
    private func mini(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 12, weight: .medium)).frame(width: 20, height: 24) }.buttonStyle(.plain).opacity(0.65).help(help)
    }
    private func row(_ tab: BrowserCore.Tab) -> some View { SidebarTabRow(tab: tab, store: store, theme: theme, appearance: appearance, motion: motion) }
    @ViewBuilder private func pane(_ id: UUID?) -> some View {
        if let id, let profile = store.profileID(for: id), store.profileUnavailable(profile) {
            VStack(spacing: 12) { if store.clearingProfileID == profile { ProgressView(); Text("Clearing this profile’s website data…") } else { Text("This profile is unavailable. Unlock local data or finish its pending operation.") } }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        else if let id, let tab = store.tab(id), !tab.url.isEmpty { WebPane(webView: store.view(for: id)).id(id).frame(minWidth: 160) }
        else {
            VStack(spacing: 10) {
                Spacer()
                Text("Search or enter a URL").font(.system(size: 16, weight: .medium)).opacity(0.32)
                Button("⌘ T") { store.showCommand() }.buttonStyle(.plain).font(.system(size: 12)).opacity(0.3)
                Spacer()
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct SiteBadge: View {
    let url: String
    var large = false
    var image: NSImage?
    var body: some View {
        let host = URL(string: url)?.host?.replacingOccurrences(of: "www.", with: "") ?? ""
        let letter = host.isEmpty ? "✦" : String(host.prefix(1)).uppercased()
        let hue = Double(host.utf8.reduce(0) { ($0 + Int($1)) % 360 }) / 360
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Text(letter).font(.system(size: large ? 15 : 10, weight: .bold, design: .rounded)).foregroundStyle(.primary).background(Color(hue: hue, saturation: 0.5, brightness: 0.8).opacity(0.16), in: RoundedRectangle(cornerRadius: large ? 7 : 5)) }
        }.frame(width: large ? 25 : 18, height: large ? 25 : 18)
    }
}

struct SidebarTabRow: View {
    let tab: BrowserCore.Tab
    @ObservedObject var store: BrowserStore
    let theme: AppearanceTheme
    let appearance: AppearanceSettings
    let motion: Animation?
    @State private var hovered = false
    var body: some View {
        HStack(spacing: 7) {
            Button { store.select(tab.id) } label: {
                HStack(spacing: 9) { SiteBadge(url: tab.homeURL ?? tab.url, image: appearance.showFavicons ? store.siteIcons[tab.id] : nil); Text(tab.pinned ? (tab.pinnedTitle ?? tab.title) : tab.title).font(.system(size: 12 * appearance.textScale, weight: store.focusedID == tab.id ? .semibold : .medium)).lineLimit(1); Spacer(minLength: 0) }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button { store.close(tab.id) } label: { Image(systemName: "xmark").font(.system(size: 9)).frame(width: 18, height: 22) }.buttonStyle(.plain).opacity(hovered || appearance.alwaysShowCloseButtons ? 0.65 : 0).help(tab.pinned ? "Close page and keep pin" : "Close tab").accessibilityLabel(tab.pinned ? "Close pinned page" : "Close tab")
        }.padding(.horizontal, 10).frame(height: appearance.rowHeight).background(store.focusedID == tab.id ? theme.selected : (hovered ? theme.tile : .clear), in: RoundedRectangle(cornerRadius: appearance.cornerRadius)).onHover { hovered = $0 }.animation(motion, value: hovered)
        .onDrag { NSItemProvider(object: tab.id.uuidString as NSString) }
        .onDrop(of: [.text], delegate: TabDrop(store: store, section: tab.pinned ? .pinned : .today, before: tab.id, folder: tab.folder))
        .contextMenu {
            Button(tab.pinned ? "Unpin Tab" : "Pin Tab") { store.togglePin(tab.id) }.disabled(!store.canModifyLocalMetadata)
            Button("Add to Favorites") { store.toggleFavorite(tab.id) }.disabled(!store.canModifyLocalMetadata)
            TabFolderDestinations(store: store, tabID: tab.id, spaceID: store.space.id)
            if tab.id != store.selectedID && !tab.url.isEmpty { Button("Open in Split View") { store.splitID = tab.id } }
            Menu("Move to Space") {
                ForEach(store.session.spaces.filter { $0.id != store.space.id }) { s in
                    Button(store.isPrivate ? s.name : "\(s.name) · \(store.profiles.first(where: { $0.id == s.effectiveProfileID })?.name ?? "Profile")") { store.requestMoveTab(tab.id, to: s.id) }
                        .disabled(!store.canModifyLocalMetadata || store.profileDataOperationInProgress || (!store.isPrivate && store.profileUnavailable(s.effectiveProfileID)))
                }
            }.disabled(!store.canModifyLocalMetadata || store.profileDataOperationInProgress)
            Divider()
            Button(tab.pinned ? "Remove from Sidebar" : "Close Tab") { if tab.pinned { store.removeFromSidebar(tab.id) } else { store.close(tab.id) } }.disabled(tab.pinned && !store.canModifyLocalMetadata)
        }
    }
}

@MainActor struct CommandResult: Identifiable {
    let id: String
    let title: String
    let icon: String
    let run: @MainActor () -> Void
}

@MainActor struct CommandPanel: View {
    @ObservedObject var store: BrowserStore
    var availableHeight: CGFloat = 480
    @State private var resultIndex = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    static func options(for store: BrowserStore) -> [CommandResult] {
        let query = store.command.trimmingCharacters(in: .whitespacesAndNewlines)
        if let site = store.commandSiteSearch {
            return [CommandResult(id: "search", title: query.isEmpty ? "Enter a query to search \(site.name)" : "Search \(site.name) for “\(query)”", icon: "magnifyingglass", run: { store.submitCommandInput() })]
        }
        var results: [CommandResult] = []
        if query.count > 1 {
            for command in store.availableCommands where command.matches(query) {
                results.append(CommandResult(id: command.rawValue, title: command.title, icon: "command", run: { store.runCommand(command) }))
            }
            if store.commandOpensNewTab || !query.contains("://") {
                for tab in store.profileTabs.filter({ !$0.url.isEmpty && ($0.title.localizedCaseInsensitiveContains(query) || $0.url.localizedCaseInsensitiveContains(query)) }).prefix(5) {
                    let quick = store.quickPage(tab.id) != nil
                    results.append(CommandResult(id: tab.id.uuidString, title: "\(quick ? "Quick Browse" : "Switch to") \(tab.pinnedTitle ?? tab.title)", icon: quick ? "arrow.up.forward.square" : "rectangle.on.rectangle", run: { store.selectAny(tab.id); store.dismissCommand() }))
                }
            }
        }
        results.append(CommandResult(id: "search", title: query.isEmpty ? "Search the web or enter a URL" : query, icon: "magnifyingglass", run: { store.submitCommandInput() }))
        for site in store.siteSearchCatalog.matches(query).prefix(5) {
            results.append(CommandResult(id: "site-search-" + site.id.uuidString, title: "Search \(site.name) · \(site.keyword)", icon: "globe", run: { _ = store.activateCommandSiteSearch(site) }))
        }
        return results
    }
    private var results: [CommandResult] { Self.options(for: store) }
    private var scale: Double { store.appearance.textScale }
    private var rowHeight: CGFloat { max(38, 42 * scale) }
    private var scrollHeight: CGFloat { min(CGFloat(results.count) * rowHeight, max(80, min(320, availableHeight - max(130, 140 * scale)))) }
    private var motion: Animation? { reduceMotion || !store.appearance.animationsEnabled ? nil : .easeInOut(duration: 0.14) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                if let site = store.commandSiteSearch {
                    SiteSearchPill(site: site, scale: scale, fill: store.activeTheme.selected) { store.leaveCommandSiteSearch(restoreKeyword: false) }
                } else { Image(systemName: "magnifyingglass").opacity(0.4) }
                FocusedInput(text: $store.command, placeholder: store.commandSiteSearch.map { "Search \($0.name)" } ?? "Search or Enter URL…", size: 20 * scale, selectAll: true, focusRequest: store.commandFocusRequest,
                             onSubmit: submit, onCancel: { store.dismissCommand() },
                             onMove: { delta in resultIndex = min(results.count - 1, max(0, resultIndex + delta)) },
                             onTab: { store.activatePreferredCommandSiteSearch() }, onEmptyDelete: { store.deleteEmptyCommandSiteSearch() })
                    .frame(minWidth: 80, maxWidth: .infinity).frame(height: max(30, 32 * scale))
                if store.commandSiteSearch == nil, let site = store.siteSearchCatalog.preferredMatch(store.command) {
                    Text("⇥").font(.system(size: 12 * scale)).opacity(0.5).help("Press Tab to search \(site.name)").accessibilityLabel("Press Tab to search \(site.name)")
                }
            }.padding(20)
            Divider().opacity(0.4)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                            Button(action: result.run) { HStack(spacing: 12) {
                                Image(systemName: result.icon).opacity(0.6).frame(width: 16)
                                Text(result.title).lineLimit(1); Spacer()
                                if index == resultIndex { Text("↵").opacity(0.4) }
                            }.font(.system(size: 13 * scale)).padding(.horizontal, 18).frame(height: rowHeight).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()).background(resultIndex == index ? store.activeTheme.selected : .clear) }
                                .buttonStyle(.plain).id(result.id)
                        }
                    }
                }.frame(height: scrollHeight)
                .onChange(of: resultIndex) { _, index in
                    guard results.indices.contains(index) else { return }
                    withAnimation(motion) { proxy.scrollTo(results[index].id, anchor: .center) }
                }
            }
            if let error = store.commandError {
                Text(error).font(.system(size: 11 * scale)).foregroundStyle(.red).lineLimit(2).padding(.horizontal, 18).padding(.vertical, 10)
            }
        }.foregroundStyle(store.activeTheme.ink)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: store.appearance.cornerRadius + 4))
            .overlay(RoundedRectangle(cornerRadius: store.appearance.cornerRadius + 4).stroke(.white.opacity(0.08)))
            .shadow(color: .black.opacity(0.3), radius: 35, y: 15)
            .preferredColorScheme(store.activeTheme.isDark ? .dark : .light)
            .onChange(of: store.command) { _, _ in
                resultIndex = 0
                if store.commandError != nil { store.commandError = nil }
            }
            .onChange(of: store.commandSiteSearch?.id) { _, _ in resultIndex = 0 }
            .animation(motion, value: store.commandSiteSearch?.id)
    }
    private func submit() { let options = results; options[min(resultIndex, options.count - 1)].run() }
}
