import AppKit
import BrowserCore

@MainActor struct LinkRoutingPrompt {
    var confirm: (NSWindow,String,String,@escaping(Bool)->Void)->Void
    static func makeAlert(title: String, detail: String) -> NSAlert {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
        alert.addButton(withTitle:"Cancel"); alert.addButton(withTitle:"Reload in Profile"); return alert
    }
    static var live: LinkRoutingPrompt {
        LinkRoutingPrompt(confirm:{ window,title,detail,reply in
            guard window.attachedSheet == nil else { reply(false); return }
            let alert = makeAlert(title:title,detail:detail)
            alert.beginSheetModal(for:window) { reply($0 == .alertSecondButtonReturn) }
        })
    }
}
@MainActor final class LinkReloadRequest {
    let request: PeekPromotionRequest
    weak var window: NSWindow?
    var closing: NSObjectProtocol?
    init(_ request: PeekPromotionRequest, window: NSWindow) { self.request = request; self.window = window }
}
extension BrowserStore {
    func finishLinkReload(_ job: LinkReloadRequest) {
        if let closing = job.closing { NotificationCenter.default.removeObserver(closing); job.closing = nil }
        if let key = linkReloadRequests.first(where:{$0.value === job})?.key { linkReloadRequests.removeValue(forKey:key) }
    }
    func cancelLinkReloads() { for job in Array(linkReloadRequests.values) { finishLinkReload(job) } }
    func requestExpandPeek(in context: PeekContext, confirmation: LinkRoutingPrompt? = nil, onComplete: ((UUID)->Void)? = nil, onError: ((Error)->Void)? = nil) {
        func report(_ error: Error) { if let onError { onError(error) } else { message = error.localizedDescription } }
        do {
            let request = try preparePeekPromotion(in:context)
            guard let window = request.web.window else { throw LinkRoutingError.contextChanged }
            let key = ObjectIdentifier(window)
            guard window.attachedSheet == nil, linkReloadRequests[key] == nil else { throw ProfileError.busy }
            if request.sourceProfileID == request.decision.destination.profileID {
                let id = try performPeekPromotion(request); onComplete?(id); return
            }
            let job = LinkReloadRequest(request,window:window); linkReloadRequests[key] = job
            job.closing = NotificationCenter.default.addObserver(forName:NSWindow.willCloseNotification,object:window,queue:.main) { [weak self,weak job] _ in
                MainActor.assumeIsolated { if let job { self?.finishLinkReload(job) } }
            }
            let profile = profiles.first(where:{$0.id == request.decision.destination.profileID})?.name ?? "destination profile"
            (confirmation ?? .live).confirm(window,"Reload in \(profile)?","This profile has separate website logins. Opening this preview there reloads the page. Unsaved forms and page state cannot be transferred.") { [weak self,weak job] accepted in
                guard let self, let job, self.linkReloadRequests[key] === job else { return }
                self.finishLinkReload(job)
                guard accepted else { return }
                guard let sourceWindow = job.window, request.web.window === sourceWindow else {
                    if let onError { onError(LinkRoutingError.contextChanged) } else { self.message = LinkRoutingError.contextChanged.localizedDescription }; return
                }
                do { let id = try self.performPeekPromotion(request,allowProfileChange:true); onComplete?(id) }
                catch { if let onError { onError(error) } else { self.message = error.localizedDescription } }
            }
        } catch { report(error) }
    }
    func peekOpenTitle(in context: PeekContext) -> String {
        guard let request = try? preparePeekPromotion(in:context) else { return "Open Preview…" }
        switch request.decision.destination {
        case .quick: return "Open in Quick Browse"
        case .newSpace: return "Open in New Space"
        case .space(let id,_): return "Open in \(session.spaces.first(where:{$0.id == id})?.name ?? "Space")"
        }
    }
}
