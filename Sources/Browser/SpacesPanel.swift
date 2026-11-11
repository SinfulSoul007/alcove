import AppKit
import SwiftUI
import BrowserCore

struct SpaceActionItems: View {
    @ObservedObject var store: BrowserStore
    let spaceID: UUID
    private var index: Int? { store.session.spaces.firstIndex { $0.id == spaceID } }
    private func move(_ offset:Int) {
        guard let index else { return }
        do { try store.moveSpace(spaceID,to:index + offset) } catch { store.message = error.localizedDescription }
    }
    var body: some View {
        Group {
            Button("Rename Space…") { store.requestRenameSpace(spaceID) }
            Menu("Change Icon") {
                ForEach(SpaceSymbol.allCases) { symbol in
                    Button { do { try store.setSpaceIcon(spaceID,icon:symbol.rawValue) } catch { store.message = error.localizedDescription } }
                    label: { Label(symbol.name,systemImage:symbol.rawValue) }
                }
            }
            Button("Customize Space…") { store.customizeSpace(spaceID) }
            Divider()
            Button("Move Left") { move(-1) }.disabled(index == nil || index == 0)
            Button("Move Right") { move(1) }.disabled(index == nil || index == store.session.spaces.count - 1)
            Divider()
            Button("Delete Space…",role:.destructive) { store.requestDeleteSpace(spaceID) }
        }.disabled(!store.canManageSpace(spaceID))
    }
}

struct SpacesPanel: View {
    @ObservedObject var store: BrowserStore
    var topInset: Double = 36
    @FocusState private var backFocused: Bool
    private var motion: Animation? { store.appearance.animationsEnabled ? .spring(response:0.3,dampingFraction:0.9) : nil }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { _ in
            VStack(spacing:14) {
                HStack(spacing:12) {
                    Button { store.presentedPanel = nil } label: { Image(systemName:"arrow.left").frame(width:24,height:28) }
                        .buttonStyle(.plain).help("Back to Browser").accessibilityLabel("Back to Browser").keyboardShortcut(.cancelAction).focused($backFocused)
                    Text("Spaces").font(.system(size:20,weight:.bold)).lineLimit(1)
                    Spacer(minLength:4)
                    Picker("Show Spaces",selection:$store.spacesShowingDeleted) {
                        Text("Open").tag(false); Text("Recently Deleted").tag(true)
                    }.labelsHidden().pickerStyle(.segmented).frame(width:214)
                    Button { store.requestNewSpace() } label: { Image(systemName:"plus").frame(width:26,height:28) }
                        .buttonStyle(.plain).help("New Space").accessibilityLabel("New Space")
                        .disabled(!store.canManageSpace(store.space.id))
                }.padding(.horizontal,20).padding(.top,topInset + 8)
                if let message = store.message { BrowserStatusBanner(store:store,message:message).padding(.horizontal,20) }
                GeometryReader { canvas in
                ScrollView(.horizontal,showsIndicators:false) {
                    LazyHStack(alignment:.top,spacing:16) {
                        if store.spacesShowingDeleted {
                            if store.deletedSpaceEntries.isEmpty {
                                VStack(spacing:12) { Image(systemName:"tray").font(.largeTitle); Text("No deleted Spaces").font(.headline); Text("Spaces you delete will appear here for recovery.").font(.caption).foregroundStyle(.secondary) }
                                    .multilineTextAlignment(.center).frame(width:300).frame(maxHeight:.infinity)
                            }
                            ForEach(store.deletedSpaceEntries) { entry in DeletedSpaceCard(store:store,entry:entry) }
                        } else {
                            ForEach(Array(store.session.spaces.enumerated()),id:\.element.id) { index,space in
                                OpenSpaceCard(store:store,space:space,index:index)
                                    .onDrop(of:[.text],delegate:SpaceDrop(store:store,target:space.id,midpoint:110))
                            }
                            Button { store.requestNewSpace() } label: {
                                VStack(spacing:12) { Image(systemName:"plus.circle.fill").font(.system(size:34)); Text("New Space").font(.headline) }
                                    .frame(width:150).frame(maxHeight:.infinity)
                                    .background(.primary.opacity(0.025),in:RoundedRectangle(cornerRadius:16))
                            }.buttonStyle(.plain).disabled(!store.canManageSpace(store.space.id))
                        }
                    }.frame(height:max(0,canvas.size.height - 16)).padding(.horizontal,20).padding(.vertical,8)
                }
                }.frame(minHeight:0,maxHeight:.infinity)
                Text(store.isPrivate ? "Private Spaces and recovery copies disappear when this private session closes." : "Recently Deleted preserves saved tabs, pins and themes. Unsaved forms cannot be restored.")
                    .font(.system(size:11)).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal,20)
            }.padding(.bottom,12).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.top)
                .background(Color(nsColor:.windowBackgroundColor).opacity(0.97))
                .animation(reduceMotion ? nil : motion,value:store.session.spaces.map(\.id))
                .accessibilityIdentifier("spaces-manager")
                .onAppear { backFocused = true }
        }
    }
}

private struct OpenSpaceCard: View {
    @ObservedObject var store: BrowserStore
    let space: Space
    let index: Int
    private var theme: AppearanceTheme { AppearanceTheme(palette:space.customTheme ?? (SidebarTheme(rawValue:space.theme ?? "midnight") ?? .midnight).palette) }
    private var profileName: String { store.isPrivate ? "Private · Temporary" : store.profiles.first(where:{$0.id == space.effectiveProfileID})?.name ?? "Profile unavailable" }
    private var available: Bool { !store.isShuttingDown && !store.profileUnavailable(space.effectiveProfileID) }
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            HStack(spacing:8) {
                Image(systemName:space.icon ?? SpaceSymbol.defaultName(at:index)).font(.system(size:15))
                Text(space.name.isEmpty ? "Space" : space.name).font(.system(size:14 * store.appearance.textScale,weight:.semibold)).lineLimit(1).help(space.name)
                    .onTapGesture(count:2) { store.requestRenameSpace(space.id) }
                Spacer(minLength:0)
                Button { store.customizeSpace(space.id) } label: { Image(systemName:"paintbrush.pointed").frame(width:22,height:26) }
                    .buttonStyle(.plain).help("Customize \(space.name)").accessibilityLabel("Customize \(space.name)").disabled(!store.canManageSpace(space.id))
            }.padding(14)
            Text(profileName).font(.system(size:10 * store.appearance.textScale)).opacity(0.6).lineLimit(1).padding(.horizontal,14).padding(.bottom,10)
            SpacePreview(store:store,space:space,interactive:true).frame(minHeight:0,maxHeight:.infinity)
            HStack {
                Image(systemName:"arrow.up.and.down.and.arrow.left.and.right").frame(width:24,height:28)
                    .onDrag { NSItemProvider(object:("alcove-space:" + space.id.uuidString) as NSString) }
                    .help("Drag to reorder \(space.name)").accessibilityHidden(true)
                Spacer()
                Button("Open") { store.selectSpace(space.id); store.presentedPanel = nil }.buttonStyle(.plain).font(.system(size:11,weight:.semibold)).disabled(!available)
                Menu { SpaceActionItems(store:store,spaceID:space.id) } label: { Image(systemName:"ellipsis").frame(width:24,height:28) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).accessibilityLabel("\(space.name) actions")
            }.padding(.horizontal,12).padding(.bottom,10)
        }.frame(width:220).frame(maxHeight:.infinity).foregroundStyle(theme.ink).environment(\.colorScheme,theme.isDark ? .dark : .light)
            .background(theme.gradient,in:RoundedRectangle(cornerRadius:16))
            .overlay { RoundedRectangle(cornerRadius:16).stroke(theme.ink.opacity(0.08),lineWidth:1) }
            .contextMenu { SpaceActionItems(store:store,spaceID:space.id) }
            .accessibilityElement(children:.contain).accessibilityLabel("Space: \(space.name)")
    }
}

private struct DeletedSpaceCard: View {
    @ObservedObject var store: BrowserStore
    let entry: DeletedSpaceEntry
    private var space: Space { entry.record.space }
    private var theme: AppearanceTheme { AppearanceTheme(palette:space.customTheme ?? (SidebarTheme(rawValue:space.theme ?? "midnight") ?? .midnight).palette) }
    private var available: Bool { (try? store.requireSpaceProfile(entry.profileID)) != nil }
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            HStack { Image(systemName:space.icon ?? SpaceSymbol.defaultName(at:entry.record.originalIndex)); Text(space.name).font(.system(size:14 * store.appearance.textScale,weight:.semibold)).lineLimit(1) }.padding(14)
            Text(store.isPrivate ? "Private · Temporary" : store.profiles.first(where:{$0.id == entry.profileID})?.name ?? "Profile unavailable").font(.system(size:10 * store.appearance.textScale)).opacity(0.6).padding(.horizontal,14)
            Text(entry.record.deletedAt,style:.date).font(.system(size:10)).opacity(0.6).padding(.horizontal,14).padding(.bottom,10)
            SpacePreview(store:store,space:space,interactive:false).frame(minHeight:0,maxHeight:.infinity)
            HStack {
                Button { do { try store.restoreDeletedSpace(entry.record.id,profileID:entry.profileID) } catch { store.message = error.localizedDescription } }
                label: { Label("Restore",systemImage:"arrow.uturn.backward").font(.system(size:12,weight:.semibold)).frame(maxWidth:.infinity).padding(9).background(theme.tile,in:RoundedRectangle(cornerRadius:8)) }
                    .buttonStyle(.plain).accessibilityLabel("Restore \(space.name)").disabled(!available)
                Menu { Button("Delete Permanently…",role:.destructive) { store.requestPermanentlyDeleteSpace(entry.record.id,profileID:entry.profileID) }.disabled(!available) }
                label: { Image(systemName:"ellipsis").frame(width:22,height:28) }.menuStyle(.borderlessButton).menuIndicator(.hidden).accessibilityLabel("\(space.name) recovery actions")
            }.padding(12)
        }.frame(width:220).frame(maxHeight:.infinity).foregroundStyle(theme.ink).environment(\.colorScheme,theme.isDark ? .dark : .light)
            .background(theme.gradient,in:RoundedRectangle(cornerRadius:16))
            .overlay { RoundedRectangle(cornerRadius:16).stroke(theme.ink.opacity(0.08),lineWidth:1) }
            .accessibilityElement(children:.contain).accessibilityLabel("Deleted Space: \(space.name)")
    }
}

private struct SpacePreview: View {
    @ObservedObject var store: BrowserStore
    let space: Space
    let interactive: Bool
    @State private var collapsed: Set<String>
    init(store:BrowserStore,space:Space,interactive:Bool) {
        self.store = store; self.space = space; self.interactive = interactive
        _collapsed = State(initialValue:Set(space.collapsedFolders ?? []))
    }
    private var pins: [BrowserCore.Tab] { space.tabs.filter {$0.pinned && $0.favorite != true && !$0.url.isEmpty} }
    private var today: [BrowserCore.Tab] { space.tabs.filter {!$0.pinned && !$0.url.isEmpty} }
    var body: some View {
        ScrollView(.vertical,showsIndicators:false) {
            VStack(alignment:.leading,spacing:5) {
                ForEach(pins.filter{$0.folder == nil}) { tab in preview(tab) }
                ForEach(Array(Set(pins.compactMap(\.folder))).sorted(),id:\.self) { folder in
                    DisclosureGroup(isExpanded:Binding(get:{!collapsed.contains(folder)},set:{ if $0 { collapsed.remove(folder) } else { collapsed.insert(folder) } })) {
                        ForEach(pins.filter{$0.folder == folder}) { tab in preview(tab) }
                    } label: { Label(folder,systemImage:"folder").font(.system(size:12 * store.appearance.textScale,weight:.medium)).lineLimit(1).padding(.vertical,6) }
                }
                if !today.isEmpty { Divider().padding(.vertical,8); Text("Today").font(.system(size:10,weight:.semibold)).opacity(0.5); ForEach(today) { tab in preview(tab) } }
                if pins.isEmpty && today.isEmpty { Text("No saved tabs").font(.system(size:12)).opacity(0.5).padding(.vertical,20) }
            }.padding(.horizontal,14).padding(.bottom,12)
        }
    }
    @ViewBuilder private func preview(_ tab:BrowserCore.Tab) -> some View {
        let row = HStack(spacing:8) { Image(systemName:tab.pinned ? "pin.fill" : "globe").font(.system(size:11)).opacity(0.6); Text(tab.pinnedTitle ?? tab.title).font(.system(size:12 * store.appearance.textScale)).lineLimit(1); Spacer(minLength:0) }.padding(.vertical,7).contentShape(Rectangle())
        if interactive {
            Button { store.selectSpace(space.id); store.select(tab.id); store.presentedPanel = nil } label: { row }
                .buttonStyle(.plain).help(tab.url).disabled(store.isShuttingDown || store.profileUnavailable(space.effectiveProfileID))
        } else { row }
    }
}
