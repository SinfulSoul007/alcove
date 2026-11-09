import AppKit
import SwiftUI
import WebKit
import BrowserCore

/// Window-local interaction state. Native window ownership belongs to the controller.
@MainActor
final class QuickBrowseWindowState: ObservableObject {
    @Published var addressText = ""
    @Published var isEditingAddress = false
    @Published var siteSearch: SiteSearch?
    var locationContext: SearchInputContext?
    private var locationURL = ""
    @Published private(set) var locationFocusRequest = 0
    @Published var findText = "" {
        didSet { if findText != oldValue { findGeneration = UUID(); findResult = "" } }
    }
    @Published private(set) var findResult = ""
    @Published private(set) var findVisible = false
    @Published private(set) var findFocusRequest = 0
    @Published var navigationError: String?
    @Published private(set) var mediaStatus: String?
    private var findGeneration = UUID()
    private var mediaGeneration = UUID()

    func requestLocation(currentURL: String, context: SearchInputContext? = nil) {
        dismissFind()
        locationURL = currentURL; addressText = currentURL
        siteSearch = nil; locationContext = context; navigationError = nil
        isEditingAddress = true
        locationFocusRequest += 1
    }
    func beginLocation(context: SearchInputContext?) {
        guard !isEditingAddress else { return }
        siteSearch = nil; locationContext = context; isEditingAddress = true; navigationError = nil
    }
    @discardableResult func activateSiteSearch(_ site: SiteSearch, context: SearchInputContext) -> Bool {
        guard isEditingAddress, locationContext == context, site.enabled, (try? site.validated()) == site else { return false }
        siteSearch = site; addressText = ""; navigationError = nil; locationFocusRequest += 1; return true
    }
    func leaveSiteSearch(restoreKeyword: Bool) {
        if restoreKeyword, let siteSearch { addressText = siteSearch.keyword }
        siteSearch = nil; navigationError = nil
    }
    @discardableResult func activatePreferredSiteSearch(catalog: SiteSearchCatalog, context: SearchInputContext?) -> Bool {
        guard siteSearch == nil, let context, let site = catalog.preferredMatch(addressText) else { return false }
        return activateSiteSearch(site, context: context)
    }
    @discardableResult func deleteEmptySiteSearch() -> Bool {
        guard siteSearch != nil, addressText.isEmpty else { return false }
        leaveSiteSearch(restoreKeyword: true); return true
    }
    func syncLocation(currentURL: String) {
        locationURL = currentURL
        if !isEditingAddress { addressText = currentURL }
    }
    func cancelLocation(currentURL: String) {
        isEditingAddress = false; siteSearch = nil; locationContext = nil
        locationURL = currentURL; addressText = currentURL
    }
    func showFind() {
        isEditingAddress = false; siteSearch = nil; locationContext = nil; addressText = locationURL
        findVisible = true
        findFocusRequest += 1
    }
    func dismissFind() {
        findGeneration = UUID()
        findVisible = false
        findResult = ""
    }
    /// The caller must validate that this is still this quick page's registered view.
    func findNext(web: WKWebView?, backwards: Bool = false,
                  stillCurrent: @escaping @MainActor (WKWebView) -> Bool) {
        guard findVisible, let web, stillCurrent(web) else { return }
        let query = findText
        let url = web.url
        let generation = UUID()
        findGeneration = generation
        guard !query.isEmpty else { findResult = ""; return }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.wraps = true
        configuration.caseSensitive = false
        web.find(query, configuration: configuration) { [weak self, weak web] result in
            Task { @MainActor in
                guard let self, let web, stillCurrent(web), self.findVisible,
                      self.findText == query, self.findGeneration == generation, web.url == url else { return }
                self.findResult = result.matchFound ? "" : "No matches"
            }
        }
    }
    func refreshMediaStatus(web: WKWebView,
                                        stillCurrent: @escaping @MainActor (WKWebView) -> Bool) {
        let url = web.url
        let generation = UUID()
        mediaGeneration = generation
        web.requestMediaPlaybackState { [weak self, weak web] playback in
            Task { @MainActor in
                guard let self, let web, stillCurrent(web), web.url == url,
                      self.mediaGeneration == generation else { return }
                var status: [String] = []
                if web.cameraCaptureState == .active { status.append("Camera in use") }
                if web.microphoneCaptureState == .active { status.append("Microphone in use") }
                if playback == .playing { status.append("Playing audio or video") }
                let next = status.isEmpty ? nil : status.joined(separator: " · ")
                if self.mediaStatus != next { self.mediaStatus = next }
            }
        }
    }
    fileprivate func clearMediaStatus() { mediaGeneration = UUID(); mediaStatus = nil }
}

@MainActor
struct QuickBrowseUI: View {
    @ObservedObject var store: BrowserStore
    @StateObject private var chrome = NativeWindowChrome()
    let id: UUID
    @ObservedObject var state: QuickBrowseWindowState
    let onPromoteSpace: (UUID?) -> Void
    let onPromotePeek: () -> Void
    let onRequestProfile: (UUID, Bool) -> Void
    let onManageProfiles: () -> Void
    let onOpenSettings: () -> Void
    let onClose: () -> Void
    let onNewQuick: () -> Void

    init(store: BrowserStore, id: UUID, state: QuickBrowseWindowState,
         onPromoteSpace: @escaping (UUID?) -> Void,
         onPromotePeek: @escaping () -> Void,
         onRequestProfile: @escaping (UUID, Bool) -> Void,
         onManageProfiles: @escaping () -> Void,
         onOpenSettings: @escaping () -> Void,
         onClose: @escaping () -> Void,
         onNewQuick: @escaping () -> Void) {
        self.store = store; self.id = id; self.state = state
        self.onPromoteSpace = onPromoteSpace; self.onPromotePeek = onPromotePeek
        self.onRequestProfile = onRequestProfile; self.onManageProfiles = onManageProfiles
        self.onOpenSettings = onOpenSettings; self.onClose = onClose; self.onNewQuick = onNewQuick
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var profilePickerVisible = false
    @State private var rememberHost = false

    private var page: QuickPage? { store.quickPage(id) }
    private var ownerID: UUID? { store.quickProfileID(id) }
    private var owner: BrowserProfile? { store.profiles.first { $0.id == ownerID } }
    private var ownerName: String { store.isPrivate ? "Private" : (owner?.name ?? "Unavailable profile") }
    private var currentURL: String { ownPeek?.url?.absoluteString ?? page?.tab.url ?? "" }
    private var currentHost: String? { URL(string: currentURL).flatMap(QuickBrowseRouting.host(for:)) }
    private var ownerAvailable: Bool { ownerID.map { !store.profileUnavailable($0) } ?? false }
    private var canSave: Bool { store.isPrivate || store.savingEnabled }
    private var canMove: Bool { page != nil && ownerAvailable && canSave }
    private var ownPeek: WKWebView? { store.quickPeekView(id) }
    private var foregroundWeb: WKWebView? { store.foregroundQuickView(id) }
    private var appearance: AppearanceSettings { store.appearance }
    private var theme: AppearanceTheme {
        if let intended = page?.intendedSpaceID,
           let space = store.session.spaces.first(where: { $0.id == intended && (store.isPrivate || $0.effectiveProfileID == ownerID) }) {
            return AppearanceTheme(palette: space.customTheme ?? (SidebarTheme(rawValue: space.theme ?? "midnight") ?? .midnight).palette)
        }
        return store.activeTheme
    }
    private var motion: Animation? {
        reduceMotion || !appearance.animationsEnabled ? nil : .easeInOut(duration: 0.16)
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                toolbar(compact: geometry.size.width < 680)
                statusBanners
                if state.findVisible { findBar }
                // The web host has a stable location, independent of toolbar/popup state.
                QuickBrowsePageContent(store: store, id: id, state: state, theme: theme,
                                       onRequestLocation: requestLocation)
                    .overlay(alignment: .top) { progress }
                    .overlay { if let peek = ownPeek { peekOverlay(peek, size: geometry.size) } }
                    .animation(motion, value: ownPeek != nil)
            }
            .background(theme.gradient)
            .foregroundStyle(theme.ink)
            .preferredColorScheme(theme.isDark ? .dark : .light)
            .ignoresSafeArea()
            .onAppear {
                state.syncLocation(currentURL: currentURL)
                if currentURL.isEmpty { requestLocation() }
            }
            .onChange(of: currentURL) { _, value in
                state.syncLocation(currentURL: value)
                state.clearMediaStatus()
                rememberHost = false
            }
            .onChange(of: store.views[id]?.isLoading) { _, loading in
                if loading == false { refreshMediaStatus() }
            }
            // registerView publishes a revision when these KVO properties change.
            .onChange(of: store.views[id]?.cameraCaptureState) { _, _ in refreshMediaStatus() }
            .onChange(of: store.views[id]?.microphoneCaptureState) { _, _ in refreshMediaStatus() }
            .onChange(of: ownPeek.map(ObjectIdentifier.init)) { _, _ in
                profilePickerVisible = false; state.dismissFind(); state.cancelLocation(currentURL: currentURL); refreshMediaStatus()
            }
            .onChange(of: ownPeek?.isLoading) { _, loading in if loading == false { refreshMediaStatus() } }
            .onChange(of: ownPeek?.cameraCaptureState) { _, _ in refreshMediaStatus() }
            .onChange(of: ownPeek?.microphoneCaptureState) { _, _ in refreshMediaStatus() }
            .onChange(of: ownerID) { _, _ in
                rememberHost = false
                state.cancelLocation(currentURL: currentURL)
                state.dismissFind()
                state.clearMediaStatus()
            }
            .onExitCommand(perform: cancelEditing)
        }
    }

    private func toolbar(compact: Bool) -> some View {
        HStack(spacing: 6) {
            // Full-size content windows draw native traffic lights above this reserved area.
            Color.clear.frame(width: max(0, chrome.leadingEdge - 14)).accessibilityHidden(true).allowsHitTesting(false)
            toolbarButton("arrow.left", label: "Back", enabled: foregroundWeb?.canGoBack == true && ownerAvailable) { store.performQuickNavigation(id, action: .back) }
            toolbarButton("arrow.right", label: "Forward", enabled: foregroundWeb?.canGoForward == true && ownerAvailable) { store.performQuickNavigation(id, action: .forward) }
            toolbarButton(foregroundWeb?.isLoading == true ? "xmark" : "arrow.clockwise",
                          label: foregroundWeb?.isLoading == true ? "Stop loading" : "Reload page",
                          enabled: foregroundWeb != nil && ownerAvailable) {
                store.performQuickNavigation(id, action: foregroundWeb?.isLoading == true ? .stop : .reload)
            }
            addressField
            if !compact {
                Button { profilePickerVisible.toggle() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: store.isPrivate ? "hand.raised.fill" : "person.crop.circle")
                        Text(ownerName).lineLimit(1).truncationMode(.tail)
                    }.font(.system(size: 11 * appearance.textScale, weight: .medium))
                        .frame(maxWidth: 105).padding(.horizontal, 8).frame(height: 30)
                }.buttonStyle(.plain).fixedSize(horizontal: true, vertical: false)
                    .background(theme.tile, in: RoundedRectangle(cornerRadius: appearance.cornerRadius))
                    .disabled(ownPeek != nil).help("Profile: \(ownerName)").accessibilityLabel("Choose profile, currently \(ownerName)")
                Menu { destinationMenu } label: {
                    Label("Open in Space", systemImage: "arrow.up.forward.square")
                        .font(.system(size: 11 * appearance.textScale, weight: .medium))
                }.menuStyle(.borderlessButton).fixedSize().disabled(!canMove || ownPeek != nil)
                    .help("Move this live page into a Space")
            }
            Menu {
                if compact {
                    Button("Profile: \(ownerName)…") { profilePickerVisible = true }.disabled(ownPeek != nil)
                    Menu("Open in Space") { destinationMenu }.disabled(!canMove || ownPeek != nil)
                    Divider()
                }
                Button("New Quick Browse", action: onNewQuick).disabled(!canMove)
                Button("Find in Page…") { state.showFind() }.disabled(store.views[id] == nil || !ownerAvailable)
                Button("Copy Address") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(currentURL, forType: .string)
                }.disabled(currentURL.isEmpty)
                Divider()
                Button("Settings…", action: onOpenSettings)
                Button("Close Quick Browse", action: onClose)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 14, weight: .medium)).frame(width: 25, height: 30)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize(horizontal: true, vertical: false)
                .help("Quick Browse actions").accessibilityLabel("Quick Browse actions")
        }
        .buttonStyle(.plain)
        .padding(.leading, 8).padding(.trailing, 10)
        .frame(height: chrome.height)
        .background(NativeChromeReader(chrome: chrome))
        .background(theme.gradient)
        .popover(isPresented: $profilePickerVisible, arrowEdge: .bottom) { profilePicker }
    }

    private var addressField: some View {
        HStack(spacing: 7) {
            if state.isEditingAddress, let site = state.siteSearch {
                SiteSearchPill(site: site, maximumWidth: 92, scale: appearance.textScale, fill: theme.selected) { state.leaveSiteSearch(restoreKeyword: false) }
                    .layoutPriority(2)
            }
            else if state.isEditingAddress { Image(systemName: "magnifyingglass").font(.system(size: 11)).opacity(0.65) }
            else { SiteBadge(url: currentURL, image: appearance.showFavicons ? store.siteIcons[id] : nil) }
            QuickBrowseInput(text: $state.addressText, placeholder: state.siteSearch.map { "Search \($0.name)" } ?? "Search or enter a URL",
                             size: 12 * appearance.textScale, ink: NSColor(theme.ink),
                             focusRequest: state.locationFocusRequest, selectAll: true,
                             resignFocus: !state.isEditingAddress,
                             onBeginEditing: { state.beginLocation(context: store.searchInputContext(quickID: id)) },
                             onEndEditing: { state.cancelLocation(currentURL: currentURL) },
                             onSubmit: navigate,
                             onCancel: { state.cancelLocation(currentURL: currentURL); focusPage() },
                             onTab: { state.activatePreferredSiteSearch(catalog: store.siteSearchCatalog, context: store.searchInputContext(quickID: id)) },
                             onEmptyDelete: { state.deleteEmptySiteSearch() })
                .frame(minWidth: 80, maxWidth: .infinity).frame(height: 24).layoutPriority(1)
                .disabled(!ownerAvailable || page == nil)
            if state.isEditingAddress, state.siteSearch == nil, let site = store.siteSearchCatalog.preferredMatch(state.addressText) {
                Text("⇥").font(.system(size: 11 * appearance.textScale)).opacity(0.55)
                    .help("Press Tab to search \(site.name)").accessibilityLabel("Press Tab to search \(site.name)")
            }
            if state.mediaStatus != nil {
                Image(systemName: "speaker.wave.2.fill").font(.system(size: 10))
                    .help(state.mediaStatus ?? "").accessibilityLabel(state.mediaStatus ?? "Media active")
            }
        }
        .padding(.horizontal, 9).frame(minWidth: 0, maxWidth: .infinity).frame(height: 31)
        .background(state.isEditingAddress ? theme.selected : theme.tile, in: RoundedRectangle(cornerRadius: appearance.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: appearance.cornerRadius).stroke(theme.ink.opacity(state.isEditingAddress ? 0.22 : 0.06), lineWidth: 1))
        .help(currentURL.isEmpty ? "Search or enter a URL (⌘L)" : currentURL)
        .animation(motion, value: state.siteSearch?.id)
    }

    @ViewBuilder private var statusBanners: some View {
        if !canSave {
            HStack(alignment: .center, spacing: 9) {
                Image(systemName: "lock.fill").accessibilityHidden(true)
                Text("Local saving is paused. Unlock to save changes.").frame(maxWidth: .infinity, alignment: .leading)
                Button(store.unlocking ? "Unlocking…" : "Unlock") { store.unlockLocalData() }.disabled(store.unlocking)
            }.font(.system(size: 11 * appearance.textScale)).padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.orange.opacity(0.15))
        }
        if let error = state.navigationError ?? store.message {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.circle").accessibilityHidden(true)
                Text(error).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    state.navigationError = nil
                    store.message = nil
                } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                    .help("Dismiss message").accessibilityLabel("Dismiss message")
            }.font(.system(size: 11 * appearance.textScale)).padding(.horizontal, 12).padding(.vertical, 8)
                .background(theme.selected)
        }
        if store.isPrivate {
            Text("Private · Temporary website storage. Downloads stay on disk.")
                .font(.system(size: 10 * appearance.textScale)).frame(maxWidth: .infinity).padding(.vertical, 5)
                .background(theme.tile)
        }
    }

    private var findBar: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").accessibilityHidden(true)
            QuickBrowseInput(text: $state.findText, placeholder: "Find in page", size: 12 * appearance.textScale,
                             ink: NSColor(theme.ink), focusRequest: state.findFocusRequest, selectAll: true,
                             onSubmit: { findNext() }, onCancel: { state.dismissFind(); focusPage() },
                             onMove: { findNext(backwards: $0 < 0) })
                .frame(minWidth: 0, maxWidth: .infinity).frame(height: 24)
                .onChange(of: state.findText) { _, _ in findNext() }
            if !state.findResult.isEmpty {
                Text(state.findResult).font(.system(size: 10 * appearance.textScale)).foregroundStyle(.secondary)
                    .accessibilityLabel(state.findResult)
            }
            toolbarButton("chevron.up", label: "Previous match", enabled: !state.findText.isEmpty) { findNext(backwards: true) }
            toolbarButton("chevron.down", label: "Next match", enabled: !state.findText.isEmpty) { findNext() }
            toolbarButton("xmark", label: "Close Find") { state.dismissFind(); focusPage() }
        }.font(.system(size: 12 * appearance.textScale)).padding(.horizontal, 12).padding(.vertical, 5)
            .background(theme.tile)
    }

    @ViewBuilder private var progress: some View {
        if let web = foregroundWeb, web.isLoading {
            ProgressView(value: min(1, max(0, web.estimatedProgress)))
                .progressViewStyle(.linear).tint(theme.accent).frame(height: 2)
                .accessibilityLabel("Loading page").accessibilityValue("\(Int(web.estimatedProgress * 100)) percent")
        }
    }

    private var profilePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(store.isPrivate ? "Private browsing" : "Page profile").font(.headline)
            if store.isPrivate {
                Text("This window uses temporary website storage. Its pages stay separate from your normal profiles.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("This page uses \(ownerName)’s website logins. Choosing another profile reloads it.")
                    .font(.callout).foregroundStyle(.secondary)
                if let host = currentHost {
                    Toggle("Remember this profile for \(host)", isOn: $rememberHost).toggleStyle(.checkbox)
                        .font(.system(size: 12)).disabled(!canMove)
                }
                Divider()
                ForEach(store.profiles) { profile in
                    Button {
                        profilePickerVisible = false
                        onRequestProfile(profile.id, rememberHost && currentHost != nil)
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: profile.icon).frame(width: 18)
                            Text(profile.name).lineLimit(1)
                            Spacer(minLength: 8)
                            if store.profileUnavailable(profile.id) { Text("Unavailable").font(.caption).foregroundStyle(.secondary) }
                            if profile.id == ownerID { Image(systemName: "checkmark").foregroundStyle(theme.accent) }
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .disabled(!canMove || store.profileUnavailable(profile.id) || (profile.id == ownerID && !rememberHost))
                        .accessibilityLabel("\(profile.name)\(profile.id == ownerID ? ", current profile" : "")")
                }
                Divider()
                Button("Manage Profiles…") { profilePickerVisible = false; onManageProfiles() }
            }
        }.padding(16).frame(width: 290).foregroundStyle(theme.ink).background(theme.gradient)
            .preferredColorScheme(theme.isDark ? .dark : .light)
    }

    @ViewBuilder private var destinationMenu: some View {
        let preferred = store.session.spaces.first { $0.id == page?.intendedSpaceID && (store.isPrivate || $0.effectiveProfileID == ownerID) }
            ?? store.session.spaces.first { store.isPrivate || $0.effectiveProfileID == ownerID }
        Button {
            onPromoteSpace(nil)
        } label: {
            Label(preferred.map { "Open in \($0.name)" } ?? "Open in New Space", systemImage: "arrow.up.forward.square")
        }.disabled(!canMove)
        Text(store.isPrivate ? "Keeps this page private" : "Keeps the \(ownerName) profile and live page")
        Divider()
        ForEach(store.session.spaces) { space in
            let profileName = store.isPrivate ? "Private" : (store.profiles.first { $0.id == space.effectiveProfileID }?.name ?? "Unavailable profile")
            Button("\(space.name) · \(profileName)\(!store.isPrivate && space.effectiveProfileID != ownerID ? "…" : "")") {
                onPromoteSpace(space.id)
            }.disabled(!canMove || store.profileUnavailable(store.isPrivate ? BrowserProfile.defaultID : space.effectiveProfileID))
        }
    }

    private func peekOverlay(_ web: WKWebView, size: CGSize) -> some View {
        ZStack {
            Color.black.opacity(0.3).contentShape(Rectangle()).onTapGesture {
                store.closeQuickPeek(id)
            }.accessibilityLabel("Close Peek").accessibilityAddTraits(.isButton)
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    toolbarButton("xmark", label: "Close Peek") {
                        store.closeQuickPeek(id)
                    }
                    Text(web.url?.host ?? "Peek").font(.system(size: 12 * appearance.textScale, weight: .medium))
                        .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    Button("Open in Space", action: onPromotePeek).font(.system(size: 11 * appearance.textScale))
                        .disabled(!canMove).help("Move the Peek page into a Space")
                }.padding(10).background(theme.gradient)
                WebPane(webView: web).id(ObjectIdentifier(web))
            }
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: appearance.cornerRadius + 2))
            .overlay(RoundedRectangle(cornerRadius: appearance.cornerRadius + 2).stroke(theme.ink.opacity(0.12)))
            .padding(min(24, size.width * 0.035))
            .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
            .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.985)))
        }.animation(motion, value: ownPeek != nil)
    }

    private func toolbarButton(_ symbol: String, label: String, enabled: Bool = true,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).frame(width: 25, height: 28)
        }.buttonStyle(.plain).disabled(!enabled).help(label).accessibilityLabel(label)
    }
    private func requestLocation() { state.requestLocation(currentURL: currentURL, context: store.searchInputContext(quickID: id)) }
    private func navigate() {
        guard state.isEditingAddress else { return }
        do {
            try store.navigateForegroundQuickPage(id, input: state.addressText, selection: state.siteSearch, context: state.locationContext)
            state.navigationError = nil
            state.cancelLocation(currentURL: currentURL)
            focusPage()
        } catch { state.navigationError = error.localizedDescription }
    }
    private func refreshMediaStatus() {
        guard let web = foregroundWeb else { return }
        state.refreshMediaStatus(web: web) { [weak store] candidate in
            guard let store, store.quickPage(id) != nil else { return false }
            return store.foregroundQuickView(id) === candidate
        }
    }
    private func findNext(backwards: Bool = false) {
        state.findNext(web: foregroundWeb, backwards: backwards) { [weak store] web in
            guard let store, store.quickPage(id) != nil else { return false }
            return store.foregroundQuickView(id) === web
        }
    }
    private func focusPage() {
        guard let web = foregroundWeb, let window = web.window, window.isKeyWindow else { return }
        window.makeFirstResponder(web)
    }
    private func cancelEditing() {
        if state.findVisible { state.dismissFind(); focusPage() }
        else if state.isEditingAddress { state.cancelLocation(currentURL: currentURL); focusPage() }
        else if ownPeek != nil { store.closeQuickPeek(id) }
    }
}

/// A separate subtree ensures focus and popover changes never replace the live WebPane.
@MainActor
private struct QuickBrowsePageContent: View {
    @ObservedObject var store: BrowserStore
    let id: UUID
    let state: QuickBrowseWindowState
    let theme: AppearanceTheme
    let onRequestLocation: () -> Void

    var body: some View {
        ZStack {
            if let page = store.quickPage(id), let owner = store.quickProfileID(id) {
                if store.profileUnavailable(owner) {
                    VStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.badge.exclamationmark").font(.system(size: 26)).opacity(0.55)
                        Text("This page’s profile is unavailable.").font(.headline)
                        Text("Unlock local data or finish its pending profile operation to continue.")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.padding(24)
                } else if !page.tab.url.isEmpty {
                    let web = store.view(for: id)
                    WebPane(webView: web).id(ObjectIdentifier(web))
                        .task(id: ObjectIdentifier(web)) {
                            state.refreshMediaStatus(web: web) { [weak store] candidate in
                                store?.foregroundQuickView(id) === candidate && store?.quickPage(id) != nil
                            }
                        }
                } else {
                    VStack(spacing: 13) {
                        Image(systemName: "arrow.up.forward.square").font(.system(size: 30, weight: .light)).foregroundStyle(theme.accent)
                        Text("A little room to browse.").font(.system(size: 20 * store.appearance.textScale, weight: .medium, design: .rounded))
                        Text("Search or enter a URL above. Move a page into a Space whenever you’re ready.")
                            .font(.system(size: 12 * store.appearance.textScale)).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Enter an address  ⌘L", action: onRequestLocation).buttonStyle(.plain)
                            .font(.system(size: 12 * store.appearance.textScale, weight: .medium)).foregroundStyle(theme.accent)
                    }.padding(28).frame(maxWidth: 420)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "rectangle.slash").font(.system(size: 26))
                    Text("This Quick Browse page is no longer open.").font(.callout)
                }.foregroundStyle(.secondary).padding(24)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.isDark ? Color(red: 0.095, green: 0.09, blue: 0.12) : Color.white)
    }
}

/// Repeated focus requests select this window's field without remounting any web content.
@MainActor
struct QuickBrowseInput: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let size: CGFloat
    let ink: NSColor
    let focusRequest: Int
    var selectAll = false
    var resignFocus = false
    var onBeginEditing: () -> Void = {}
    var onEndEditing: () -> Void = {}
    let onSubmit: () -> Void
    let onCancel: () -> Void
    var onMove: (Int) -> Void = { _ in }
    var onTab: () -> Bool = { false }
    var onEmptyDelete: () -> Bool = { false }

    final class Field: NSTextField {
        var pendingFocus = false
        var selectAllWhenFocused = false
        override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 22) }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
            if let window {
                NotificationCenter.default.addObserver(self, selector: #selector(windowBecameKey),
                                                       name: NSWindow.didBecomeKeyNotification, object: window)
            }
            applyPendingFocus()
        }
        @objc private func windowBecameKey(_ notification: Notification) { applyPendingFocus() }
        func applyPendingFocus() {
            guard pendingFocus, isEnabled, window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.pendingFocus, self.isEnabled, let window = self.window, window.isKeyWindow else { return }
                self.pendingFocus = false
                window.makeFirstResponder(self)
                if self.selectAllWhenFocused { self.selectText(nil) }
            }
        }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: QuickBrowseInput
        var lastFocusRequest: Int
        init(_ parent: QuickBrowseInput) { self.parent = parent; lastFocusRequest = parent.focusRequest }
        func controlTextDidBeginEditing(_ notification: Notification) { parent.onBeginEditing() }
        func controlTextDidEndEditing(_ notification: Notification) { parent.onEndEditing() }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { parent.text = field.stringValue }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch NSStringFromSelector(selector) {
            case "insertNewline:": parent.onSubmit(); return true
            case "cancelOperation:":
                control.window?.makeFirstResponder(nil)
                parent.onCancel()
                return true
            case "moveUp:": parent.onMove(-1); return true
            case "moveDown:": parent.onMove(1); return true
            case "insertTab:":
                guard parent.onTab() else { return false }; sync(control, editor: textView); return true
            case "deleteBackward:":
                guard parent.text.isEmpty, parent.onEmptyDelete() else { return false }; sync(control, editor: textView); return true
            default: return false
            }
        }
        @MainActor private func sync(_ control: NSControl, editor: NSTextView) {
            (control as? NSTextField)?.stringValue = parent.text; editor.string = parent.text
            editor.setSelectedRange(NSRange(location: (parent.text as NSString).length, length: 0))
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> Field {
        let field = Field(string: text)
        field.isBordered = false; field.isBezeled = false; field.drawsBackground = false
        field.isEnabled = context.environment.isEnabled
        field.focusRingType = .none; field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingMiddle; field.delegate = context.coordinator
        field.font = .systemFont(ofSize: size); field.textColor = ink; field.placeholderString = placeholder
        field.setAccessibilityLabel(placeholder)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.selectAllWhenFocused = selectAll; field.pendingFocus = focusRequest > 0
        return field
    }
    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        field.isEnabled = context.environment.isEnabled
        field.font = .systemFont(ofSize: size); field.textColor = ink
        field.placeholderString = placeholder; field.setAccessibilityLabel(placeholder)
        if field.stringValue != text { field.stringValue = text }
        if resignFocus, field.currentEditor() != nil { field.window?.makeFirstResponder(nil) }
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            field.selectAllWhenFocused = selectAll; field.pendingFocus = true
        }
        field.applyPendingFocus()
    }
}
