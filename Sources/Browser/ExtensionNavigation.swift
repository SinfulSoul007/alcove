import Foundation
import WebKit
import BrowserCore

@MainActor final class ExtensionNavigationSource {
    weak var store:BrowserStore?, web:WKWebView?
    weak var host:(any BrowserExtensionHosting)?
    let profileID:UUID, epoch:UUID
    let document:NSUUID, records:[BrowserExtensionRecord]
    init(store:BrowserStore,web:WKWebView,host:any BrowserExtensionHosting,profileID:UUID) {
        self.store = store;self.web = web;self.host = host;self.profileID = profileID
        epoch = store.extensionReviewEpoch(for:profileID);document = store.documentIdentity(for:web)
        records = store.extensionRecords(profileID:profileID)
    }
    var currentWeb:WKWebView? {
        guard let store, let web, let host, !store.isShuttingDown,
              store.extensionHosting === host, store.profileID(for:web) == profileID,
              !store.profileUnavailable(profileID), store.documentIdentity(for:web) == document,
              store.extensionReviewEpoch(for:profileID) == epoch, store.extensionRecords(profileID:profileID) == records,
              host.matches(web.configuration,profileID:profileID) else {return nil}
        return web
    }
}

@MainActor final class ExtensionNavigationProblem:Identifiable {
    let id = UUID(), source:ExtensionNavigationSource, url:URL, detail:String
    init(source:ExtensionNavigationSource,url:URL,error:Error) {self.source = source;self.url = url;detail = error.localizedDescription}
}

@MainActor final class ExtensionNavigationTicket {
    let id = UUID(), source:ExtensionNavigationSource, url:URL, isMainFrame:Bool
    private let allowed:WKNavigationActionPolicy
    private var decision:((WKNavigationActionPolicy)->Void)?
    private var preparation:Task<Void,Never>?, timeout:Task<Void,Never>?
    init(source:ExtensionNavigationSource,url:URL,isMainFrame:Bool,allow:WKNavigationActionPolicy,decision:@escaping(WKNavigationActionPolicy)->Void) {
        self.source = source;self.url = url;self.isMainFrame = isMainFrame;allowed = allow;self.decision = decision
    }
    func start(timeout duration:Duration) {
        guard let host = source.host else {finish(.cancel);return}
        let profile = source.profileID
        preparation = Task { @MainActor [weak self] in
            do {
                try await host.prepare(profileID:profile)
                guard let self else {return}
                guard self.source.currentWeb != nil, !host.requiresPreparation(profileID:profile) else {self.finish(.cancel);return}
                self.finish(self.allowed)
            } catch {self?.failed(error)}
        }
        timeout = Task { @MainActor [weak self] in
            do {try await Task.sleep(for:max(.milliseconds(1),duration));self?.failed(ExtensionHostError.timedOut)} catch {}
        }
    }
    func failed(_ error:Error) {
        guard decision != nil else {return}
        if source.currentWeb != nil, let store = source.store {
            store.extensionNavigationProblem = ExtensionNavigationProblem(source:source,url:url,error:error)
            store.message = "Extensions did not start. Your existing page was kept. " + error.localizedDescription
        }
        finish(.cancel)
    }
    func finish(_ policy:WKNavigationActionPolicy) {
        guard let decision else {return}
        self.decision = nil;preparation?.cancel();timeout?.cancel();preparation = nil;timeout = nil
        source.store?.extensionNavigationTickets.removeValue(forKey:id)
        decision(policy)
    }
}

extension BrowserStore {
    func beginExtensionMainNavigation(_ web:WKWebView) {
        cancelExtensionNavigations(for:web,mainFrameOnly:true)
        if extensionNavigationProblem?.source.web === web {extensionNavigationProblem = nil}
    }
    /// Central consumer for actual WKNavigationDelegate decisions, including downloads.
    func decideExtensionNavigation(_ web:WKWebView,url:URL,isMainFrame:Bool,allow:WKNavigationActionPolicy,timeout:Duration = .seconds(20),decision:@escaping(WKNavigationActionPolicy)->Void) {
        if isMainFrame {
            beginExtensionMainNavigation(web)
        }
        guard !isShuttingDown, let profile = profileID(for:web), !profileUnavailable(profile) else {decision(.cancel);return}
        guard let host = ensureExtensionHost() else {decision(allow);return}
        guard host.matches(web.configuration,profileID:profile) else {decision(.cancel);return}
        guard host.requiresPreparation(profileID:profile) else {decision(allow);return}
        guard extensionNavigationTickets.count < 256 else {decision(.cancel);message = "Too many pages are waiting for extensions. Retry after preparation finishes.";return}
        let source = ExtensionNavigationSource(store:self,web:web,host:host,profileID:profile)
        let ticket = ExtensionNavigationTicket(source:source,url:url,isMainFrame:isMainFrame,allow:allow,decision:decision)
        extensionNavigationTickets[ticket.id] = ticket;ticket.start(timeout:timeout)
    }
    func cancelExtensionNavigations(for web:WKWebView,mainFrameOnly:Bool = false) {
        for ticket in Array(extensionNavigationTickets.values) where ticket.source.web === web && (!mainFrameOnly || ticket.isMainFrame) {ticket.finish(.cancel)}
    }
    func cancelInvalidExtensionNavigations() {
        for ticket in Array(extensionNavigationTickets.values) where ticket.source.currentWeb == nil {ticket.finish(.cancel)}
        if extensionNavigationProblem?.source.currentWeb == nil {extensionNavigationProblem = nil}
    }
    func cancelAllExtensionNavigations() {
        for ticket in Array(extensionNavigationTickets.values) {ticket.finish(.cancel)}
        extensionNavigationProblem = nil
    }
    func continueWithoutExtensions() throws {
        guard let problem = extensionNavigationProblem, let web = problem.source.currentWeb, let host = problem.source.host else {throw ExtensionHostError.stale}
        try host.continueWithout(profileID:problem.source.profileID)
        extensionNavigationProblem = nil;web.load(URLRequest(url:problem.url))
    }
    func retryExtensionNavigation() async throws {
        guard let problem = extensionNavigationProblem, let host = problem.source.host, problem.source.currentWeb != nil else {throw ExtensionHostError.stale}
        host.invalidate(profileID:problem.source.profileID)
        try await host.prepare(profileID:problem.source.profileID)
        guard extensionNavigationProblem === problem, let web = problem.source.currentWeb else {throw ExtensionHostError.stale}
        extensionNavigationProblem = nil;web.load(URLRequest(url:problem.url))
    }
}
