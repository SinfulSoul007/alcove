import AppKit
import WebKit
import BrowserCore

enum ExtensionWindowKind:Hashable {case primary,quick(UUID)}
@MainActor final class ExtensionBrowserWindow {
    let id = UUID(),kind:ExtensionWindowKind
    weak var window:NSWindow?
    private var focusObservers:[NSObjectProtocol] = []
    init(_ window:NSWindow,kind:ExtensionWindowKind,changed:@escaping @MainActor ()->Void) {
        self.window = window;self.kind = kind
        for name in [NSWindow.didBecomeKeyNotification,NSWindow.didResignKeyNotification] {
            focusObservers.append(NotificationCenter.default.addObserver(forName:name,object:window,queue:.main){_ in MainActor.assumeIsolated{changed()}})
        }
    }
    deinit {for observer in focusObservers {NotificationCenter.default.removeObserver(observer)}}
}
extension BrowserStore {
    func registerExtensionWindow(_ window:NSWindow,kind:ExtensionWindowKind) {
        if extensionWindows[kind]?.window !== window {extensionWindows[kind] = ExtensionBrowserWindow(window,kind:kind){ [weak self] in self?.extensionBrowserStateChanged() }}
        ensureExtensionHost()?.refresh()
    }
    func unregisterExtensionWindow(kind:ExtensionWindowKind) {extensionWindows.removeValue(forKey:kind);extensionHosting?.refresh()}
    func extensionBrowserStateChanged() {extensionHosting?.browserStateChanged()}
}

struct NativeExtensionWindowKey:Hashable {let storeID:UUID,profileID:UUID,windowID:UUID}
@available(macOS 15.4,*) @MainActor final class NativeExtensionWindow:NSObject,WKWebExtensionWindow {
    let key:NativeExtensionWindowKey,reference:ExtensionBrowserWindow
    private let privateWindow:Bool
    weak var host:NativeBrowserExtensionHost?,store:BrowserStore?
    var tabKeys:[NativeExtensionTabKey] = [],activeKey:NativeExtensionTabKey?
    init(host:NativeBrowserExtensionHost,store:BrowserStore,profileID:UUID,reference:ExtensionBrowserWindow) {
        self.host = host;self.store = store;self.reference = reference
        privateWindow = store.isPrivate
        key = NativeExtensionWindowKey(storeID:store.extensionStoreID,profileID:profileID,windowID:reference.id)
    }
    func live(_ context:WKWebExtensionContext) -> (BrowserStore,NSWindow)? {
        guard let store, let window = reference.window, store.extensionWindows[reference.kind] === reference,
              host?.authorized(context,profileID:key.profileID,client:store) == true else {return nil}
        return (store,window)
    }
    var isFocusedInClient:Bool {
        guard let store,!store.isShuttingDown,store.extensionWindows[reference.kind] === reference,reference.window?.isKeyWindow == true else {return false}
        if reference.kind == .primary,!store.isPrivate {return store.activeProfileID == key.profileID}
        return true
    }
    func tabs(for context:WKWebExtensionContext) -> [any WKWebExtensionTab] {
        guard live(context) != nil, let host else {return []}
        return tabKeys.compactMap{host.nativeTabs[$0]}
    }
    func activeTab(for context:WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        guard live(context) != nil, let activeKey else {return nil};return host?.nativeTabs[activeKey]
    }
    // WebKit caches this classification before permission filtering and for the window's lifetime.
    func isPrivate(for context:WKWebExtensionContext) -> Bool {privateWindow}
    func windowType(for context:WKWebExtensionContext) -> WKWebExtension.WindowType {if case .quick = reference.kind {return .popup};return .normal}
    func windowState(for context:WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let (_,window) = live(context) else {return .normal}
        if window.isMiniaturized {return .minimized};if window.styleMask.contains(.fullScreen) {return .fullscreen}
        return window.isZoomed ? .maximized : .normal
    }
    func screenFrame(for context:WKWebExtensionContext) -> CGRect {live(context)?.1.screen?.frame ?? .null}
    func frame(for context:WKWebExtensionContext) -> CGRect {live(context)?.1.frame ?? .null}
    func setFrame(_ frame:CGRect,for context:WKWebExtensionContext,completionHandler:@escaping(Error?)->Void) {
        guard let (_,window) = live(context), [frame.origin.x,frame.origin.y,frame.width,frame.height].allSatisfy(\.isFinite), frame.width > 0,frame.height > 0 else {completionHandler(ExtensionHostError.stale);return}
        var bounded = frame
        bounded.size.width = max(window.minSize.width,bounded.width);bounded.size.height = max(window.minSize.height,bounded.height)
        if let screen = window.screen {bounded.size.width = min(bounded.width,screen.visibleFrame.width);bounded.size.height = min(bounded.height,screen.visibleFrame.height);bounded = window.constrainFrameRect(bounded,to:screen)}
        window.setFrame(bounded,display:true);completionHandler(nil)
    }
    func setWindowState(_ state:WKWebExtension.WindowState,for context:WKWebExtensionContext,completionHandler:@escaping(Error?)->Void) {
        guard let (_,window) = live(context) else {completionHandler(ExtensionHostError.stale);return}
        switch state {
        case .minimized:window.miniaturize(nil)
        case .maximized:if !window.isZoomed {window.zoom(nil)}
        case .fullscreen:if !window.styleMask.contains(.fullScreen) {window.toggleFullScreen(nil)}
        case .normal:
            if window.isMiniaturized {window.deminiaturize(nil)}
            if window.styleMask.contains(.fullScreen) {window.toggleFullScreen(nil)} else if window.isZoomed {window.zoom(nil)}
        @unknown default:completionHandler(ExtensionHostError.native("Unsupported window state."));return
        }
        completionHandler(nil)
    }
    func focus(for context:WKWebExtensionContext,completionHandler:@escaping(Error?)->Void) {
        guard let (store,window) = live(context) else {completionHandler(ExtensionHostError.stale);return}
        if case .primary = reference.kind, !store.isPrivate, store.activeProfileID != key.profileID,
           let space = store.session.spaces.first(where:{$0.effectiveProfileID == key.profileID}) {store.selectSpace(space.id)}
        if case .quick(let id) = reference.kind {store.focusedQuickPageID = id}
        if window.isMiniaturized {window.deminiaturize(nil)};window.makeKeyAndOrderFront(nil);completionHandler(nil)
    }
    func close(for context:WKWebExtensionContext,completionHandler:@escaping(Error?)->Void) {
        guard let (store,window) = live(context) else {completionHandler(ExtensionHostError.stale);return}
        if reference.kind == .primary,!store.isPrivate {
            let otherSpaces = store.session.spaces.contains{$0.effectiveProfileID != key.profileID}
            let otherPages = store.views.keys.contains{store.quickProfileID($0) == nil && store.viewProfileIDs[$0] != key.profileID}
            guard !otherSpaces && !otherPages else {
                completionHandler(ExtensionHostError.native("The main window contains other profiles. Close this account's tabs individually."));return
            }
        }
        window.performClose(nil)
        completionHandler(store.extensionWindows[reference.kind] === reference ? ExtensionHostError.native("The window could not close.") : nil)
    }
}
