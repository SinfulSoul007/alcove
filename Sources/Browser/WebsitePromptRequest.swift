import AppKit
import WebKit

/// Owns one website reply and only the presentation created for that reply.
@MainActor final class WebsitePromptRequest {
    let id = UUID()
    weak var web: WKWebView?
    var onCancel: (() -> Void)?
    private enum State { case pending, finished, cancelled }
    private var state = State.pending
    private var dismissPresentation: (() -> Void)?

    init(web: WKWebView) { self.web = web }
    var isPending: Bool { state == .pending }

    func bindCancellation(_ dismiss: (() -> Void)?) {
        if state == .pending { dismissPresentation = dismiss }
        else if state == .cancelled { dismiss?() }
    }

    func finish() -> Bool {
        guard isPending else { return false }
        state = .finished; onCancel = nil; dismissPresentation = nil
        return true
    }

    func cancel() {
        guard isPending else { return }
        state = .cancelled
        let dismiss = dismissPresentation, reply = onCancel
        dismissPresentation = nil; onCancel = nil
        // A native cancellation may invoke its completion synchronously. The
        // terminal state above prevents that callback from answering twice.
        dismiss?(); reply?()
    }
}

extension BrowserStore {
    func cancelWebsitePrompts(for web: WKWebView) {
        for request in Array(websitePromptRequests.values) where request.web === web { request.cancel() }
    }
    func cancelAllWebsitePrompts() {
        for request in Array(websitePromptRequests.values) { request.cancel() }
    }
}
