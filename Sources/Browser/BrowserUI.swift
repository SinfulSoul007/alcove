import SwiftUI
import WebKit
import BrowserCore

final class EdgeToEdgeWebHost: NSView {
    private var contentConstraints: [NSLayoutConstraint] = []
    func setContent(_ view: NSView) {
        guard subviews.first !== view else { return }
        NSLayoutConstraint.deactivate(contentConstraints)
        for old in subviews { old.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view)
        contentConstraints = [view.topAnchor.constraint(equalTo: topAnchor), view.bottomAnchor.constraint(equalTo: bottomAnchor), view.leadingAnchor.constraint(equalTo: leadingAnchor), view.trailingAnchor.constraint(equalTo: trailingAnchor)]
        NSLayoutConstraint.activate(contentConstraints)
        func removeTitlebarInset(_ view: NSView) {
            if let scroll = view as? NSScrollView { scroll.automaticallyAdjustsContentInsets = false; scroll.contentInsets = .init(top: 0, left: 0, bottom: 0, right: 0) }
            for child in view.subviews { removeTitlebarInset(child) }
        }
        removeTitlebarInset(view)
    }
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
    @State private var resize = SidebarResizeState()
    @State private var sidebarHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var theme: AppearanceTheme { store.activeTheme }
    var appearance: AppearanceSettings { store.appearance }
    var motion: Animation? { reduceMotion || !appearance.animationsEnabled ? nil : .spring(response: 0.28, dampingFraction: 0.88) }
    var pins: [BrowserCore.Tab] { store.space.tabs.filter { $0.pinned && $0.favorite != true } }
    var today: [BrowserCore.Tab] { store.space.tabs.filter { !$0.pinned && !$0.url.isEmpty } }
    var body: some View {
        GeometryReader { geometry in
            let width = SidebarSizing.width(saved: resize.temporaryWidth ?? sidebarWidth, windowWidth: geometry.size.width)
            let shown = store.sidebarVisible || reveal.revealed
            ZStack(alignment: .leading) {
                // Keep web content and sidebar mounted; transitions change layout, not view ownership.
                content.padding(8).padding(.leading, store.sidebarVisible ? width : 0)
                    .animation(resize.temporaryWidth == nil ? motion : nil, value: store.sidebarVisible)
                sidebar(width: width, windowHeight: geometry.size.height).frame(width: width)
                    .background(theme.gradient)
                    .clipShape(RoundedRectangle(cornerRadius: store.sidebarVisible ? 0 : appearance.cornerRadius + 4))
                    .shadow(color: .black.opacity(!store.sidebarVisible && shown ? 0.25 : 0), radius: 20, x: 8, y: 0)
                    .overlay(alignment: .trailing) {
                        SidebarResizeHandle(onBegin: { reveal.panelEntered(); resize.begin(at: width) }, onDrag: { resize.drag(by: $0, windowWidth: geometry.size.width) }, onEnd: {
                            if let value = resize.finish() { sidebarWidth = value }
                            if !store.sidebarVisible { if sidebarHovered { reveal.panelEntered() } else { reveal.panelExited() } }
                        }, onReset: { resize.cancel(); sidebarWidth = 236 }).frame(width: 6)
                    }
                    .offset(x: shown ? 0 : -width - 16)
                    .opacity(shown ? 1 : 0)
                    .allowsHitTesting(shown).accessibilityHidden(!shown)
                    .onHover { inside in
                        sidebarHovered = inside
                        guard !store.sidebarVisible, resize.temporaryWidth == nil else { return }
                        if inside { reveal.panelEntered() } else { reveal.panelExited() }
                    }
                    .animation(motion, value: shown)
                Color.clear.frame(width: 8).contentShape(Rectangle()).allowsHitTesting(!store.sidebarVisible && !shown)
                    .onHover { inside in guard !store.sidebarVisible else { return }; if inside { reveal.edgeEntered() } else if !reveal.revealed { reveal.reset() } }
                if store.peekView != nil {
                    Color.black.opacity(0.35).ignoresSafeArea().onTapGesture { store.closePeek() }
                    PeekPanel(store: store).frame(width: min(1000, geometry.size.width - 96), height: geometry.size.height - 96).frame(maxWidth: .infinity, maxHeight: .infinity).transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.98)))
                }
                if store.commandVisible {
                    Color.black.opacity(0.25).ignoresSafeArea().onTapGesture { store.commandVisible = false }
                    CommandPanel(store: store).frame(width: min(600, geometry.size.width - 64)).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(.top, min(140, geometry.size.height * 0.18)).transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : -8)))
                }
                if let message = store.message {
                    VStack { Spacer(); HStack {
                        if !store.savingEnabled && !store.isPrivate { Button("Unlock") { store.unlockLocalData() } }
                        Text(message).font(.system(size: 12)).textSelection(.enabled)
                        Button { store.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                    }.padding(14).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).shadow(radius: 10).padding(24) }.frame(maxWidth: .infinity)
                }
                if store.onboardingVisible { OnboardingView(store: store).transition(.opacity).zIndex(10) }
            }
            .background(theme.gradient).foregroundStyle(theme.ink)
            .frame(minWidth: 800, minHeight: 540).ignoresSafeArea()
            .preferredColorScheme(theme.isDark ? .dark : .light)
            .animation(motion, value: store.commandVisible)
            .animation(motion, value: store.peekView != nil)
            .onChange(of: store.sidebarVisible) { _, _ in reveal.reset() }
            .sheet(item: $store.presentedPanel) { panel in
                switch panel {
                case .library: LibraryPanel(store: store)
                case .settings: SettingsPanel(store: store, availableHeight: geometry.size.height - 40)
                case .appearance: AppearancePanel(store: store, availableHeight: geometry.size.height - 40)
                case .updates: UpdatesPanel(controller: updates, channel: Binding(get: { UpdateChannel(rawValue: store.preferences.updateChannel ?? "preview") ?? .preview }, set: { store.preferences.updateChannel = $0.rawValue; store.save() }), availableHeight: geometry.size.height - 40, onClose: { store.presentedPanel = nil })
                }
            }
        }
    }
    private var content: some View {
        VStack(spacing: 0) {
            HStack { Spacer().frame(width: 66); mini("sidebar.left", "Show Sidebar") { store.sidebarVisible = true }; Spacer() }.padding(.horizontal, 8).frame(height: store.sidebarVisible ? 0 : 36).opacity(store.sidebarVisible ? 0 : 1).clipped().accessibilityHidden(store.sidebarVisible)
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
        let favoritesHeight: Double = min(max(0, favoriteRows * 55.0 - 7.0), min(224.0, max(96.0, windowHeight * 0.28)))
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Spacer().frame(width: 64)
                mini("sidebar.left", "Hide Sidebar") { store.sidebarVisible = false }
                mini("arrow.left", "Back") { store.currentView?.goBack() }.disabled(store.currentView?.canGoBack != true)
                mini("arrow.right", "Forward") { store.currentView?.goForward() }.disabled(store.currentView?.canGoForward != true)
                mini(store.currentView?.isLoading == true ? "xmark" : "arrow.clockwise", "Reload / Stop") { if store.currentView?.isLoading == true { store.currentView?.stopLoading() } else { store.currentView?.reload() } }
            }.padding(.horizontal, 10).frame(height: 40)
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
                        }.buttonStyle(.plain).help(tab.pinnedTitle ?? tab.title).onDrag { NSItemProvider(object: tab.id.uuidString as NSString) }.contextMenu { Button("Remove from Favorites") { store.toggleFavorite(tab.id) }; Button("Remove from Sidebar") { store.removeFromSidebar(tab.id) } }
                    }
                }
                }.frame(height: favoritesHeight).padding(.horizontal, 8).padding(.bottom, 12).onDrop(of: [.text], delegate: TabDrop(store: store, section: .favorites))
            }
            HStack {
                Text(store.space.name.isEmpty ? "Space" : store.space.name).font(.system(size: 12, weight: .semibold)).opacity(0.5)
                Spacer()
                Menu {
                    Button("New Space…") { store.addSpace() }
                    Button("Customize…") { store.appearanceVisible = true }
                    Menu("Theme") { ForEach(SidebarTheme.allCases) { choice in Button(choice.name) { withAnimation(motion) { store.setTheme(choice) } } } }
                    Button("Split View") { store.toggleSplit() }
                    Button("Bookmark Page") { store.addBookmark() }.disabled(store.isPrivate)
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 20).accessibilityLabel("Space settings")
            }.padding(.horizontal, 16).padding(.vertical, 12)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(pins.filter { $0.folder == nil }) { row($0) }
                    ForEach(Array(Set(pins.compactMap(\.folder))).sorted(), id: \.self) { folder in
                        DisclosureGroup(isExpanded: Binding(get: { !(store.space.collapsedFolders ?? []).contains(folder) }, set: { expanded in
                            var collapsed = store.space.collapsedFolders ?? []; collapsed.removeAll { $0 == folder }; if !expanded { collapsed.append(folder) }; store.session.spaces[store.spaceIndex].collapsedFolders = collapsed; store.save()
                        })) { ForEach(pins.filter { $0.folder == folder }) { row($0) } } label: {
                            Label(folder, systemImage: "folder.fill").font(.system(size: 12 * appearance.textScale, weight: .medium)).lineLimit(1).padding(.vertical, 7).foregroundStyle(theme.accent)
                        }.tint(theme.ink.opacity(0.4)).padding(.horizontal, 9).onDrop(of: [.text], delegate: TabDrop(store: store, section: .pinned, folder: folder))
                    }
                    Color.clear.frame(height: pins.isEmpty ? 10 : 3).contentShape(Rectangle()).onDrop(of: [.text], delegate: TabDrop(store: store, section: .pinned))
                    Rectangle().fill(theme.ink.opacity(0.12)).frame(height: 0.5).padding(.horizontal, 10).padding(.vertical, 12)
                    HStack {
                        Button { store.showCommand(new: true) } label: { Label("New Tab", systemImage: "plus").font(.system(size: 13)).opacity(0.5) }.buttonStyle(.plain)
                        Spacer()
                        if today.contains(where: { !$0.url.isEmpty }) { Button("Clear") { for tab in today where !tab.url.isEmpty { store.close(tab.id) } }.font(.system(size: 10)).buttonStyle(.plain).opacity(0.4).help("Close Today tabs") }
                    }.padding(.horizontal, 12).frame(height: 32).onDrop(of: [.text], delegate: TabDrop(store: store, section: .today))
                    ForEach(today) { row($0) }
                }.padding(.horizontal, 8)
            }
            HStack(spacing: 10) {
                mini("archivebox", "Library") { store.libraryVisible = true }
                if updates.offer != nil { mini("arrow.down.circle.fill", "An Alcove update is available") { store.updatesVisible = true }.foregroundStyle(theme.accent) }
                Spacer(minLength: 0)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(Array(store.session.spaces.enumerated()), id: \.element.id) { index, space in
                                Button { store.selectSpace(space.id) } label: {
                                    Image(systemName: space.icon ?? ["circle.fill", "moon.fill", "leaf.fill", "sun.max.fill", "star.fill", "square.fill"][index % 6]).font(.system(size: 11)).opacity(store.session.selectedSpace == space.id ? 1 : 0.3).frame(width: 19, height: 26)
                                }.buttonStyle(.plain).help(space.name).id(space.id)
                            }
                        }.frame(minHeight: 26)
                    }.onChange(of: store.session.selectedSpace) { _, id in proxy.scrollTo(id, anchor: .center) }
                }
                Spacer(minLength: 0)
                Menu { Button("New Space…") { store.addSpace() }; Button("Settings…") { store.settingsVisible = true }; Button("Customize…") { store.appearanceVisible = true }; ForEach(store.session.spaces) { s in Button(s.name) { store.selectSpace(s.id) } } } label: { Image(systemName: "plus").font(.system(size: 15)) }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 20).accessibilityLabel("More Spaces and settings")
            }.padding(.horizontal, 14).frame(height: 42)
        }.padding(.bottom, 4)
    }
    private func mini(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 12, weight: .medium)).frame(width: 20, height: 24) }.buttonStyle(.plain).opacity(0.65).help(help)
    }
    private func row(_ tab: BrowserCore.Tab) -> some View { SidebarTabRow(tab: tab, store: store, theme: theme, appearance: appearance, motion: motion) }
    @ViewBuilder private func pane(_ id: UUID?) -> some View {
        if let id, let tab = store.tab(id), !tab.url.isEmpty { WebPane(webView: store.view(for: id)).id(id).frame(minWidth: 160) }
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
            Button(tab.pinned ? "Unpin Tab" : "Pin Tab") { store.togglePin(tab.id) }
            Button("Add to Favorites") { store.toggleFavorite(tab.id) }
            Button("Move to Folder…") { store.setFolder(tab.id) }
            if tab.id != store.selectedID && !tab.url.isEmpty { Button("Open in Split View") { store.splitID = tab.id } }
            Menu("Move to Space") { ForEach(store.session.spaces.filter { $0.id != store.space.id }) { s in Button(s.name) { store.move(tab.id, to: s.id) } } }
            Divider()
            Button(tab.pinned ? "Remove from Sidebar" : "Close Tab") { if tab.pinned { store.removeFromSidebar(tab.id) } else { store.close(tab.id) } }
        }
    }
}

private struct CommandResult: Identifiable {
    let id: String
    let title: String
    let icon: String
    let run: () -> Void
}

struct CommandPanel: View {
    @ObservedObject var store: BrowserStore
    @State private var resultIndex = 0
    private var results: [CommandResult] {
        let query = store.command.trimmingCharacters(in: .whitespacesAndNewlines)
        var results: [CommandResult] = []
        if query.count > 1 {
            for command in store.availableCommands where command.matches(query) {
                results.append(CommandResult(id: command.rawValue, title: command.title, icon: "command", run: { store.runCommand(command) }))
            }
            if store.commandOpensNewTab || !query.contains("://") {
                for tab in store.profileTabs.filter({ !$0.url.isEmpty && ($0.title.localizedCaseInsensitiveContains(query) || $0.url.localizedCaseInsensitiveContains(query)) }).prefix(5) {
                    results.append(CommandResult(id: tab.id.uuidString, title: "Switch to \(tab.pinnedTitle ?? tab.title)", icon: "rectangle.on.rectangle", run: { store.selectAny(tab.id); store.commandVisible = false; store.commandOpensNewTab = false }))
                }
            }
        }
        results.append(CommandResult(id: "search", title: query.isEmpty ? "Search the web or enter a URL" : query, icon: "magnifyingglass", run: { store.navigate(store.command) }))
        return results
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").opacity(0.4)
                FocusedInput(text: $store.command, placeholder: "Search or Enter URL…", selectAll: true, onSubmit: submit, onCancel: { store.commandVisible = false }, onMove: { delta in resultIndex = min(results.count - 1, max(0, resultIndex + delta)) }).frame(height: 28)
            }.padding(22)
            Divider().opacity(0.4)
            ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                Button(action: result.run) { HStack(spacing: 12) {
                    Image(systemName: result.icon).opacity(0.6).frame(width: 16)
                    Text(result.title).lineLimit(1); Spacer()
                    if index == resultIndex { Text("↵").opacity(0.4) }
                }.font(.system(size: 13)).padding(.horizontal, 18).padding(.vertical, 13).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()).background(resultIndex == index ? Color.primary.opacity(0.07) : .clear) }.buttonStyle(.plain)
            }
        }.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.08))).shadow(color: .black.opacity(0.3), radius: 35, y: 15)
        .onChange(of: store.command) { _, _ in resultIndex = 0 }
    }
    private func submit() { let options = results; options[min(resultIndex, options.count - 1)].run() }
}
