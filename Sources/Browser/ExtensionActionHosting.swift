import AppKit
import WebKit
import BrowserCore

struct BrowserExtensionActionSummary:Identifiable {
    let id:UUID,label:String,badge:String,isEnabled:Bool,presentsPopup:Bool,icon:NSImage?
}
extension BrowserStore {
    func extensionActionSummaries(for web:WKWebView) -> [BrowserExtensionActionSummary] {
        guard let profile = profileID(for:web),!profileUnavailable(profile) else {return []}
        return extensionHosting?.actionSummaries(for:web,profileID:profile) ?? []
    }
    func performExtensionAction(_ id:UUID,from web:WKWebView,anchor:NSView) throws {
        guard !isShuttingDown,let profile = profileID(for:web),!profileUnavailable(profile),let host = ensureExtensionHost() else {throw ExtensionHostError.stale}
        try host.performAction(id,from:web,profileID:profile,anchor:anchor)
    }
}

@available(macOS 15.4,*) @MainActor struct NativeExtensionActionPresenter {
    var present:(WKWebExtension.Action,NSView)throws->Void
    static var live:Self {
        Self(present:{action,anchor in
            guard let popover = action.popupPopover,let window = anchor.window,window.isVisible else {throw ExtensionHostError.stale}
            popover.behavior = .transient
            popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            popover.show(relativeTo:anchor.bounds,of:anchor,preferredEdge:.minY)
            guard popover.isShown else {throw ExtensionHostError.native("The extension popup could not be shown in its source window.")}
        })
    }
}

@available(macOS 15.4,*) @MainActor final class NativeExtensionActionJob {
    let id = UUID(),source:NativeExtensionSource,action:WKWebExtension.Action
    weak var anchor:NSView?
    private(set) var presented = false
    private var timeout:Task<Void,Never>?,closing:NSObjectProtocol?
    init(source:NativeExtensionSource,action:WKWebExtension.Action,anchor:NSView) {self.source = source;self.action = action;self.anchor = anchor}
    var current:Bool {source.current && anchor?.window === source.window}
    func start(duration:Duration) {
        timeout = Task { @MainActor [weak self] in
            do {try await Task.sleep(for:min(.seconds(20),max(.milliseconds(1),duration)));guard let self else {return};self.source.host?.closeActionJob(self.id,error:ExtensionHostError.timedOut)} catch {}
        }
    }
    func willPresent(_ popover:NSPopover) {
        closing = NotificationCenter.default.addObserver(forName:NSPopover.didCloseNotification,object:popover,queue:.main){ [weak self] _ in
            MainActor.assumeIsolated {guard let self else {return};self.source.host?.closeActionJob(self.id)}
        }
    }
    func didPresent() {presented = true;timeout?.cancel();timeout = nil}
    func close() {
        timeout?.cancel();timeout = nil
        if let closing {NotificationCenter.default.removeObserver(closing);self.closing = nil}
        action.closePopup()
    }
    deinit {if let closing {NotificationCenter.default.removeObserver(closing)}}
}

@available(macOS 15.4,*) @MainActor extension NativeBrowserExtensionHost {
    func actionSummaries(for web:WKWebView,profileID:UUID) -> [BrowserExtensionActionSummary] {
        guard let owner else {return []}
        return actionSummaries(for:web,profileID:profileID,client:owner)
    }
    func actionSummaries(for web:WKWebView,profileID:UUID,client:BrowserStore) -> [BrowserExtensionActionSummary] {
        guard let runtime = profiles[profileID],let tab = tabsByView[ObjectIdentifier(web)],tab.web === web,
              tab.key.storeID == client.extensionStoreID,tab.key.profileID == profileID else {return []}
        return owner?.extensionRecords(profileID:profileID).compactMap {record in
            guard let context = runtime.contexts[record.id],tab.live(context) === client,let action = context.action(for:tab) else {return nil}
            return BrowserExtensionActionSummary(id:record.id,label:action.label,badge:action.badgeText,isEnabled:action.isEnabled,presentsPopup:action.presentsPopup,icon:action.icon(for:CGSize(width:18,height:18)))
        } ?? []
    }
    func performAction(_ id:UUID,from web:WKWebView,profileID:UUID,anchor:NSView) throws {
        guard let owner else {throw ExtensionHostError.closed}
        try performAction(id,from:web,profileID:profileID,client:owner,anchor:anchor)
    }
    func performAction(_ id:UUID,from web:WKWebView,profileID:UUID,client:BrowserStore,anchor:NSView) throws {
        synchronizeBrowserState()
        guard let runtime = profiles[profileID],let context = runtime.contexts[id],let tab = tabsByView[ObjectIdentifier(web)],
              tab.web === web,tab.key.profileID == profileID,tab.key.storeID == client.extensionStoreID,
              let source = NativeExtensionSource(host:self,controller:runtime.controller,context:context,tab:tab),
              let window = source.window,anchor.window === window,window.attachedSheet == nil,
              let action = context.action(for:tab),action.isEnabled else {throw ExtensionHostError.stale}
        if let existing = actionJobs.values.first(where:{$0.action === action && $0.source.key == source.key && $0.source.window === window && $0.current}) {
            if existing.presented {closeActionJob(existing.id)}
            return
        }
        for job in Array(actionJobs.values) where job.source.window === window || job.action === action {closeActionJob(job.id)}
        if action.presentsPopup {
            guard actionJobs.count < 32 else {throw ExtensionHostError.native("Too many extension popups are waiting to open.")}
            let job = NativeExtensionActionJob(source:source,action:action,anchor:anchor)
            actionJobs[job.id] = job;job.start(duration:actionPreparationTimeout)
        }
        context.performAction(for:tab)
    }
    func closeActionJob(_ id:UUID,error:Error? = nil) {
        guard let job = actionJobs.removeValue(forKey:id) else {return}
        job.close()
        if let error,job.source.current {job.source.client?.message = error.localizedDescription}
    }
    func reconcileActionJobs() {
        for job in Array(actionJobs.values) where !job.current {closeActionJob(job.id)}
    }
    func reconcileExtensionSourceRequests() {reconcilePermissionRequests();reconcileActionJobs()}
    func sourceDocumentChanged(_ web:WKWebView) {reconcileExtensionSourceRequests();browserStateChanged()}
    func cancelActionJobs(profileID:UUID? = nil) {
        for job in Array(actionJobs.values) where profileID == nil || job.source.key.profileID == profileID {closeActionJob(job.id)}
    }
    func webExtensionController(_ controller:WKWebExtensionController,presentActionPopup action:WKWebExtension.Action,for context:WKWebExtensionContext,completionHandler:@escaping(Error?)->Void) {
        guard let profile = profileID(for:context),let owner,profiles[profile]?.controller === controller,
              authorized(context,profileID:profile,client:owner),action.webExtensionContext === context else {completionHandler(ExtensionHostError.stale);return}
        guard let job = actionJobs.values.first(where:{$0.action === action && $0.source.context === context && $0.source.controller === controller}) else {
            action.closePopup();completionHandler(ExtensionHostError.stale);return
        }
        guard !job.presented else {completionHandler(ExtensionHostError.stale);return}
        // A spanning extension's native interface retains its account settings.
        // Its private source website still has its own temporary store and UCC.
        guard job.current,
              let anchor = job.anchor,let popup = action.popupWebView,let popover = action.popupPopover,
              popup.url?.host == context.baseURL.host,
              owner.matchesBoostWebsiteDataStore(popup,profileID:job.source.key.profileID) else {
            closeActionJob(job.id);completionHandler(ExtensionHostError.stale);return
        }
        do {
            job.willPresent(popover);try actionPresenter.present(action,anchor)
            guard job.current,actionJobs[job.id] === job else {throw ExtensionHostError.stale}
            job.didPresent();action.hasUnreadBadgeText = false;completionHandler(nil)
        } catch {closeActionJob(job.id,error:error);completionHandler(error)}
    }
    func webExtensionController(_ controller:WKWebExtensionController,didUpdate action:WKWebExtension.Action,forExtensionContext context:WKWebExtensionContext) {
        guard let profile = profileID(for:context),let owner,profiles[profile]?.controller === controller,authorized(context,profileID:profile,client:owner),action.webExtensionContext === context else {return}
        owner.revision += 1
        for association in privateClients.values where association.profileID == profile {
            if let client = association.current,authorized(context,profileID:profile,client:client) {client.revision += 1}
        }
    }
}
