import SwiftUI
import BrowserCore

struct SidebarSavedLayout {
    let tree: SidebarFolderTree
    let topLevelTabs: [BrowserCore.Tab]
    let tabsByFolder: [String: [BrowserCore.Tab]]
    let folders: [SidebarFolderTree.Row]

    init(space: Space, collapsed: Set<String>? = nil) {
        tree = SidebarFolderTree(space: space)
        let pins = space.tabs.filter { $0.pinned && $0.favorite != true }
        let grouped = Dictionary(grouping: pins, by: \.folder)
        topLevelTabs = grouped[nil] ?? []
        tabsByFolder = Dictionary(uniqueKeysWithValues: grouped.compactMap { name, tabs in
            name.map { ($0, tabs) }
        })
        folders = tree.visibleFolders(collapsed: collapsed ?? Set(space.collapsedFolders ?? []))
    }

    func height(rowHeight: Double) -> Double {
        let tabs = folders.reduce(topLevelTabs.count) { count, folder in
            count + (folder.expanded ? tabsByFolder[folder.name, default: []].count : 0)
        }
        let empty = folders.filter {
            $0.expanded && tabsByFolder[$0.name, default: []].isEmpty && tree.children(of: $0.name).isEmpty
        }.count
        return Double(tabs) * (rowHeight + 3) + Double(folders.count) * 35 + Double(empty) * 24 + 8
    }
}

struct SidebarSavedTabs: View {
    @ObservedObject var store: BrowserStore
    let theme: AppearanceTheme
    let appearance: AppearanceSettings
    let motion: Animation?
    let height: Double
    let layout: SidebarSavedLayout

    var body: some View {
        let spaceID = store.space.id
        VStack(spacing: 0) {
            HStack {
                Text("Pinned").font(.system(size: 11, weight: .semibold)).opacity(0.5)
                Spacer()
                Button { store.requestNewTabFolder(in: spaceID) } label: {
                    Image(systemName: "folder.badge.plus").font(.system(size: 12)).frame(width: 26, height: 26)
                }.buttonStyle(.plain).help("New Folder").accessibilityLabel("New Folder")
                    .disabled(!store.canManageSpace(spaceID))
            }.padding(.horizontal, 16).frame(height: 26)
            ScrollView {
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
                                    .onDrop(of: [.text], delegate: TabDrop(store: store, section: .pinned, folder: folder.name))
                            }
                        }
                    }
                    if layout.topLevelTabs.isEmpty && layout.folders.isEmpty {
                        Text("Drag tabs here to keep them").font(.system(size: 11))
                            .foregroundStyle(theme.ink.opacity(0.35)).padding(.horizontal, 10).frame(height: 32)
                    }
                    Color.clear.frame(height: 8).contentShape(Rectangle())
                }.padding(.horizontal, 8)
            }.frame(height: height).accessibilityLabel("Pinned tabs")
                .onDrop(of: [.text], delegate: TabDrop(store: store, section: .pinned))
        }
    }

    private func indentation(_ depth: Int) -> Double { Double(min(depth, 4)) * 11 }

    private func savedRow(_ tab: BrowserCore.Tab) -> some View {
        SidebarTabRow(tab: tab, store: store, theme: theme, appearance: appearance, motion: motion)
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
        .onDrop(of: [.text], delegate: TabDrop(store: store, section: .pinned, folder: name))
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
