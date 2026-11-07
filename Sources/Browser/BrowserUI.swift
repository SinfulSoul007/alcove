import SwiftUI
import WebKit
import BrowserCore

struct WebPane: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct BrowserUI: View {
    @ObservedObject var store: BrowserStore
    private let ink = Color(red: 0.12, green: 0.18, blue: 0.20)
    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                if store.sidebarVisible { sidebar.frame(width: 242) }
                VStack(spacing: 0) {
                    toolbar
                    if let web = store.currentView, web.isLoading {
                        ProgressView(value: web.estimatedProgress).progressViewStyle(.linear).tint(.teal).frame(height: 2)
                    }
                    HSplitView {
                        pane(store.selectedID)
                        if let split = store.splitID { pane(split) }
                    }
                    .background(.white).clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.black.opacity(0.07)))
                    .padding([.horizontal, .bottom], 8)
                }
            }
            .background(LinearGradient(colors: [Color(red: 0.83, green: 0.90, blue: 0.87), Color(red: 0.91, green: 0.92, blue: 0.84)], startPoint: .topLeading, endPoint: .bottomTrailing))
            if store.commandVisible {
                Color.black.opacity(0.18).ignoresSafeArea().onTapGesture { store.commandVisible = false }
                CommandPanel(store: store).frame(width: 580).offset(y: -110)
            }
            if let message = store.message {
                VStack { Spacer(); HStack {
                    Text(message).font(.system(size: 12)).textSelection(.enabled)
                    Button { store.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }.padding(14).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).shadow(radius: 10).padding(24) }
            }
        }
        .foregroundStyle(ink)
        .frame(minWidth: 800, minHeight: 540)
        .preferredColorScheme(.light)
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "circle.hexagongrid.fill").font(.system(size: 19))
                Text("browser").font(.system(size: 19, weight: .semibold, design: .rounded))
                Spacer()
                Text("PREVIEW").font(.system(size: 8, weight: .bold)).tracking(1).opacity(0.5)
            }.padding(.top, 13)
            Button { store.showCommand() } label: {
                HStack { Image(systemName: "magnifyingglass"); Text("Search or enter URL"); Spacer(); Text("⌘L").opacity(0.5) }
                    .font(.system(size: 12)).padding(12).background(.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
            }.buttonStyle(.plain)
            HStack {
                Text(store.space.name.uppercased()).font(.system(size: 10, weight: .bold)).tracking(1.7)
                Spacer()
                Menu { ForEach(store.session.spaces) { space in Button(space.name) { store.selectSpace(space.id) } }; Divider(); Button("New Space…") { store.addSpace() } } label: { Image(systemName: "chevron.down") }
                    .menuStyle(.borderlessButton).frame(width: 20)
            }.opacity(0.65)
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    if store.space.tabs.contains(where: \.pinned) {
                        label("PINNED")
                        ForEach(store.space.tabs.filter(\.pinned)) { tab in row(tab) }
                        Divider().padding(.vertical, 10)
                    }
                    ForEach(store.space.tabs.filter { !$0.pinned }) { tab in row(tab) }
                    Button { store.showCommand(new: true) } label: { Label("New Tab", systemImage: "plus").font(.system(size: 13)).padding(11).opacity(0.65) }.buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                ForEach(Array(store.session.spaces.enumerated()), id: \.element.id) { index, space in
                    Button { store.selectSpace(space.id) } label: {
                        Text(String(space.name.prefix(1)).uppercased()).font(.system(size: 11, weight: .bold)).frame(width: 28, height: 28)
                            .background(store.session.selectedSpace == space.id ? .white.opacity(0.8) : .white.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).help(space.name)
                }
                Button { store.addSpace() } label: { Image(systemName: "plus").frame(width: 24, height: 28) }.buttonStyle(.plain).help("New Space")
            }
            Text("A little more room for the web.").font(.system(size: 10)).opacity(0.45)
        }.padding(.horizontal, 18).padding(.bottom, 18)
    }
    private func label(_ title: String) -> some View { Text(title).font(.system(size: 9, weight: .bold)).tracking(1.3).opacity(0.4).padding(.horizontal, 10).padding(.bottom, 7) }
    private func row(_ tab: BrowserCore.Tab) -> some View {
        HStack(spacing: 9) {
            Button { store.select(tab.id) } label: {
                HStack(spacing: 9) {
                    Image(systemName: tab.pinned ? "pin.fill" : (tab.url.isEmpty ? "sparkle" : "globe")).font(.system(size: 12)).opacity(0.65).frame(width: 17)
                    Text(tab.title).font(.system(size: 13, weight: store.selectedID == tab.id ? .medium : .regular)).lineLimit(1)
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button { store.close(tab.id) } label: { Image(systemName: "xmark").font(.system(size: 9)).opacity(0.5).frame(width: 18, height: 22) }.buttonStyle(.plain).help("Close Tab")
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(store.selectedID == tab.id ? .white.opacity(0.68) : .clear, in: RoundedRectangle(cornerRadius: 9))
        .contextMenu {
            Button(tab.pinned ? "Unpin Tab" : "Pin Tab") { store.togglePin(tab.id) }
            if tab.id != store.selectedID && !tab.url.isEmpty { Button("Open Beside Current Tab") { store.splitID = tab.id } }
            Menu("Move to Space") { ForEach(store.session.spaces.filter { $0.id != store.space.id }) { s in Button(s.name) { store.move(tab.id, to: s.id) } } }
            Divider(); Button("Close Tab") { store.close(tab.id) }
        }
    }
    private var toolbar: some View {
        HStack(spacing: 14) {
            tool("sidebar.left", "Toggle Sidebar") { store.sidebarVisible.toggle() }
            tool("chevron.left", "Back") { store.currentView?.goBack() }.disabled(store.currentView?.canGoBack != true)
            tool("chevron.right", "Forward") { store.currentView?.goForward() }.disabled(store.currentView?.canGoForward != true)
            tool(store.currentView?.isLoading == true ? "xmark" : "arrow.clockwise", "Reload / Stop") { if store.currentView?.isLoading == true { store.currentView?.stopLoading() } else { store.currentView?.reload() } }
            Spacer()
            Button { store.showCommand() } label: {
                HStack(spacing: 6) {
                    Image(systemName: store.selectedTab?.url.hasPrefix("https:") == true ? "lock" : "globe").font(.system(size: 9))
                    Text(URL(string: store.selectedTab?.url ?? "")?.host ?? "Your next idea starts here").font(.system(size: 11, weight: .medium)).lineLimit(1)
                }.opacity(0.65)
            }.buttonStyle(.plain)
            Spacer()
            tool("rectangle.split.2x1", "Split View") { store.toggleSplit() }
            tool("plus", "New Tab") { store.showCommand(new: true) }
        }.buttonStyle(.plain).padding(.horizontal, 18).frame(height: 48)
    }
    private func tool(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 13)).frame(width: 20, height: 24) }.help(title)
    }
    @ViewBuilder private func pane(_ id: UUID?) -> some View {
        if let id, let tab = store.tab(id), !tab.url.isEmpty {
            WebPane(webView: store.view(for: id)).id(id).frame(minWidth: 250)
        } else {
            VStack(spacing: 22) {
                Spacer()
                Image(systemName: "sun.horizon").font(.system(size: 42, weight: .ultraLight)).foregroundStyle(.teal)
                VStack(spacing: 9) {
                    Text("Room to explore.").font(.system(size: 34, weight: .medium, design: .serif))
                    Text("A quiet place for your next rabbit hole.").font(.system(size: 13)).opacity(0.5)
                }
                Button { store.showCommand() } label: {
                    HStack { Image(systemName: "magnifyingglass"); Text("Search or enter a URL"); Spacer(); Text("⌘L").opacity(0.5) }.font(.system(size: 13)).padding(16).frame(width: 340).background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain)
                HStack(spacing: 12) {
                    quickLink("WebKit", "safari", "https://webkit.org")
                    quickLink("Wikipedia", "book", "https://wikipedia.org")
                    quickLink("GitHub", "chevron.left.forwardslash.chevron.right", "https://github.com")
                }
                Spacer()
                Text("BUILT FOR MAC  ·  POWERED BY WEBKIT").font(.system(size: 9, weight: .medium)).tracking(2).opacity(0.3).padding(.bottom, 28)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(red: 0.98, green: 0.98, blue: 0.96))
        }
    }
    private func quickLink(_ name: String, _ icon: String, _ url: String) -> some View {
        Button { store.navigate(url) } label: {
            VStack(spacing: 9) { Image(systemName: icon).font(.system(size: 17)).frame(width: 48, height: 44).background(.white, in: RoundedRectangle(cornerRadius: 12)); Text(name).font(.system(size: 10)).opacity(0.6) }.frame(width: 82)
        }.buttonStyle(.plain)
    }
}

struct CommandPanel: View {
    @ObservedObject var store: BrowserStore
    @FocusState private var focused: Bool
    var matches: [BrowserCore.Tab] { store.space.tabs.filter { !$0.url.isEmpty && !store.command.isEmpty && ($0.title.localizedCaseInsensitiveContains(store.command) || $0.url.localizedCaseInsensitiveContains(store.command)) }.prefix(5).map { $0 } }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "magnifyingglass").opacity(0.5)
                TextField("Search the web or enter a URL", text: $store.command).textFieldStyle(.plain).font(.system(size: 19)).focused($focused).onSubmit { store.navigate(store.command) }
                Text("↵").opacity(0.4)
            }.padding(22)
            Divider()
            Button { store.navigate(store.command) } label: {
                HStack { Image(systemName: "arrow.up.right"); Text(store.command.isEmpty ? "Type to begin exploring" : "Go to \(store.command)").lineLimit(1); Spacer(); Text("Return").opacity(0.4) }.font(.system(size: 12)).padding(18)
            }.buttonStyle(.plain)
            ForEach(matches) { tab in
                Button { store.select(tab.id); store.commandVisible = false } label: { Label("Switch to \(tab.title)", systemImage: "rectangle.on.rectangle").font(.system(size: 12)).padding(.horizontal, 18).padding(.bottom, 14) }.buttonStyle(.plain)
            }
            HStack { Text("SEARCH WITH DUCKDUCKGO"); Spacer(); Text("ESC TO CLOSE") }.font(.system(size: 8, weight: .medium)).tracking(1).opacity(0.4).padding(14).background(.black.opacity(0.025))
        }.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17)).clipShape(RoundedRectangle(cornerRadius: 17)).shadow(color: .black.opacity(0.2), radius: 40, y: 16)
        .onAppear { focused = true }.onExitCommand { store.commandVisible = false }
    }
}
