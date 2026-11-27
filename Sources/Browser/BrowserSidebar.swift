import AppKit
import SwiftUI
import WebKit
import UniformTypeIdentifiers
import BrowserCore

/// The complete sidebar keeps its native tracking and chrome models owned by
/// BrowserUI, while its layout has a separate SwiftUI dependency boundary.
struct BrowserSidebar: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var chrome: NativeWindowChrome
    @ObservedObject var reveal: SidebarRevealController
    @EnvironmentObject private var updates: UpdateController
    let width: Double
    let windowHeight: Double
    let motion: Animation?
    let interactionBlocked: Bool
    let resizing: Bool
    private var theme: AppearanceTheme { store.activeTheme }
    private var appearance: AppearanceSettings { store.appearance }
    private var nearbySpaces: SidebarSpaceSwipeRegion.Spaces {
        let spaces = store.session.spaces
        let index = store.spaceIndex
        return .init(current: store.space.id,
                     previous: index > spaces.startIndex ? spaces[index - 1].id : nil,
                     next: index + 1 < spaces.endIndex ? spaces[index + 1].id : nil)
    }

    private var canSwipeSpaces: Bool {
        (store.sidebarVisible || reveal.revealed) && !interactionBlocked &&
            store.boostPicker == nil && !store.profileDataOperationInProgress && !resizing
    }

    var body: some View {
        let swipeSpaces = nearbySpaces
        let lists = store.sidebarLists
        let space = lists.space
        let today = lists.today
        let favorites = store.favorites
        let columns = appearance.columns(for: width)
        let favoriteRows = Double((favorites.count + columns - 1) / columns)
        // Reserve chrome, both section headers and the footer before dividing the scrollable space.
        let pool = max(0, windowHeight - chrome.height - 197 - (favorites.isEmpty ? 0 : 8))
        let rowHeight = appearance.rowHeight + 3
        let pinnedCollapsed = space.pinnedShelfCollapsed == true
        let pinnedDemand = pinnedCollapsed ? 0 : max(32, lists.saved.height(rowHeight: appearance.rowHeight))
        let todayDemand = max(32, Double(today.count) * rowHeight)
        let favoriteDemand = min(224, max(0, favoriteRows * 55 - 7))
        let favoriteBudget = max(pool * 0.30, pool - pinnedDemand - todayDemand)
        let favoritesHeight = min(favoriteDemand, favoriteBudget)
        let remaining = pool - favoritesHeight
        // Keep the shelves separately scrollable and let them use space Today doesn't need.
        let pinnedBudget = max(min(260, remaining * 0.5), remaining - todayDemand)
        let pinnedHeight = min(pinnedDemand, pinnedBudget)
        let chromeLeading = max(10, Double(chrome.leadingEdge))
        let chromeTrailing = 10.0
        let availableChrome = max(0, width - chromeLeading - chromeTrailing)
        let navigationButtonsWidth = 4 * 20.0
        let extensionsWidth = 22.0
        let standardSpacing = 7.0
        let extensionsInTitlebar = availableChrome >= navigationButtonsWidth + extensionsWidth + 4 * standardSpacing
        let chromeSpacing = extensionsInTitlebar ? standardSpacing : max(0, min(standardSpacing, (availableChrome - navigationButtonsWidth) / 3))
        let extensions = ExtensionControls(store: store, web: store.primaryPeekView ?? store.currentView)
            .frame(width: extensionsWidth, height: 26)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: chromeSpacing) {
                mini("sidebar.left", "Hide Sidebar") { store.sidebarVisible = false }
                mini("arrow.left", "Back") { store.currentView?.goBack() }.disabled(store.currentView?.canGoBack != true)
                mini("arrow.right", "Forward") { store.currentView?.goForward() }.disabled(store.currentView?.canGoForward != true)
                mini(store.currentView?.isLoading == true ? "xmark" : "arrow.clockwise", "Reload / Stop") { if store.currentView?.isLoading == true { store.currentView?.stopLoading() } else { store.currentView?.reload() } }
                if extensionsInTitlebar { extensions }
            }.padding(.leading, chromeLeading).padding(.trailing, chromeTrailing)
                .frame(maxWidth: .infinity, alignment: .leading).frame(height: chrome.height)
                .background(NativeChromeReader(chrome: chrome))
            HStack(spacing: 8) {
                Button { store.showCommand() } label: {
                    HStack {
                        if store.currentView?.url?.scheme == "https" && store.currentView?.hasOnlySecureContent == true { Image(systemName: "lock.fill").font(.system(size: 9)).opacity(0.5) }
                        Text(EaselRoute.isNative(store.sidebarAddressURL?.absoluteString ?? "") ? "Easel" : (store.sidebarAddressURL?.host ?? "Search or enter URL")).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 0)
                    }.padding(.horizontal, 12).frame(height: 36)
                        .background(theme.tile, in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain)
                ReaderControl(store: store, web: store.primaryPeekView ?? store.currentView)
                if !extensionsInTitlebar { extensions }
            }.padding(.horizontal, 8).padding(.bottom, 8)
            VStack(alignment: .leading, spacing: 0) {
                if !favorites.isEmpty {
                    SidebarTabScrollView(positions: sidebarTabPositions(favorites), focusedTab: store.focusedID,
                                         theme: theme, motion: motion, showsIndicators: false) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: columns), spacing: 7) {
                        ForEach(favorites) { tab in
                            let actions = tab.pinned ? store.pinnedAddressActions(for: tab.id) : .unavailable
                            Button { store.selectAny(tab.id) } label: {
                                SiteBadge(url: tab.homeURL ?? tab.url, large: true, image: appearance.showFavicons ? store.siteIcons[tab.id] : nil).frame(maxWidth: .infinity).frame(height: 48).background(store.focusedID == tab.id ? theme.selected : theme.tile, in: RoundedRectangle(cornerRadius: 10))
                            }.buttonStyle(.plain).help(tab.sidebarTitle).accessibilityLabel(tab.sidebarTitle)
                                .onDrag { store.beginSidebarTabDrag(tab.id) }.contextMenu {
                                    PinnedAddressMenu(store: store, tabID: tab.id, actions: actions)
                                    Button("Rename Tab…") { store.requestRenameSidebarTab(tab.id) }.disabled(!store.canModifyLocalMetadata)
                                    if tab.customTitle != nil {
                                        Button("Restore Tab Name") { store.restoreSidebarTabName(tab.id) }.disabled(!store.canModifyLocalMetadata)
                                    }
                                    Button("Duplicate Tab") { store.duplicateSidebarTab(tab.id) }.disabled(!store.canDuplicateSidebarTab(tab.id))
                                    TabFolderDestinations(store: store, tabID: tab.id, spaceID: store.space.id)
                                    Button("Remove from Favorites") { store.toggleFavorite(tab.id) }.disabled(!store.canModifyLocalMetadata)
                                    Button("Remove from Sidebar") { store.removeFromSidebar(tab.id) }.disabled(!store.canModifyLocalMetadata)
                                }
                                .overlay(alignment: .topTrailing) {
                                    if tab.homeURL != tab.url && actions.canReturn {
                                        PinnedAddressButton(store: store, tabID: tab.id, accent: theme.accent)
                                            .padding(4)
                                    }
                                }
                                .sidebarTabScrollTarget(tab.id)
                        }
                    }
                    }.frame(height: favoritesHeight).accessibilityLabel("Favorites").padding(.horizontal, 8).padding(.bottom, 8).onDrop(of: SidebarTabDrag.dropTypes, delegate: TabDrop(store: store, section: .favorites))
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
                        Button("Extensions…") {store.requestExtensionManager()}
                        Menu("Theme") { ForEach(SidebarTheme.allCases) { choice in Button(choice.name) { withAnimation(motion) { store.setTheme(choice) } } } }.disabled(!store.canModifyLocalMetadata)
                        Button("Split View") { store.toggleSplit() }
                        Button("Bookmark Page") { store.addBookmark() }.disabled(store.isPrivate || !store.savingEnabled || store.profileUnavailable(store.activeProfileID))
                        spaceProfileMenu
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 20).accessibilityLabel("Space settings")
                }.padding(.horizontal, 16).frame(height: 36)
                SidebarSavedTabs(store: store, theme: theme, appearance: appearance, motion: motion,
                                 height: pinnedHeight, layout: lists.saved, collapsed: pinnedCollapsed)
                Rectangle().fill(theme.ink.opacity(0.12)).frame(height: 1).padding(.horizontal, 18).padding(.vertical, 6)
                HStack {
                    Text("Today").font(.system(size: 11, weight: .semibold)).opacity(0.5)
                    Spacer(minLength: 4)
                    if !today.isEmpty {
                        Button("Clear") { store.clearTodayTabs() }
                            .font(.system(size: 10)).buttonStyle(.plain).opacity(0.4)
                            .disabled(store.clearingToday).help("Close inactive Today tabs")
                    }
                    Button { store.showCommand(new: true) } label: { Label("New Tab", systemImage: "plus").font(.system(size: 12)).opacity(0.5) }.buttonStyle(.plain)
                }.padding(.horizontal, 18).frame(height: 32).onDrop(of: SidebarTabDrag.dropTypes, delegate: TabDrop(store: store, section: .today))
                SidebarTabScrollView(positions: lists.todayPositions, focusedTab: store.focusedID, theme: theme, motion: motion) {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(today) { tab in
                            SidebarTabRow(tab: tab, spaceID: space.id, store: store, theme: theme, appearance: appearance, motion: motion)
                                .sidebarTabScrollTarget(tab.id)
                        }
                    }.padding(.horizontal, 8)
                }.accessibilityLabel("Today tabs").onDrop(of: SidebarTabDrag.dropTypes, delegate: TabDrop(store: store, section: .today))
            }.animation(motion, value: pinnedCollapsed).modifier(SidebarSpaceSwipeRegion(
                spaces: swipeSpaces,
                reveal: reveal,
                enabled: canSwipeSpaces,
                motion: motion,
                select: { destination in
                    guard nearbySpaces == swipeSpaces, canSwipeSpaces else { return }
                    store.selectSpace(destination)
                }
            ))
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    mini("archivebox", "Library") { store.libraryVisible = true }
                    SidebarPlaybackButton(store: store)
                    if store.hasDownloadsForActiveProfile {
                        mini("square.and.arrow.down", "Show Downloads") { store.showDownloads() }
                            .accessibilityLabel("Show Downloads")
                    }
                    if updates.offer != nil { mini("arrow.down.circle.fill", "An Alcove update is available") { store.updatesVisible = true }.foregroundStyle(theme.accent) }
                }
                Spacer(minLength: 0)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(Array(store.session.spaces.enumerated()), id: \.element.id) { index, space in
                                Button { store.selectSpace(space.id) } label: {
                                    Image(systemName: space.icon ?? SpaceSymbol.defaultName(at:index)).font(.system(size: 11)).opacity(store.session.selectedSpace == space.id ? 1 : 0.3).frame(width: 19, height: 26)
                                }.buttonStyle(.plain).help(store.isPrivate ? space.name : "\(space.name) · \(store.profiles.first(where: { $0.id == space.effectiveProfileID })?.name ?? "Profile")").id(space.id)
                                    .onDrag { NSItemProvider(object:("alcove-space:" + space.id.uuidString) as NSString) }
                                    .onDrop(of: SidebarTabDrag.dropTypes, delegate: SpaceDrop(store:store,target:space.id))
                                    .contextMenu { SpaceActionItems(store:store,spaceID:space.id) }
                            }
                        }.frame(minHeight: 26)
                    }.onChange(of: store.session.selectedSpace) { _, id in
                        withAnimation(motion) { proxy.scrollTo(id, anchor: .center) }
                    }
                        .onChange(of:store.session.spaces.map(\.id)) { _,_ in proxy.scrollTo(store.session.selectedSpace,anchor:.center) }
                }
                Spacer(minLength: 0)
                Menu { Button("New Easel") { store.requestNewEasel() }.disabled(!store.canManageSpace(store.space.id)); Button("Capture Page to Easel…") { store.requestPageCapture() }.disabled(!store.canRequestPageCapture); Divider(); Button("Manage Spaces…") { store.showSpacesManager() }; Button("Recently Deleted Spaces") { store.showSpacesManager(deleted:true) }; spaceProfileMenu; Button("New Space…") { store.requestNewSpace() }.disabled(!store.canModifyLocalMetadata || store.profileDataOperationInProgress || (!store.isPrivate && store.profileUnavailable(store.activeProfileID))); Button("Settings…") { store.settingsVisible = true }; Button("Customize…") { store.appearanceVisible = true }.disabled(!store.canModifyLocalMetadata); ForEach(store.session.spaces) { s in Button(s.name) { store.selectSpace(s.id) } } } label: { Image(systemName: "plus").font(.system(size: 15)) }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 20).accessibilityLabel("Create an Easel, manage Spaces and settings")
            }.padding(.horizontal, 14).frame(height: 42)
        }.padding(.bottom, 4)
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
    private func mini(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 12, weight: .medium)).frame(width: 20, height: 24) }.buttonStyle(.plain).opacity(0.65).help(help)
    }
}
