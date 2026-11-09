import AppKit

enum PageOutputQuitChoice { case wait, quitNow, cancel }
typealias PageOutputQuitPresenter = (Int, @escaping (PageOutputQuitChoice) -> Void) -> (() -> Void)

/// Keeps the native termination request alive while accepted output drains.
@MainActor final class PageOutputTermination {
    @MainActor private final class Attempt {
        let reply: (Bool) -> Void
        var presentationID: UUID?
        var cancellation: (() -> Void)?
        var delay: Task<Void, Never>?
        init(reply: @escaping (Bool) -> Void) { self.reply = reply }
        deinit { delay?.cancel() }
    }
    private let output: PageOutputCoordinator
    private let presenter: PageOutputQuitPresenter
    private var attempt: Attempt?
    init(output: PageOutputCoordinator, presenter: @escaping PageOutputQuitPresenter) {
        self.output = output; self.presenter = presenter
    }
    func decision(reply: @escaping (Bool) -> Void) -> NSApplication.TerminateReply {
        if attempt != nil { _ = resurface(); return .terminateLater }
        guard output.pendingOutputCount > 0 else { return .terminateNow }
        let current = Attempt(reply: reply); attempt = current
        output.waitForPendingOutput { [weak self, weak current] success in
            guard let self, let current else { return }; self.complete(current, success: success)
        }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(150))
        current.delay = Task { [weak self, weak current] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard !Task.isCancelled, let self, let current else { return }
            self.show(current)
        }
        return .terminateLater
    }
    func resurface() -> Bool {
        guard let current = attempt else { return false }
        current.delay?.cancel(); current.delay = nil
        // Defer even an immediate injected presenter until the caller returns.
        Task { [weak self, weak current] in
            guard let self, let current else { return }; self.show(current)
        }
        return true
    }
    private func dismiss(_ current: Attempt) {
        current.presentationID = nil
        let cancellation = current.cancellation; current.cancellation = nil
        cancellation?()
    }
    private func show(_ current: Attempt) {
        guard attempt === current, current.presentationID == nil else { return }
        guard output.pendingOutputCount > 0 else { return }
        let id = UUID(); current.presentationID = id
        let cancellation = presenter(output.pendingOutputCount) { [weak self, weak current] choice in
            guard let self, let current, self.attempt === current, current.presentationID == id else { return }
            switch choice {
            case .wait: self.dismiss(current)
            case .quitNow: self.complete(current, success: true)
            case .cancel: self.complete(current, success: false)
            }
        }
        if attempt === current, current.presentationID == id { current.cancellation = cancellation }
        else { cancellation() }
    }
    private func complete(_ current: Attempt, success: Bool) {
        guard attempt === current else { return }
        attempt = nil; current.delay?.cancel(); current.delay = nil
        dismiss(current)
        // NSApplication must receive .terminateLater before its matching reply.
        Task { current.reply(success) }
    }
}
