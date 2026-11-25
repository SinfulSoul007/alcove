import AppKit
import WebKit
import BrowserCore

enum WebsiteProtectionPurpose {
    case navigation(isMainFrame:Bool),download
    var restoresAddress:Bool {if case .navigation(let main)=self {return main};return false}
}

@MainActor final class WebsiteProtectionSource {
    weak var store:BrowserStore?,web:WKWebView?
    let profileID:UUID,document:NSUUID
    private let dataStore:WKWebsiteDataStore
    private let previousURL:URL?,previousInitialURL:URL?,previousTitle:String?
    init(store:BrowserStore,web:WKWebView,profileID:UUID) {
        self.store=store;self.web=web;self.profileID=profileID
        document=store.documentIdentity(for:web);dataStore=web.configuration.websiteDataStore
        previousURL=web.backForwardList.currentItem?.url;previousInitialURL=web.backForwardList.currentItem?.initialURL
        previousTitle=web.title.flatMap{$0.isEmpty ? nil:$0}
    }
    var currentWeb:WKWebView? {
        guard let store,let web,!store.isShuttingDown,web.navigationDelegate === store,
              store.profileID(for:web)==profileID,!store.profileUnavailable(profileID),
              store.documentIdentity(for:web) === document,
              store.websiteDataStore(forProfile:profileID) === dataStore else {return nil}
        return web
    }
    func restoredTab(_ original:BrowserCore.Tab) -> BrowserCore.Tab {
        var tab=original
        tab.url=previousURL?.absoluteString ?? "";tab.title=previousTitle ?? previousURL?.host ?? "New Tab"
        return tab
    }
    func restoreAddress() {
        guard let store,let web,let id=store.views.first(where:{$0.value === web})?.key else {return}
        store.update(id){$0=restoredTab($0)}
        if let profile=store.quickProfileID(id) {
            // Only a committed page can identify an existing Quick Browse route.
            // Preserve its original address when that page arrived via redirects.
            store.mutateLibrary(for:profile) {records in
                guard let index=records.quickPages?.firstIndex(where:{$0.id==id}) else {return}
                records.quickPages?[index].requestedURL=(previousInitialURL ?? previousURL)?.absoluteString
            }
            store.save()
        }
    }
}

/// Owns one real framework decision. Approval never constructs or replays a request.
@MainActor final class WebsiteProtectionTicket:Identifiable {
    let id=UUID(),source:WebsiteProtectionSource,url:URL,kind:WebsiteProtectionPurpose
    private(set) var assessment:WebsiteProtectionAssessment?
    private(set) var revision=UUID()
    private weak var presentation:NSView?
    private var decision:(@MainActor (Bool)->Void)?
    private var work:Task<Void,Never>?,timeout:Task<Void,Never>?
    private var restoringFullscreen=false
    private var pendingAssessment:WebsiteProtectionAssessment?
    var isPending:Bool {decision != nil}
    var canPresent:Bool {isPending && !restoringFullscreen}
    init(source:WebsiteProtectionSource,url:URL,kind:WebsiteProtectionPurpose,decision:@escaping @MainActor (Bool)->Void) {
        self.source=source;self.url=url;self.kind=kind;self.decision=decision
    }
    deinit {
        work?.cancel();timeout?.cancel()
        if let decision {Task{@MainActor in decision(false)}}
    }
    func start(timeout duration:Duration) {
        guard let service=source.store?.websiteProtection else {finish(false);return}
        if let assessment=service.cachedAssessment(for:url) {consume(assessment);return}
        work=Task{@MainActor [weak self,service] in
            // The shared wait retains no browsing address or canceled ticket.
            let result=await service.load()
            guard !Task.isCancelled,let self,self.isPending else {return}
            self.consume(service.assessment(for:self.url,result:result))
        }
        timeout=Task{@MainActor [weak self] in
            do {try await Task.sleep(for:max(.milliseconds(1),duration));self?.consume(.unavailable(.unreadableResources))}catch{}
        }
    }
    private func consume(_ value:WebsiteProtectionAssessment) {
        guard isPending,let web=source.currentWeb else {finish(false);return}
        if case .unlisted=value {finish(true);return}
        work?.cancel();timeout?.cancel();work=nil;timeout=nil
        if restoringFullscreen {pendingAssessment=value;return}
        if let fullscreen=(web as? SplitDropWebView)?.websiteFullscreen,
           fullscreen.isBorrowed || web.fullscreenState != .notInFullscreen {
            restoringFullscreen=true;pendingAssessment=value
            fullscreen.exit { [weak self] restored in
                guard let self,self.isPending else {return}
                self.restoringFullscreen=false
                let pending=self.pendingAssessment;self.pendingAssessment=nil
                guard restored,let pending,self.source.currentWeb != nil else {self.finish(false);return}
                self.consume(pending)
            }
            return
        }
        assessment=value;revision=UUID()
        if let store=source.store,let web=source.web {
            for other in Array(store.websiteProtectionTickets.values) where other !== self && other.source.web === web {other.cancel()}
            store.objectWillChange.send()
        }
    }
    func presented(in view:NSView) {
        guard let parent=view.superview,parent === source.web?.superview,view.window != nil else {return}
        presentation=view
    }
    func approve(expectedRevision:UUID) {
        guard isPending,revision==expectedRevision,let web=source.currentWeb,
              let presentation,let window=presentation.window,window.isVisible,
              !presentation.isHiddenOrHasHiddenAncestor,presentation.superview === web.superview else {return}
        guard assessment != nil else {return}
        if case .unavailable=assessment,let fresh=source.store?.websiteProtection.cachedAssessment(for:url),case .listed=fresh {
            consume(fresh);return
        }
        finish(true)
    }
    func cancel(restoringAddress:Bool = true) {finish(false,restoringAddress:restoringAddress)}
    private func finish(_ requested:Bool,restoringAddress:Bool = true) {
        guard let decision else {return}
        let approved=requested && source.currentWeb != nil
        self.decision=nil;work?.cancel();timeout?.cancel();work=nil;timeout=nil;presentation=nil
        restoringFullscreen=false;pendingAssessment=nil
        let store=source.store
        store?.websiteProtectionTickets.removeValue(forKey:id)
        if !approved && restoringAddress && kind.restoresAddress {source.restoreAddress()}
        store?.objectWillChange.send()
        decision(approved)
    }
}

extension BrowserStore {
    @discardableResult func decideWebsiteProtection(_ web:WKWebView,url:URL,kind:WebsiteProtectionPurpose,timeout:Duration = .seconds(10),decision:@escaping @MainActor (Bool)->Void) -> WebsiteProtectionTicket? {
        guard !isShuttingDown,let profile=profileID(for:web),!profileUnavailable(profile) else {decision(false);return nil}
        let source=WebsiteProtectionSource(store:self,web:web,profileID:profile)
        return decideWebsiteProtection(source,url:url,kind:kind,timeout:timeout,decision:decision)
    }
    @discardableResult func decideWebsiteProtection(_ source:WebsiteProtectionSource,url:URL,kind:WebsiteProtectionPurpose,timeout:Duration = .seconds(10),decision:@escaping @MainActor (Bool)->Void) -> WebsiteProtectionTicket? {
        guard source.store === self,let web=source.currentWeb else {decision(false);return nil}
        if let value=websiteProtection.cachedAssessment(for:url),case .unlisted=value {decision(true);return nil}
        guard websiteProtectionTickets.count<128,
              websiteProtectionTickets.values.filter({$0.source.web === web}).count<8 else {decision(false);return nil}
        let ticket=WebsiteProtectionTicket(source:source,url:url,kind:kind,decision:decision)
        websiteProtectionTickets[ticket.id]=ticket;objectWillChange.send();ticket.start(timeout:timeout)
        return ticket
    }
    func websiteProtectionTicket(for web:WKWebView) -> WebsiteProtectionTicket? {
        websiteProtectionTickets.values.first{$0.source.web === web && $0.isPending && $0.source.currentWeb != nil && $0.assessment != nil} ??
            websiteProtectionTickets.values.first{$0.source.web === web && $0.isPending && $0.source.currentWeb != nil}
    }
    func cancelWebsiteProtectionTickets(for web:WKWebView,restoringAddress:Bool = true) {
        for ticket in Array(websiteProtectionTickets.values) where ticket.source.web === web {ticket.cancel(restoringAddress:restoringAddress)}
    }
    func cancelInvalidWebsiteProtectionTickets() {
        for ticket in Array(websiteProtectionTickets.values) where ticket.source.currentWeb==nil {ticket.cancel()}
    }
    func cancelAllWebsiteProtectionTickets() {for ticket in Array(websiteProtectionTickets.values) {ticket.cancel()}}
}
