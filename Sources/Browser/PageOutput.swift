import AppKit
import WebKit
import UniformTypeIdentifiers

enum PageOutputFormat: Equatable, Sendable {
    case pdf, webArchive
    var fileExtension: String { self == .pdf ? "pdf" : "webarchive" }
    var contentType: UTType { self == .pdf ? .pdf : .webArchive }
    func suggestedName(_ title: String?) -> String {
        let limited = (title ?? "").unicodeScalars.prefix(512)
        let unsafe = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        var name = String(String.UnicodeScalarView(limited.map { unsafe.contains($0) ? UnicodeScalar(45)! : $0 }))
            .precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        while name.utf8.count > 180 { name.removeLast() }
        if name.isEmpty { name = "Page" }
        return name + "." + fileExtension
    }
}

@MainActor struct PageOutputEnvironment {
    var capture: (WKWebView, PageOutputFormat, @escaping (Result<Data, Error>) -> Void) -> Void
    var choose: (NSWindow, String, PageOutputFormat, @escaping (URL?) -> Void) -> (() -> Void)
    var print: (WKWebView, NSWindow, @escaping (Bool) -> Void) -> (() -> Void)
    var write: (Data, URL, @escaping (Result<Void, Error>) -> Void) -> Void
    var reportError: (String, NSWindow) -> Void
    var reportOrphanedError: (String) -> Void
    static var live: PageOutputEnvironment { PageOutputNative().environment }
}

@MainActor final class PageOutputCoordinator {
    private enum Stage { case capture, ready, choose, print, write }
    @MainActor private final class Job {
        let id = UUID(), key: ObjectIdentifier, profile: UUID, url: URL, title: String?
        weak var store: BrowserStore?
        weak var web: WKWebView?
        weak var window: NSWindow?
        var stage: Stage
        var data: Data?
        var presentation: (() -> Void)?
        var cancelled = false
        var timeout: Task<Void, Never>?
        var closing: NSObjectProtocol?
        var readiness: [NSObjectProtocol] = []
        init(web: WKWebView, store: BrowserStore, window: NSWindow, profile: UUID, url: URL, stage: Stage) {
            self.key = ObjectIdentifier(window); self.web = web; self.store = store; self.window = window
            self.profile = profile; self.url = url; self.title = web.title; self.stage = stage
        }
        deinit {
            timeout?.cancel(); if let closing { NotificationCenter.default.removeObserver(closing) }
            readiness.forEach(NotificationCenter.default.removeObserver)
        }
    }
    private final class Notice {
        let job: Job, message: String, acceptedFile: Bool
        var observations: [NSObjectProtocol] = []
        init(job: Job, message: String, acceptedFile: Bool) { self.job = job; self.message = message; self.acceptedFile = acceptedFile }
        deinit { observations.forEach(NotificationCenter.default.removeObserver) }
    }
    private let environment: PageOutputEnvironment
    private let preparationTimeout: Duration
    private var jobs: [ObjectIdentifier: Job] = [:]
    private var notices: [ObjectIdentifier: Notice] = [:]
    private var writes: [UUID: Job] = [:]
    private var prints: [UUID: Job] = [:]
    private struct Waiter { let completion: (Bool) -> Void; var failed = false }
    private var waiters: [Waiter] = []
    private let orphanedFailure = "A requested page could not finish saving. Check the destination and try again."
    init(environment: PageOutputEnvironment? = nil, preparationTimeout: Duration = .seconds(30)) {
        self.environment = environment ?? .live; self.preparationTimeout = preparationTimeout
    }
    func isBusy(in window: NSWindow) -> Bool { jobs[ObjectIdentifier(window)] != nil }
    var pendingWriteCount: Int { writes.count }
    var pendingOutputCount: Int { writes.count + prints.count }
    func waitForPendingOutput(_ completion: @escaping (Bool) -> Void) {
        guard pendingOutputCount > 0 else { completion(true); return }
        waiters.append(Waiter(completion: completion))
    }
    private func settleWaiters() {
        guard pendingOutputCount == 0 else { return }
        let ready = waiters; waiters.removeAll()
        ready.forEach { $0.completion(!$0.failed) }
    }
    func canBegin(web: WKWebView, store: BrowserStore, window: NSWindow) -> Bool {
        web.window === window && window.attachedSheet == nil && !isBusy(in: window)
            && web.url != nil && store.isFocusedWebsite(web)
    }
    private func begin(web: WKWebView, store: BrowserStore, window: NSWindow, stage: Stage) -> Job? {
        guard canBegin(web: web, store: store, window: window), let profile = store.profileID(for: web), let url = web.url else { return nil }
        discardNotice(in: ObjectIdentifier(window))
        let job = Job(web: web, store: store, window: window, profile: profile, url: url, stage: stage)
        jobs[job.key] = job
        job.closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self, weak job] _ in
            MainActor.assumeIsolated { if let job { self?.finish(job, cancel: true) } }
        }
        return job
    }
    private func current(_ job: Job, stage: Stage) -> Bool { jobs[job.key] === job && job.stage == stage }
    private func valid(_ job: Job) -> Bool {
        guard !job.cancelled, let web = job.web, let store = job.store, let window = job.window else { return false }
        return web.window === window && web.url == job.url && store.profileID(for: web) == job.profile && store.isVisibleWebsite(web)
    }
    private func install(_ cancellation: @escaping () -> Void, for job: Job, stage: Stage) {
        if current(job, stage: stage) { job.presentation = cancellation }
        else if job.cancelled { cancellation() }
    }
    private func finish(_ job: Job, cancel: Bool = false, message: String? = nil) {
        guard jobs[job.key] === job else { return }
        jobs.removeValue(forKey: job.key); job.timeout?.cancel(); job.timeout = nil
        if let token = job.closing { NotificationCenter.default.removeObserver(token); job.closing = nil }
        job.readiness.forEach(NotificationCenter.default.removeObserver); job.readiness.removeAll()
        let presentation = job.presentation; job.presentation = nil; job.data = nil; job.cancelled = cancel
        if let message { report(message, for: job) }
        if cancel { presentation?() }
    }
    private func discardNotice(in key: ObjectIdentifier) {
        guard let notice = notices.removeValue(forKey: key), notice.acceptedFile else { return }
        environment.reportOrphanedError(orphanedFailure)
    }
    private func report(_ message: String, for job: Job, acceptedFile: Bool = false) {
        guard valid(job), let web = job.web, let store = job.store, let window = job.window else {
            if acceptedFile { environment.reportOrphanedError(orphanedFailure) }; return
        }
        if store.isFocusedWebsite(web), window.attachedSheet == nil { environment.reportError(message, window); return }
        discardNotice(in: job.key)
        let notice = Notice(job: job, message: message, acceptedFile: acceptedFile); notices[job.key] = notice
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didEndSheetNotification, NSWindow.willCloseNotification] {
            notice.observations.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self, weak job] notification in
                MainActor.assumeIsolated {
                    guard let self, let job, self.notices[job.key]?.job === job else { return }
                    if notification.name == NSWindow.willCloseNotification { self.discardNotice(in: job.key) }
                    else { self.deliverNotice(for: job) }
                }
            })
        }
    }
    private func deliverNotice(for job: Job) {
        guard let notice = notices[job.key], notice.job === job else { return }
        guard valid(job), let web = job.web, let store = job.store, let window = job.window else { discardNotice(in: job.key); return }
        guard store.isFocusedWebsite(web), window.attachedSheet == nil else { return }
        notices.removeValue(forKey: job.key)
        environment.reportError(notice.message, window)
    }
    func cancel(in window: NSWindow) {
        discardNotice(in: ObjectIdentifier(window))
        if let job = jobs[ObjectIdentifier(window)] { finish(job, cancel: true) }
    }
    func printPage(web: WKWebView, store: BrowserStore, window: NSWindow) {
        guard let job = begin(web: web, store: store, window: window, stage: .print) else { return }
        prints[job.id] = job
        let cancellation = environment.print(web, window) { [weak self, job] _ in
            guard let self, self.prints[job.id] === job else { return }
            self.prints.removeValue(forKey: job.id)
            self.finish(job); self.settleWaiters()
        }
        install(cancellation, for: job, stage: .print)
    }
    func save(web: WKWebView, store: BrowserStore, window: NSWindow, format: PageOutputFormat) {
        guard let job = begin(web: web, store: store, window: window, stage: .capture) else { return }
        let deadline = ContinuousClock.now.advanced(by: preparationTimeout)
        job.timeout = Task { [weak self, weak job] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard !Task.isCancelled, let self, let job, self.current(job, stage: .capture) else { return }
            self.finish(job, message: "Preparing this page took too long. Try saving again.")
        }
        environment.capture(web, format) { [weak self, weak job] result in
            guard let self, let job, self.current(job, stage: .capture) else { return }
            job.timeout?.cancel(); job.timeout = nil
            guard self.valid(job), let window = job.window else { self.finish(job); return }
            switch result {
            case .failure(let error): self.finish(job, message: "Could not prepare this page: " + error.localizedDescription)
            case .success(let data):
                guard !data.isEmpty else { self.finish(job, message: "This page produced no content to save."); return }
                job.data = data; job.stage = .ready
                for name in [NSWindow.didBecomeKeyNotification, NSWindow.didEndSheetNotification] {
                    job.readiness.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self, weak job] _ in
                        MainActor.assumeIsolated { if let job { self?.choose(job, format: format) } }
                    })
                }
                self.choose(job, format: format)
            }
        }
    }
    private func choose(_ job: Job, format: PageOutputFormat) {
        guard current(job, stage: .ready) else { return }
        guard valid(job), let web = job.web, let store = job.store, let window = job.window else { finish(job); return }
        guard store.isFocusedWebsite(web), window.attachedSheet == nil else { return }
        job.readiness.forEach(NotificationCenter.default.removeObserver); job.readiness.removeAll(); job.stage = .choose
        let cancellation = environment.choose(window, format.suggestedName(job.title), format) { [weak self, weak job] destination in
            guard let self, let job, self.current(job, stage: .choose) else { return }
            guard let destination else { self.finish(job); return }
            guard destination.isFileURL, self.valid(job), let data = job.data else {
                self.finish(job)
                self.environment.reportOrphanedError("Saving was cancelled because the source page or its window changed. Try saving the current page again.")
                return
            }
            job.presentation = nil; job.data = nil; job.stage = .write
            // Explicit acceptance commits these immutable bytes; IO may finish after close.
            self.writes[job.id] = job
            self.environment.write(data, destination) { [weak self, job] result in
                guard let self, self.writes[job.id] === job else { return }
                self.writes.removeValue(forKey: job.id)
                switch result {
                case .success: self.finish(job)
                case .failure(let error):
                    for index in self.waiters.indices { self.waiters[index].failed = true }
                    self.finish(job)
                    self.report("Could not save this page: " + error.localizedDescription, for: job, acceptedFile: true)
                }
                self.settleWaiters()
            }
        }
        install(cancellation, for: job, stage: .choose)
    }
}
