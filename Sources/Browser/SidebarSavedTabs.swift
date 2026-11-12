import SwiftUI
import BrowserCore

struct SidebarSavedTabs:View {
    @ObservedObject var store:BrowserStore
    let theme:AppearanceTheme
    let appearance:AppearanceSettings
    let motion:Animation?
    let height:Double
    private var pins:[BrowserCore.Tab] {store.space.tabs.filter {$0.pinned && $0.favorite != true}}
    var body:some View {
        let spaceID = store.space.id
        VStack(spacing:0) {
            HStack {
                Text("Pinned").font(.system(size:11,weight:.semibold)).opacity(0.5)
                Spacer()
                Button {store.requestNewTabFolder(in:spaceID)} label: {Image(systemName:"folder.badge.plus").font(.system(size:12)).frame(width:26,height:26)}
                    .buttonStyle(.plain).help("New Folder").accessibilityLabel("New Folder").disabled(!store.canManageSpace(spaceID))
            }.padding(.horizontal,16).frame(height:26)
            ScrollView {
                LazyVStack(alignment:.leading,spacing:3) {
                    ForEach(pins.filter {$0.folder == nil}) {tab in savedRow(tab)}
                    ForEach(store.space.folderNames,id:\.self) {name in folder(name,in:spaceID)}
                    if pins.isEmpty && store.space.folderNames.isEmpty {
                        Text("Drag tabs here to keep them").font(.system(size:11)).foregroundStyle(theme.ink.opacity(0.35)).padding(.horizontal,10).frame(height:32)
                    }
                    Color.clear.frame(height:8).contentShape(Rectangle())
                }.padding(.horizontal,8)
            }.frame(height:height).accessibilityLabel("Pinned tabs")
                .onDrop(of:[.text],delegate:TabDrop(store:store,section:.pinned))
        }
    }
    private func savedRow(_ tab:BrowserCore.Tab) -> some View {SidebarTabRow(tab:tab,store:store,theme:theme,appearance:appearance,motion:motion)}
    private func folder(_ name:String,in spaceID:UUID) -> some View {
        DisclosureGroup(isExpanded:Binding(get:{!(store.space.collapsedFolders ?? []).contains(name)},set:{expanded in
            do {try store.setTabFolderExpanded(name,expanded:expanded,in:spaceID)} catch {store.message = error.localizedDescription}
        })) {
            ForEach(pins.filter {$0.folder == name}) {tab in savedRow(tab)}
            if !pins.contains(where:{$0.folder == name}) {
                Text("Drop tabs here").font(.system(size:11)).foregroundStyle(theme.ink.opacity(0.4)).frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,6)
            }
        } label: {
            Label(name,systemImage:"folder.fill").font(.system(size:12 * appearance.textScale,weight:.medium)).lineLimit(1).padding(.vertical,7).foregroundStyle(theme.accent)
        }.tint(theme.ink.opacity(0.4)).padding(.horizontal,9)
            .disabled(!store.canManageSpace(spaceID))
            .onDrop(of:[.text],delegate:TabDrop(store:store,section:.pinned,folder:name))
            .contextMenu {
                Button("Rename Folder…") {store.requestRenameTabFolder(name,in:spaceID)}
                Button("Remove Folder, Keep Tabs") {do {try store.removeTabFolder(name,in:spaceID)} catch {store.message = error.localizedDescription}}
            }
    }
}

struct TabFolderDestinations:View {
    @ObservedObject var store:BrowserStore
    let tabID:UUID
    let spaceID:UUID
    var body:some View {
        Menu("Move to Folder") {
            ForEach(store.session.spaces.first(where:{$0.id == spaceID})?.folderNames ?? [],id:\.self) {name in
                Button {move(to:name)} label: {if store.tab(tabID)?.folder == name {Label(name,systemImage:"checkmark")} else {Text(name)}}
            }
            if store.tab(tabID)?.folder != nil {Button("Ungrouped") {move(to:nil)}}
            Divider()
            Button("New Folder…") {store.requestNewTabFolder(in:spaceID,adding:tabID)}
        }.disabled(!store.canManageSpace(spaceID))
    }
    private func move(to name:String?) {do {try store.moveTabToFolder(tabID,folder:name,in:spaceID)} catch {store.message = error.localizedDescription}}
}
