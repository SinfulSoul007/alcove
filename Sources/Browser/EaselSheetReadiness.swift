import AppKit

/// A completed background operation may outlive the window's ability to show a sheet.
@MainActor final class EaselSheetReadiness {
    private weak var window: NSWindow?
    private let isCurrent: () -> Bool
    private let ready: () -> Void, canceled: () -> Void
    private var observers: [NSObjectProtocol] = []
    private var monitor: Task<Void, Never>?
    private var finished = false
    init(window: NSWindow, isCurrent: @escaping () -> Bool, ready: @escaping () -> Void, canceled: @escaping () -> Void) {
        self.window = window; self.isCurrent = isCurrent; self.ready = ready; self.canceled = canceled
    }
    func start() {
        guard let window, !finished else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didEndSheetNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            })
        }
        monitor = Task { [weak self] in
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                guard let self, !self.finished else { return }
                if ContinuousClock.now >= deadline { self.cancel(); self.canceled(); return }
                self.check()
            }
        }
        check()
    }
    private func check() {
        guard !finished else { return }
        guard let window, isCurrent() else { cancel(); canceled(); return }
        guard window.isKeyWindow, window.attachedSheet == nil else { return }
        cancel(); ready()
    }
    func cancel() {
        finished = true; monitor?.cancel(); monitor = nil
        observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
    }
    deinit { monitor?.cancel(); observers.forEach(NotificationCenter.default.removeObserver) }
}
