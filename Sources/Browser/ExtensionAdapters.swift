import AppKit
import WebKit
import BrowserCore

@available(macOS 15.4,*) @MainActor extension NativeBrowserExtensionHost {
    func authorized(_ context:WKWebExtensionContext,profileID:UUID,client:BrowserStore) -> Bool {
        guard client === owner,!client.isShuttingDown,!client.profileUnavailable(profileID),let runtime = profiles[profileID],
              runtime.controllerID == client.profiles.first(where:{$0.id == profileID})?.extensionControllerID,
              runtime.epoch == client.extensionReviewEpoch(for:profileID),let entry = runtime.contexts.first(where:{$0.value === context}),
              let record = client.extensionRecords(profileID:profileID).first(where:{$0.id == entry.key}),record.enabled,record.pendingRemoval != true,record.grants != nil else {return false}
        return true
    }
    func profileID(for context:WKWebExtensionContext) -> UUID? {profiles.first(where:{$0.value.contexts.values.contains(where:{$0 === context})})?.key}
    func permitsNavigation(_ url:URL?,context:WKWebExtensionContext,profileID:UUID) -> Bool {
        guard let owner,authorized(context,profileID:profileID,client:owner) else {return false}
        guard let url else {return true}
        if ["http","https"].contains(url.scheme?.lowercased() ?? "") || url.absoluteString == "about:blank" {return true}
        return url.scheme?.lowercased() == "webkit-extension" && url.host == context.baseURL.host && profiles[profileID]?.controller.extensionContext(for:url) === context
    }
    func optionsURL(_ id:UUID,profileID:UUID) -> URL? {profiles[profileID]?.contexts[id]?.optionsPageURL}
    func allowsExtensionURL(_ url:URL,profileID:UUID) -> Bool {
        guard url.scheme?.lowercased() == "webkit-extension",url.user == nil,url.password == nil,url.port == nil,
              (try? ExtensionResourcePath.normalized(String(url.path.dropFirst()))) != nil,
              let owner,let context = profiles[profileID]?.controller.extensionContext(for:url) else {return false}
        return authorized(context,profileID:profileID,client:owner)
    }
    func configuration(for url:URL,profileID:UUID) -> WKWebViewConfiguration? {
        guard allowsExtensionURL(url,profileID:profileID) else {return nil}
        return profiles[profileID]?.controller.extensionContext(for:url)?.webViewConfiguration
    }
    func browserStateChanged() {
        guard synchronization == nil else {return}
        synchronization = Task { @MainActor [weak self] in
            guard let self else {return};self.synchronization = nil;self.synchronizeBrowserState()
        }
    }
    func synchronizeBrowserState() {
        guard let owner,!owner.isShuttingDown else {return}
        let locations = Dictionary(uniqueKeysWithValues:nativeTabs.values.map{(ObjectIdentifier($0),($0.browserWindow,$0.browserWindow?.tabKeys.firstIndex(of:$0.key) ?? 0))})
        var wantedWindows = Set<NativeExtensionWindowKey>(),wantedTabs = Set<NativeExtensionTabKey>()
        for (profileID,runtime) in profiles where !owner.profileUnavailable(profileID) {
            for reference in owner.extensionWindows.values where reference.window != nil {
                let windowKey = NativeExtensionWindowKey(storeID:owner.extensionStoreID,profileID:profileID,windowID:reference.id)
                let window = nativeWindows[windowKey] ?? NativeExtensionWindow(host:self,store:owner,profileID:profileID,reference:reference)
                let newWindow = nativeWindows[windowKey] == nil
                nativeWindows[windowKey] = window;wantedWindows.insert(windowKey)
                let oldActive = window.activeKey.flatMap{nativeTabs[$0]}
                window.tabKeys = []
                var pages:[(UUID,Bool,WKWebView?,NativeExtensionTabState)] = []
                func append(_ id:UUID,_ isPeek:Bool,_ web:WKWebView?,_ title:String,_ url:String,_ pinned:Bool) {
                    pages.append((id,isPeek,web,NativeExtensionTabState(title:web?.title ?? title,url:web?.url ?? URL(string:url),pinned:pinned,loading:web?.isLoading ?? false,zoom:Double(web?.pageZoom ?? 1),size:web?.bounds.size ?? .zero)))
                }
                switch reference.kind {
                case .primary:
                    var seen = Set<UUID>()
                    for tab in owner.session.spaces.filter({$0.effectiveProfileID == profileID}).flatMap(\.tabs) + owner.favorites(for:profileID) where seen.insert(tab.id).inserted {
                        append(tab.id,false,owner.views[tab.id],tab.title,tab.url,tab.pinned)
                    }
                    if let peek = owner.peekPages[.primary],peek.profileID == profileID {append(peek.id,true,peek.web,peek.web.title ?? "Peek",peek.web.url?.absoluteString ?? peek.requestedURL?.absoluteString ?? "",false)}
                case .quick(let id):
                    if owner.quickProfileID(id) == profileID,let page = owner.quickPage(id) {append(id,false,owner.views[id],page.tab.title,page.tab.url,false)}
                    if let peek = owner.peekPages[.quick(id)],peek.profileID == profileID {append(peek.id,true,peek.web,peek.web.title ?? "Peek",peek.web.url?.absoluteString ?? peek.requestedURL?.absoluteString ?? "",false)}
                }
                var tabKeys:[NativeExtensionTabKey] = []
                if newWindow {runtime.controller.didOpenWindow(window)}
                for (index,page) in pages.enumerated() {
                    let key = NativeExtensionTabKey(storeID:owner.extensionStoreID,profileID:profileID,id:page.0,isPeek:page.1)
                    let inherited = page.2.flatMap {tabsByView[ObjectIdentifier($0)]}.flatMap {$0.key.profileID == profileID && $0.key.storeID == owner.extensionStoreID && $0.web === page.2 ? $0 : nil}
                    let tab = nativeTabs[key] ?? inherited ?? NativeExtensionTab(host:self,store:owner,key:key,state:page.3,web:page.2)
                    let existed = nativeTabs[key] != nil || inherited != nil
                    let oldWindow = locations[ObjectIdentifier(tab)]?.0,oldIndex = locations[ObjectIdentifier(tab)]?.1 ?? 0,oldState = tab.state
                    if tab.key != key {nativeTabs.removeValue(forKey:tab.key)}
                    if let previous = tab.web,previous !== page.2 {tabsByView.removeValue(forKey:ObjectIdentifier(previous))}
                    tab.key = key;tab.state = page.3;tab.web = page.2;tab.browserWindow = window
                    nativeTabs[key] = tab;if let web = page.2 {tabsByView[ObjectIdentifier(web)] = tab}
                    tabKeys.append(key);wantedTabs.insert(key)
                    window.tabKeys = tabKeys
                    if !existed {runtime.controller.didOpenTab(tab)}
                    else if oldWindow !== window || oldIndex != index {runtime.controller.didMoveTab(tab,from:oldIndex,in:oldWindow)}
                    var changed:WKWebExtension.TabChangedProperties = []
                    if oldState.title != page.3.title {changed.insert(.title)};if oldState.url != page.3.url {changed.insert(.URL)}
                    if oldState.loading != page.3.loading {changed.insert(.loading)};if oldState.pinned != page.3.pinned {changed.insert(.pinned)}
                    if oldState.zoom != page.3.zoom {changed.insert(.zoomFactor)};if oldState.size != page.3.size {changed.insert(.size)}
                    if !changed.isEmpty {runtime.controller.didChangeTabProperties(changed,for:tab)}
                }
                window.tabKeys = tabKeys
                let peekID:UUID?,selected:UUID?
                switch reference.kind {
                case .primary:peekID = owner.peekPages[.primary]?.id;selected = owner.activeProfileID == profileID ? owner.focusedID : owner.session.spaces.first(where:{$0.effectiveProfileID == profileID})?.selected
                case .quick(let id):peekID = owner.peekPages[.quick(id)]?.id;selected = id
                }
                window.activeKey = tabKeys.first(where:{$0.isPeek && $0.id == peekID}) ?? tabKeys.first(where:{$0.id == selected}) ?? tabKeys.first
                if let activated = window.activeKey.flatMap({nativeTabs[$0]}),activated !== oldActive {runtime.controller.didActivateTab(activated,previousActiveTab:oldActive)}
            }
        }
        for (key,tab) in nativeTabs where !wantedTabs.contains(key) {
            profiles[key.profileID]?.controller.didCloseTab(tab,windowIsClosing:tab.browserWindow.map{!wantedWindows.contains($0.key)} ?? true)
            if let web = tab.web {tabsByView.removeValue(forKey:ObjectIdentifier(web))};nativeTabs.removeValue(forKey:key)
        }
        for (key,window) in nativeWindows where !wantedWindows.contains(key) {profiles[key.profileID]?.controller.didCloseWindow(window);nativeWindows.removeValue(forKey:key)}
        tabsByView = tabsByView.filter {key,tab in tab.web.map{ObjectIdentifier($0)} == key && nativeTabs[tab.key] === tab}
    }
    func webExtensionController(_ controller:WKWebExtensionController,openWindowsFor context:WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        guard let id = profileID(for:context),let owner,authorized(context,profileID:id,client:owner),profiles[id]?.controller === controller else {return []}
        return nativeWindows.values.filter{$0.key.profileID == id && $0.live(context) != nil}
    }
    func webExtensionController(_ controller:WKWebExtensionController,focusedWindowFor context:WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        webExtensionController(controller,openWindowsFor:context).first {($0 as? NativeExtensionWindow)?.reference.window?.isKeyWindow == true}
    }
    func webExtensionController(_ controller:WKWebExtensionController,openNewWindowUsing configuration:WKWebExtension.WindowConfiguration,for context:WKWebExtensionContext,completionHandler:@escaping((any WKWebExtensionWindow)?,Error?)->Void) {
        completionHandler(nil,ExtensionHostError.native("Creating additional normal windows through extensions is not available yet."))
    }
    func webExtensionController(_ controller:WKWebExtensionController,openNewTabUsing configuration:WKWebExtension.TabConfiguration,for context:WKWebExtensionContext,completionHandler:@escaping((any WKWebExtensionTab)?,Error?)->Void) {
        guard let id = profileID(for:context),let owner,authorized(context,profileID:id,client:owner),profiles[id]?.controller === controller,permitsNavigation(configuration.url,context:context,profileID:id) else {completionHandler(nil,ExtensionHostError.stale);return}
        let target = (configuration.window as? NativeExtensionWindow) ?? nativeWindows.values.first(where:{$0.key.profileID == id && $0.reference.kind == .primary})
        guard let target,target.key.profileID == id,target.live(context) != nil,target.reference.kind == .primary,
              !configuration.shouldBeMuted,!configuration.shouldReaderModeBeActive else {completionHandler(nil,ExtensionHostError.native("This tab configuration is unavailable in the target browser window."));return}
        do {let tabID = try owner.createExtensionTab(url:configuration.url,profileID:id,activate:configuration.shouldBeActive,pinned:configuration.shouldBePinned,index:configuration.index);synchronizeBrowserState();completionHandler(nativeTabs[NativeExtensionTabKey(storeID:owner.extensionStoreID,profileID:id,id:tabID,isPeek:false)],nil)} catch {completionHandler(nil,error)}
    }
    func webExtensionController(_ controller:WKWebExtensionController,openOptionsPageFor context:WKWebExtensionContext,completionHandler:@escaping(Error?)->Void) {
        guard let profile = profileID(for:context),let owner,authorized(context,profileID:profile,client:owner),let record = profiles[profile]?.contexts.first(where:{$0.value === context})?.key else {completionHandler(ExtensionHostError.stale);return}
        Task { @MainActor [weak owner] in
            guard let owner else {completionHandler(ExtensionHostError.closed);return}
            do {_ = try await owner.openExtensionOptions(record,profileID:profile);completionHandler(nil)} catch {completionHandler(error)}
        }
    }
}
