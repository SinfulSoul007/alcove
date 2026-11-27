import AppKit
import WebKit

struct EaselCaptureChoice { let raster: EaselRaster; let destination: EaselCaptureDestination }
@MainActor struct EaselCaptureEnvironment {
    var snapshot: (WKWebView, @escaping (Result<EaselRaster, Error>) -> Void) -> Void
    var preview: (EaselCaptureSource, EaselRaster, NSWindow, @escaping (EaselCaptureChoice?) throws -> Void) -> (() -> Void)
    static var live: Self { EaselCaptureNative().environment }
}

@MainActor final class EaselCaptureCoordinator {
    private final class Job {
        let source: EaselCaptureSource
        var previewing = false
        var cancelPresentation: (() -> Void)?
        var monitor: Task<Void, Never>?
        init(source: EaselCaptureSource) { self.source = source }
        deinit { monitor?.cancel() }
    }
    private let environment: EaselCaptureEnvironment
    private var jobs: [ObjectIdentifier: Job] = [:]
    init(environment: EaselCaptureEnvironment? = nil) { self.environment = environment ?? .live }
    func isBusy(in window: NSWindow) -> Bool { jobs[ObjectIdentifier(window)] != nil }
    func capture(web: WKWebView, store: BrowserStore, window: NSWindow) {
        let key = ObjectIdentifier(window)
        guard jobs[key] == nil else { return }
        let source: EaselCaptureSource
        do { source = try EaselCaptureSource(web: web, store: store, window: window) }
        catch { store.message = "Bring the page into this window before capturing it."; return }
        guard let rendered = source.renderedWeb else { return }
        let job = Job(source: source); jobs[key] = job
        job.monitor = Task { [weak self, weak job] in
            let deadline = ContinuousClock.now.advanced(by: .seconds(20))
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled, let self, let job, self.jobs[key] === job else { return }
                if !job.source.isCurrent { self.finish(key, job: job); return }
                if !job.previewing, ContinuousClock.now >= deadline {
                    job.source.store?.message = "This page took too long to capture. Try again."
                    self.finish(key, job: job); return
                }
            }
        }
        environment.snapshot(rendered) { [weak self, weak job] result in
            guard let self, let job, self.jobs[key] === job, !job.previewing else { return }
            guard job.source.isCurrent, let window = job.source.window else { self.finish(key, job: job); return }
            switch result {
            case .failure(let error):
                job.source.store?.message = "Couldn’t capture this page. " + error.localizedDescription
                self.finish(key, job: job)
            case .success(let raster):
                job.previewing = true
                let cancel = self.environment.preview(job.source, raster, window) { [weak self, weak job] choice in
                    guard let self, let job, self.jobs[key] === job, job.previewing else { return }
                    guard let choice else { self.finish(key, job: job); return }
                    guard job.source.isCurrent, let store = job.source.store else { throw SearchInputError.contextChanged }
                    _ = try store.publishEaselCapture(choice.raster, from: job.source, destination: choice.destination)
                    self.finish(key, job: job)
                }
                if self.jobs[key] === job { job.cancelPresentation = cancel } else { cancel() }
            }
        }
    }
    private func finish(_ key: ObjectIdentifier, job: Job) {
        guard jobs[key] === job else { return }
        jobs.removeValue(forKey: key); job.monitor?.cancel(); job.monitor = nil
        let cancel = job.cancelPresentation; job.cancelPresentation = nil; cancel?()
    }
    func cancel(in window: NSWindow) {
        let key = ObjectIdentifier(window)
        if let job = jobs[key] { finish(key, job: job) }
    }
}
