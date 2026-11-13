import AppKit
import WebKit
import BrowserCore

/// Both the native context and actual document/window must still be the reviewed source.
@available(macOS 15.4,*) @MainActor final class NativeExtensionSource {
    weak var host:NativeBrowserExtensionHost?,context:WKWebExtensionContext?,controller:WKWebExtensionController?
    weak var tab:NativeExtensionTab?,client:BrowserStore?,web:WKWebView?,window:NSWindow?
    let key:NativeExtensionTabKey,windowID:UUID,document:NSUUID?,record:BrowserExtensionRecord,epoch:UUID
    private let requiresMountedView:Bool,destination:String?
    private var closed = false,closing:NSObjectProtocol?
    init?(host:NativeBrowserExtensionHost,controller:WKWebExtensionController,context:WKWebExtensionContext,tab:NativeExtensionTab,requiresMountedView:Bool = true) {
        guard let client = tab.live(context),let owner = host.owner,
              let browserWindow = tab.browserWindow,let (_,window) = browserWindow.live(context),
              host.nativeTabs[tab.key] === tab,host.profiles[tab.key.profileID]?.controller === controller,
              let id = host.profiles[tab.key.profileID]?.contexts.first(where:{$0.value === context})?.key,
              let record = owner.extensionRecords(profileID:tab.key.profileID).first(where:{$0.id == id}) else {return nil}
        let web = tab.web
        if let web {
            guard (!requiresMountedView || web.window === window),web.configuration.webExtensionController === controller,
                  client.matchesBoostWebsiteDataStore(web,profileID:client.isPrivate ? BrowserProfile.defaultID : tab.key.profileID) else {return nil}
        } else if requiresMountedView || tab.key.isPeek || client.tab(tab.key.id) == nil {return nil}
        self.host = host;self.context = context;self.controller = controller;self.tab = tab
        self.client = client;self.web = web;self.window = window;self.record = record
        key = tab.key;windowID = browserWindow.key.windowID;document = web.map{client.documentIdentity(for:$0)}
        self.requiresMountedView = requiresMountedView;destination = client.tab(tab.key.id)?.url
        epoch = owner.extensionReviewEpoch(for:key.profileID)
        closing = NotificationCenter.default.addObserver(forName:NSWindow.willCloseNotification,object:window,queue:.main){ [weak self] _ in
            MainActor.assumeIsolated {self?.closed = true;self?.host?.reconcileExtensionSourceRequests()}
        }
    }
    deinit {if let closing {NotificationCenter.default.removeObserver(closing)}}
    var current:Bool {
        guard !closed,let host,let owner = host.owner,let client,let context,let controller,let tab,let window,
              tab.key == key,host.nativeTabs[key] === tab,tab.web === web,tab.live(context) === client,
              tab.browserWindow?.key.windowID == windowID,tab.browserWindow?.live(context)?.1 === window,
              host.profiles[key.profileID]?.controller === controller,
              owner.extensionReviewEpoch(for:key.profileID) == epoch,
              owner.extensionRecords(profileID:key.profileID).first(where:{$0.id == record.id}) == record else {return false}
        if let document {
            guard let web,client.documentIdentity(for:web) === document,(!requiresMountedView || web.window === window) else {return false}
        } else if web != nil || requiresMountedView {return false}
        return requiresMountedView || client.tab(key.id)?.url == destination
    }
}
