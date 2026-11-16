import AppKit
import WebKit
import BrowserCore

extension BrowserStore {
    var extensionPopupTabs: [BrowserCore.Tab] {
        guard let profileID = extensionPopupProfileID, let windowGroup else { return [] }
        return session.spaces.filter { $0.effectiveProfileID == profileID }.flatMap(\.tabs).filter {
            windowGroup.presentation(tabID: $0.id, in: self) == .owned
        }
    }

    func selectExtensionPopupTab(_ id: UUID) {
        guard extensionPopupTabs.contains(where: { $0.id == id }),
              let targetSpace = session.spaces.first(where: { $0.tabs.contains { $0.id == id } }) else { return }
        if targetSpace.id != space.id { selectSpace(targetSpace.id) }
        select(id)
    }

    func closeExtensionPopupTabs() throws {
        let tabs = extensionPopupTabs.filter { !$0.pinned }
        guard !tabs.isEmpty else { return }
        var document = makeDocument()
        for tab in tabs {
            if let space = document.session.spaces.first(where: { $0.tabs.contains { $0.id == tab.id } }) {
                document.session.close(tab.id, in: space.id)
            }
        }
        try commitQuickDocument(document, discarding: tabs.map(\.id))
    }

    func restoreSavedExtensionTab(_ id:UUID,url:URL,placeholder:WKWebView,profileID:UUID) {
        guard ensureExtensionHost() != nil else {
            extensionStates[profileID] = .failed(ExtensionHostError.unavailable.localizedDescription)
            message = ExtensionHostError.unavailable.localizedDescription;return
        }
        decideExtensionNavigation(placeholder,url:url,isMainFrame:true,allow:.allow) { [weak self,weak placeholder] policy in
            guard policy == .allow,let self,let placeholder,self.views[id] === placeholder,self.profileID(for:placeholder) == profileID else {return}
            do {try self.navigateExtensionTab(id,to:url,profileID:profileID)} catch {self.message = error.localizedDescription}
        }
    }
    /// Extension and ordinary documents require different public WebKit configurations.
    /// The user-requested navigation replaces that document while keeping its model/tab ID.
    func navigateExtensionTab(_ id:UUID,to url:URL,profileID:UUID,request:URLRequest?=nil) throws {
        try requireQuickProfile(profileID)
        guard self.profileID(for:id) == profileID else {throw ExtensionHostError.stale}
        let existing = views[id],previous = existing?.url ?? tab(id).flatMap{URL(string:$0.url)}
        if let existing,extensionOriginPopups.contains(existing),["http","https"].contains(url.scheme?.lowercased() ?? "") {throw ExtensionHostError.unsupportedWebsitePopup}
        if let existing,extensionOriginPopups.contains(existing),url.absoluteString == "about:blank" {
            update(id){$0.url = url.absoluteString};existing.load(request ?? URLRequest(url:url));return
        }
        let wasExtension = previous?.scheme?.lowercased() == "webkit-extension",isExtension = url.scheme?.lowercased() == "webkit-extension"
        let replace = wasExtension != isExtension || (isExtension && (previous?.host != url.host || existing?.url?.scheme?.lowercased() != "webkit-extension"))
        let configuration:WKWebViewConfiguration?
        if isExtension {
            guard let value = extensionHosting?.configuration(for:url,profileID:profileID) else {throw isPrivate ? ExtensionHostError.unsupportedPrivatePage : ExtensionHostError.stale};configuration = value
        } else {configuration = nil}
        update(id){$0.url = url.absoluteString}
        guard let existing else {_ = view(for:id,configuration:configuration);return}
        guard replace else {existing.load(request ?? URLRequest(url:url));return}
        let destination = configuration ?? WKWebViewConfiguration()
        destination.websiteDataStore = websiteDataStore(forProfile:profileID)
        destination.preferences.javaScriptCanOpenWindowsAutomatically = false
        configureExtensions(destination,profileID:profileID)
        let replacement = WKWebView(frame:existing.frame,configuration:destination)
        registerView(replacement,for:id,profile:profileID)
        replacement.load(request ?? URLRequest(url:url));revision += 1;extensionHosting?.refresh()
    }
    private func extensionTabDocument(_ id:UUID,profileID:UUID) throws -> (BrowserDocument,Int,Int) {
        try requireQuickProfile(profileID)
        guard self.profileID(for:id)==profileID,quickPage(id)==nil,let value=tab(id) else {throw ExtensionHostError.stale}
        var document=makeDocument()
        if let owner=document.session.spaces.firstIndex(where:{$0.tabs.contains(where:{$0.id==id})}) {
            guard isPrivate || document.session.spaces[owner].effectiveProfileID==profileID,
                  let index=document.session.spaces[owner].tabs.firstIndex(where:{$0.id==id}) else {throw ExtensionHostError.stale}
            return (document,owner,index)
        }
        guard value.favorite==true,
              let owner=document.session.spaces.firstIndex(where:{$0.id==document.session.selectedSpace && (isPrivate || $0.effectiveProfileID==profileID)}) ?? document.session.spaces.firstIndex(where:{isPrivate || $0.effectiveProfileID==profileID}) else {throw ExtensionHostError.native("Open a Space in this profile before changing this Favorite.")}
        document.session.spaces[owner].tabs.append(value)
        return (document,owner,document.session.spaces[owner].tabs.count-1)
    }
    func setExtensionTabPinned(_ id:UUID,profileID:UUID,pinned:Bool) throws {
        guard tab(id)?.pinned != pinned else {return}
        var (document,owner,index)=try extensionTabDocument(id,profileID:profileID)
        var value=document.session.spaces[owner].tabs[index]
        value.pinned=pinned
        if pinned {value.homeURL=value.url;value.pinnedTitle=value.title}
        else {value.favorite=nil;value.folder=nil;value.homeURL=nil;value.pinnedTitle=nil}
        document.session.spaces[owner].tabs[index]=value
        var library=document.library(for:profileID)
        if value.favorite != true {library.favoriteTabs?.removeAll{$0.id==id}}
        document.setLibrary(library,for:profileID)
        try commitQuickDocument(document)
    }
    func activateExtensionTab(_ id:UUID,profileID:UUID) throws {
        var (document,owner,_)=try extensionTabDocument(id,profileID:profileID)
        if splitLayout?.tabIDs.contains(id) == true, space.id == document.session.spaces[owner].id,
           (windowGroup?.presentation(tabID: id, in: self) ?? .owned) == .owned {
            dismissCommand(); closePrimaryPeek(); focusPane(id)
            return
        }
        document.session.activateSpace(document.session.spaces[owner].id)
        document.session.spaces[owner].selected=id
        try commitQuickDocument(document)
        dismissCommand();closePrimaryPeek();clearSplit()
    }
    @discardableResult func openExtensionOptions(_ id:UUID,profileID:UUID) async throws -> UUID {
        try await prepareExtensions(profileID:profileID)
        try Task.checkCancellation()
        guard let host = extensionHosting, let url = host.optionsURL(id,profileID:profileID) else {throw ExtensionHostError.native("This extension has no available options page.")}
        if isPrivate {throw ExtensionHostError.unsupportedPrivatePage}
        if extensionWindows[.primary]?.window == nil {extensionPrimaryWindowRequested?()}
        let target = extensionWindows[.primary]?.window != nil ? self : (windowGroup?.focusedPrimary ?? self)
        return try target.createExtensionTab(url:url,profileID:profileID,activate:true)
    }
    @discardableResult func createExtensionTab(url:URL?,profileID:UUID,activate:Bool,pinned:Bool = false,index:Int? = nil) throws -> UUID {
        try requireQuickProfile(profileID)
        guard extensionWindows[.primary]?.window != nil else {throw ExtensionHostError.native("Open the main browser window before creating a tab.")}
        let configuration:WKWebViewConfiguration?
        if let url, url.scheme?.lowercased() == "webkit-extension" {
            guard let value = extensionHosting?.configuration(for:url,profileID:profileID) else {throw isPrivate ? ExtensionHostError.unsupportedPrivatePage : ExtensionHostError.stale};configuration = value
        } else {
            guard url == nil || ["http","https"].contains(url!.scheme?.lowercased() ?? "") || url?.absoluteString == "about:blank" else {throw QuickBrowseError.invalidAddress}
            configuration = nil
        }
        let currentProfileID = isPrivate ? BrowserProfile.defaultID : space.effectiveProfileID
        let target = currentProfileID == profileID ? space.id : session.spaces.first(where:{$0.effectiveProfileID == profileID})?.id
        guard let target, let spaceIndex = session.spaces.firstIndex(where:{$0.id == target}) else {throw ProfileError.missing}
        var tab = BrowserCore.Tab(title:url?.host ?? "New Tab",url:url?.absoluteString ?? "");tab.pinned = pinned
        if pinned {tab.homeURL = tab.url;tab.pinnedTitle = tab.title}
        var candidate = makeDocument()
        let insertion = min(max(0,index ?? candidate.session.spaces[spaceIndex].tabs.count),candidate.session.spaces[spaceIndex].tabs.count)
        candidate.session.spaces[spaceIndex].tabs.insert(tab,at:insertion)
        if activate {candidate.session.spaces[spaceIndex].selected = tab.id;candidate.session.activateSpace(target)}
        try commitQuickDocument(candidate)
        _ = view(for:tab.id,configuration:configuration);revision += 1;extensionHosting?.refresh()
        return tab.id
    }

    func prepareExtensionWindowTabs(profileID: UUID, URLs: [URL], moving tabIDs: [UUID]) throws {
        try requireQuickProfile(profileID)
        guard let group = windowGroup, group.containsPrimary(self),
              tabIDs.allSatisfy({ group.canClaimPresentation(tabID: $0, in: self) }) else { throw ExtensionHostError.stale }
        var document = makeDocument()
        let spaceIndex: Int?
        if let first = tabIDs.first {
            spaceIndex = document.session.spaces.firstIndex { space in
                space.effectiveProfileID == profileID && space.tabs.contains { $0.id == first }
            }
        } else if space.effectiveProfileID == profileID {
            spaceIndex = self.spaceIndex
        } else {
            spaceIndex = document.session.spaces.firstIndex { $0.effectiveProfileID == profileID }
        }
        guard let spaceIndex else { throw ProfileError.missing }
        var tabs = URLs.map { BrowserCore.Tab(title: $0.host ?? "New Tab", url: $0.absoluteString) }
        if tabs.isEmpty && tabIDs.isEmpty { tabs = [BrowserCore.Tab()] }
        document.session.spaces[spaceIndex].tabs.append(contentsOf: tabs)
        document.session.spaces[spaceIndex].selected = tabIDs.first ?? tabs.first?.id
        document.session.activateSpace(document.session.spaces[spaceIndex].id)
        try commitProfileDocument(document)
        for tabID in tabIDs { group.claimPresentation(tabID: tabID, in: self, allowPopupTransfer: true) }
    }
}

struct NativeExtensionTabKey:Hashable {let storeID:UUID,profileID:UUID,id:UUID,isPeek:Bool}
struct NativeExtensionTabState:Equatable {
    var title:String,url:URL?,pinned:Bool,loading:Bool,zoom:Double,size:CGSize
}
@available(macOS 15.4,*) @MainActor final class NativeExtensionTab:NSObject,WKWebExtensionTab {
    var key:NativeExtensionTabKey,state:NativeExtensionTabState
    weak var host:NativeBrowserExtensionHost?,store:BrowserStore?,web:WKWebView?,browserWindow:NativeExtensionWindow?
    init(host:NativeBrowserExtensionHost,store:BrowserStore,key:NativeExtensionTabKey,state:NativeExtensionTabState,web:WKWebView?) {
        self.host = host;self.store = store;self.key = key;self.state = state;self.web = web
    }
    func live(_ context:WKWebExtensionContext) -> BrowserStore? {
        guard let store,host?.authorized(context,profileID:key.profileID,client:store) == true else {return nil}
        if key.isPeek {guard store.peekPages.values.contains(where:{$0.id == key.id && $0.web === web}) else {return nil}}
        else {
            guard store.profileID(for:key.id) == (store.isPrivate ? BrowserProfile.defaultID : key.profileID) else {return nil}
            if let group = store.windowGroup, store.quickPage(key.id) == nil, group.extensionPresenter(for: key.id) !== store { return nil }
        }
        return store
    }
    func actualView(_ context:WKWebExtensionContext) throws -> WKWebView {
        guard let store = live(context) else {throw ExtensionHostError.stale}
        if key.isPeek {guard let web else {throw ExtensionHostError.stale};return web}
        let view = store.view(for:key.id);web = view;return view
    }
    func webView(for context:WKWebExtensionContext) -> WKWebView? {live(context) == nil ? nil : web}
    func window(for context:WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        // Supply structural ownership even before private approval so the engine can cache
        // the true private flag. Data and actions still require live(context) authorization.
        if let store,store.isPrivate,let host,let owner = host.owner,
           host.authorized(context,profileID:key.profileID,client:owner),host.isAssociated(store,profileID:key.profileID),
           let browserWindow,store.extensionWindows[browserWindow.reference.kind] === browserWindow.reference,browserWindow.reference.window != nil {return browserWindow}
        return live(context) == nil ? nil : browserWindow
    }
    func indexInWindow(for context:WKWebExtensionContext) -> Int {guard live(context) != nil else {return NSNotFound};return browserWindow?.tabKeys.firstIndex(of:key) ?? NSNotFound}
    func title(for context:WKWebExtensionContext) -> String? {live(context) == nil ? nil : state.title}
    func url(for context:WKWebExtensionContext) -> URL? {live(context) == nil ? nil : state.url}
    func isPinned(for context:WKWebExtensionContext) -> Bool {live(context) != nil && state.pinned}
    func isLoadingComplete(for context:WKWebExtensionContext) -> Bool {live(context) != nil && !state.loading}
    func size(for context:WKWebExtensionContext) -> CGSize {live(context) == nil ? .zero : state.size}
    func zoomFactor(for context:WKWebExtensionContext) -> Double {live(context) == nil ? 1 : Double(web?.pageZoom ?? CGFloat(state.zoom))}
    func isSelected(for context:WKWebExtensionContext) -> Bool {live(context) != nil && browserWindow?.activeKey == key}
    func shouldGrantPermissionsOnUserGesture(for context:WKWebExtensionContext) -> Bool {
        guard live(context) != nil,let host else {return false}
        return host.hasApprovedPermission(WKWebExtension.Permission(rawValue:"activeTab"),context:context,profileID:key.profileID)
    }
    func shouldBypassPermissions(for context:WKWebExtensionContext) -> Bool {false}
    func setPinned(_ pinned:Bool,for context:WKWebExtensionContext,completionHandler:@escaping(Error?)->Void) {
        guard let store = live(context),!key.isPeek,store.quickPage(key.id) == nil else {completionHandler(ExtensionHostError.stale);return}
        do {try store.setExtensionTabPinned(key.id,profileID:store.isPrivate ? BrowserProfile.defaultID : key.profileID,pinned:pinned);host?.synchronizeBrowserState();completionHandler(nil)} catch {completionHandler(error)}
    }
    func setZoomFactor(_ value:Double,for context:WKWebExtensionContext,completionHandler:@escaping(Error?)->Void) {
        let zoom = value == 0 ? 1 : value
        guard zoom.isFinite,(0.5...3).contains(zoom) else {completionHandler(ExtensionHostError.native("Zoom must be between 0.5 and 3, or 0 to reset."));return}
        do {try actualView(context).pageZoom = CGFloat(zoom);host?.synchronizeBrowserState();completionHandler(nil)} catch {completionHandler(error)}
    }
    func loadURL(_ url:URL,for context:WKWebExtensionContext,completionHandler:@escaping(Error?)->Void) {
        guard let store = live(context),host?.permitsNavigation(url,context:context,profileID:key.profileID) == true else {completionHandler(ExtensionHostError.stale);return}
        do {
            if !key.isPeek {try store.navigateExtensionTab(key.id,to:url,profileID:store.isPrivate ? BrowserProfile.defaultID : key.profileID)}
            else {try store.navigateExtensionSurface(actualView(context),to:url,profileID:store.isPrivate ? BrowserProfile.defaultID : key.profileID)}
            completionHandler(nil)
        } catch {completionHandler(error)}
    }
    func reload(fromOrigin:Bool,for context:WKWebExtensionContext,completionHandler:@escaping(Error?)->Void) {
        do {let view = try actualView(context);if fromOrigin {view.reloadFromOrigin()} else {view.reload()};completionHandler(nil)} catch {completionHandler(error)}
    }
    func goBack(for context:WKWebExtensionContext,completionHandler:@escaping(Error?)->Void) {
        do {let view = try actualView(context);guard view.canGoBack else {throw ExtensionHostError.native("No previous page.")};view.goBack();completionHandler(nil)} catch {completionHandler(error)}
    }
    func goForward(for context:WKWebExtensionContext,completionHandler:@escaping(Error?)->Void) {
        do {let view = try actualView(context);guard view.canGoForward else {throw ExtensionHostError.native("No next page.")};view.goForward();completionHandler(nil)} catch {completionHandler(error)}
    }
    func activate(for context:WKWebExtensionContext,completionHandler:@escaping(Error?)->Void) {
        guard let store = live(context),let window = browserWindow else {completionHandler(ExtensionHostError.stale);return}
        if !key.isPeek {
            if store.quickPage(key.id) != nil {store.focusedQuickPageID = key.id;store.quickPageRequested?(key.id)}
            else {
                do {try store.activateExtensionTab(key.id,profileID:store.isPrivate ? BrowserProfile.defaultID : key.profileID)}
                catch {completionHandler(error);return}
            }
        }
        host?.synchronizeBrowserState();window.focus(for:context,completionHandler:completionHandler)
    }
    func setSelected(_ selected:Bool,for context:WKWebExtensionContext,completionHandler:@escaping(Error?)->Void) {
        if selected {activate(for:context,completionHandler:completionHandler)}
        else {completionHandler(isSelected(for:context) ? ExtensionHostError.native("The active page cannot be deselected without selecting another tab.") : nil)}
    }
    func close(for context:WKWebExtensionContext,completionHandler:@escaping(Error?)->Void) {
        guard let store = live(context) else {completionHandler(ExtensionHostError.stale);return}
        do {
            if key.isPeek {guard let peek = store.peekPages.first(where:{$0.value.id == key.id})?.key else {throw ExtensionHostError.stale};store.closePeek(in:peek)}
            else if store.quickPage(key.id) != nil {try store.closeQuickPage(key.id)}
            else {if state.pinned {store.togglePin(key.id)};store.close(key.id)}
            host?.synchronizeBrowserState();completionHandler(nil)
        } catch {completionHandler(error)}
    }
    func duplicate(using configuration:WKWebExtension.TabConfiguration,for context:WKWebExtensionContext,completionHandler:@escaping((any WKWebExtensionTab)?,Error?)->Void) {
        guard let store = live(context),let host,host.permitsNavigation(state.url,context:context,profileID:key.profileID) else {completionHandler(nil,ExtensionHostError.stale);return}
        let requested:(any WKWebExtensionWindow)?=configuration.window ?? browserWindow
        guard let target=requested as? NativeExtensionWindow,target.store === store,target.key.profileID==key.profileID,target.live(context) != nil,
              target.reference.kind == .primary,!configuration.shouldBeMuted,!configuration.shouldReaderModeBeActive else {completionHandler(nil,ExtensionHostError.native("This duplicate destination or tab configuration is unavailable."));return}
        do {let id = try store.createExtensionTab(url:state.url,profileID:store.isPrivate ? BrowserProfile.defaultID : key.profileID,activate:configuration.shouldBeActive,pinned:configuration.shouldBePinned,index:configuration.index);host.synchronizeBrowserState();completionHandler(host.nativeTabs[NativeExtensionTabKey(storeID:store.extensionStoreID,profileID:key.profileID,id:id,isPeek:false)],nil)} catch {completionHandler(nil,error)}
    }
}
