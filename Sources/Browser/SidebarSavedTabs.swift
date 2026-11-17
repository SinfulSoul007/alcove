import SwiftUI
import BrowserCore

enum SidebarFolderLinkFormat {
    case plainText, markdown
}

/// The tab lists depend on the active Space. The sidebar can reuse them at any size.
final class SidebarSpaceLists {
    let space: Space
    let today: [BrowserCore.Tab]
    let saved: SidebarSavedLayout

    init(space: Space) {
        self.space = space
        today = space.tabs.filter { !$0.pinned && !$0.url.isEmpty }
        saved = SidebarSavedLayout(space: space)
    }
}

struct SidebarSavedLayout {
    let spaceID: UUID
    let tree: SidebarFolderTree
    let topLevelTabs: [BrowserCore.Tab]
    let tabsByFolder: [String: [BrowserCore.Tab]]
    let folders: [SidebarFolderTree.Row]
    private let visibleTabCount: Int
    private let emptyFolderCount: Int

    init(space: Space, collapsed: Set<String>? = nil) {
        let tree = SidebarFolderTree(space: space)
        let folders = tree.visibleFolders(collapsed: collapsed ?? Set(space.collapsedFolders ?? []))
        let grouped = Dictionary(grouping: space.tabs.filter { $0.pinned && $0.favorite != true }, by: \.folder)
        let byFolder = Dictionary(uniqueKeysWithValues: grouped.compactMap { name, tabs in
            name.map { ($0, tabs) }
        })
        spaceID = space.id
        self.tree = tree
        self.folders = folders
        topLevelTabs = grouped[nil] ?? []
        tabsByFolder = byFolder

        var visibleTabs = topLevelTabs.count
        var emptyFolders = 0
        for folder in folders where folder.expanded {
            let tabCount = byFolder[folder.name]?.count ?? 0
            visibleTabs += tabCount
            if tabCount == 0 && tree.children(of: folder.name).isEmpty { emptyFolders += 1 }
        }
        visibleTabCount = visibleTabs
        emptyFolderCount = emptyFolders
    }

    func height(rowHeight: Double) -> Double {
        Double(visibleTabCount) * (rowHeight + 3) + Double(folders.count) * 35 + Double(emptyFolderCount) * 24 + 8
    }

    func copiedLinks(in folder: String, format: SidebarFolderLinkFormat) -> String? {
        guard tree.names.contains(folder) else { return nil }
        var links: [String] = []
        var pending = [folder]
        while let name = pending.popLast() {
            for tab in tabsByFolder[name, default: []] {
                if let link = Self.formattedLink(for: tab, format: format) { links.append(link) }
            }
            pending.append(contentsOf: tree.children(of: name).reversed())
        }
        return links.isEmpty ? nil : links.joined(separator: "\n")
    }

    private static func formattedLink(for tab: BrowserCore.Tab, format: SidebarFolderLinkFormat) -> String? {
        guard let url = URL(string: tab.homeURL ?? tab.url), let host = QuickBrowseRouting.host(for: url),
              url.user == nil, url.password == nil else { return nil }
        if case .plainText = format { return url.absoluteString }

        let title = tab.sidebarTitle.split { character in
            character.isWhitespace || character.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
        }.joined(separator: " ")
        let punctuation: Set<Character> = ["\\", "`", "*", "_", "[", "]", "<", ">", "&"]
        let label = (title.isEmpty ? host : title).reduce(into: "") {
            if punctuation.contains($1) { $0.append("\\") }
            $0.append($1)
        }
        return "[\(label)](<\(url.absoluteString)>)"
    }
}

struct SidebarSavedTabs: View {
    @ObservedObject var store: BrowserStore
    let theme: AppearanceTheme
    let appearance: AppearanceSettings
    let motion: Animation?
    let height: Double
    let layout: SidebarSavedLayout
    let collapsed: Bool

    var body: some View {
        let spaceID = layout.spaceID
        VStack(spacing: 0) {
            HStack {
                Button { store.requestPinnedShelfCollapsed(!collapsed, in: spaceID) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 8, weight: .semibold)).frame(width: 8)
                            .accessibilityHidden(true)
                        Text("Pinned").font(.system(size: 11, weight: .semibold))
                        Spacer(minLength: 0)
                    }.opacity(0.65).frame(height: 26).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Pinned")
                    .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
                    .help(collapsed ? "Expand Pinned" : "Collapse Pinned")
                    .disabled(!store.canManageSpace(spaceID))
                Button { store.requestNewTabFolder(in: spaceID) } label: {
                    Image(systemName: "folder.badge.plus").font(.system(size: 12)).frame(width: 26, height: 26)
                }.buttonStyle(.plain).help("New Folder").accessibilityLabel("New Folder")
                    .disabled(!store.canManageSpace(spaceID))
            }.padding(.horizontal, 16).frame(height: 26).contentShape(Rectangle())
                .onDrop(of: SidebarTabDrag.dropTypes, delegate: TabDrop(store: store, section: .pinned))
            if !collapsed { pinnedList(in: spaceID) }
        }
    }

    private func pinnedList(in spaceID: UUID) -> some View {
        let empty = layout.topLevelTabs.isEmpty && layout.folders.isEmpty
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 3) {
                ForEach(layout.topLevelTabs) { tab in savedRow(tab) }
                ForEach(layout.folders) { folder in
                    folderHeader(folder, in: spaceID)
                    if folder.expanded {
                        let tabs = layout.tabsByFolder[folder.name, default: []]
                        ForEach(tabs) { tab in
                            savedRow(tab).padding(.leading, indentation(folder.depth + 1))
                        }
                        if tabs.isEmpty && layout.tree.children(of: folder.name).isEmpty {
                            Text("Drop tabs here").font(.system(size: 11))
                                .foregroundStyle(theme.ink.opacity(0.4)).frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, indentation(folder.depth + 1) + 12).frame(height: 21)
                                .onDrop(of: SidebarTabDrag.dropTypes, delegate: TabDrop(store: store, section: .pinned, folder: folder.name))
                        }
                    }
                }
                if empty {
                    Text("Drag tabs here to keep them").font(.system(size: 11))
                        .foregroundStyle(theme.ink.opacity(0.35)).padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, alignment: .leading).frame(height: height)
                } else {
                    Color.clear.frame(height: 8).contentShape(Rectangle())
                }
            }.padding(.horizontal, 8)
        }.frame(height: height).scrollDisabled(empty)
            .scrollIndicators(empty ? .hidden : .automatic)
            .accessibilityLabel("Pinned tabs")
            .onDrop(of: SidebarTabDrag.dropTypes, delegate: TabDrop(store: store, section: .pinned))
    }

    private func indentation(_ depth: Int) -> Double { Double(min(depth, 4)) * 11 }

    private func savedRow(_ tab: BrowserCore.Tab) -> some View {
        SidebarTabRow(tab: tab, spaceID: layout.spaceID, store: store, theme: theme, appearance: appearance, motion: motion)
    }

    private func folderHeader(_ folder: SidebarFolderTree.Row, in spaceID: UUID) -> some View {
        let name = folder.name
        let path = layout.tree.path(to: name)
        return Button {
            withAnimation(motion) {
                do { try store.setTabFolderExpanded(name, expanded: !folder.expanded, in: spaceID) }
                catch { store.message = error.localizedDescription }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: folder.expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold)).frame(width: 9)
                    .foregroundStyle(theme.ink.opacity(0.55)).accessibilityHidden(true)
                Label(name, systemImage: "folder.fill")
                    .font(.system(size: 12 * appearance.textScale, weight: .medium))
                    .foregroundStyle(theme.accent).lineLimit(1)
            }.padding(.leading, indentation(folder.depth) + 9).padding(.trailing, 8)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(path.joined(separator: ", ")))
        .accessibilityValue(folder.expanded ? "Expanded" : "Collapsed")
        .help(path.joined(separator: " › "))
        .disabled(!store.canManageSpace(spaceID))
        .onDrag { NSItemProvider(object: SidebarFolderDrag(spaceID: spaceID, name: name).text as NSString) }
        .onDrop(of: SidebarTabDrag.dropTypes, delegate: TabDrop(store: store, section: .pinned, folder: name))
        .contextMenu {
            Button("New Subfolder…") { store.requestNewTabFolder(in: spaceID, parent: name) }
            Button("Rename Folder…") { store.requestRenameTabFolder(name, in: spaceID) }
            Menu("Move Folder") {
                if layout.tree.parents[name] != nil {
                    Button("Top Level") { move(name, under: nil, in: spaceID) }
                }
                ForEach(layout.tree.names.filter { layout.tree.parents[name] != $0 && layout.tree.canMove(name, under: $0) }, id: \.self) { target in
                    Button(layout.tree.path(to: target).joined(separator: " › ")) { move(name, under: target, in: spaceID) }
                }
            }.disabled(layout.tree.parents[name] == nil && !layout.tree.names.contains { layout.tree.canMove(name, under: $0) })
            Divider()
            Button("Copy All Links") { store.copyPinnedFolderLinks(name, in: spaceID, format: .plainText) }
            Button("Copy All Links as Markdown") { store.copyPinnedFolderLinks(name, in: spaceID, format: .markdown) }
            Divider()
            Button("Remove Folder, Keep Contents") {
                do { try store.removeTabFolder(name, in: spaceID) }
                catch { store.message = error.localizedDescription }
            }
        }
    }

    private func move(_ name: String, under parent: String?, in spaceID: UUID) {
        withAnimation(motion) {
            do { try store.moveTabFolder(name, under: parent, in: spaceID) }
            catch { store.message = error.localizedDescription }
        }
    }
}

struct TabFolderDestinations: View {
    @ObservedObject var store: BrowserStore
    let tabID: UUID
    let spaceID: UUID

    var body: some View {
        let tree = store.session.spaces.first(where: { $0.id == spaceID }).map(SidebarFolderTree.init(space:))
        Menu("Move to Folder") {
            ForEach(tree?.visibleFolders(collapsed: []) ?? []) { folder in
                let name = tree?.path(to: folder.name).joined(separator: " › ") ?? folder.name
                Button { move(to: folder.name) } label: {
                    if store.tab(tabID)?.folder == folder.name { Label(name, systemImage: "checkmark") }
                    else { Text(name) }
                }
            }
            if store.tab(tabID)?.folder != nil { Button("Ungrouped") { move(to: nil) } }
            Divider()
            Button("New Folder…") { store.requestNewTabFolder(in: spaceID, adding: tabID) }
        }.disabled(!store.canManageSpace(spaceID))
    }

    private func move(to name: String?) {
        do { try store.moveTabToFolder(tabID, folder: name, in: spaceID) }
        catch { store.message = error.localizedDescription }
    }
}
