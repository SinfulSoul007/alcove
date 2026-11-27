import AppKit
import BrowserCore
import UniformTypeIdentifiers

enum EaselExportFormat: Sendable {
    case png, html
    var contentType: UTType { self == .png ? .png : .html }
    var fileExtension: String { self == .png ? "png" : "html" }
    func suggestedName(_ title: String) -> String { String(PageOutputFormat.pdf.suggestedName(title).dropLast(4)) + "." + fileExtension }
}
typealias EaselExportChooser = (NSWindow, EaselExportFormat, String, EaselExportLayout, @escaping (URL?) -> Void) -> (() -> Void)

@MainActor final class EaselExportController {
    @MainActor private final class Job {
        let key: ObjectIdentifier, destination: EaselImageDestination
        weak var canvas: EaselCanvasView?
        weak var window: NSWindow?
        let worker: Task<Data, Error>
        var close: NSObjectProtocol?
        var dismiss: (() -> Void)?
        var readiness: EaselSheetReadiness?
        init(canvas: EaselCanvasView, window: NSWindow, destination: EaselImageDestination, worker: Task<Data, Error>) {
            key = ObjectIdentifier(window); self.canvas = canvas; self.window = window; self.destination = destination; self.worker = worker
        }
        deinit { worker.cancel(); if let close { NotificationCenter.default.removeObserver(close) } }
    }
    private var jobs: [ObjectIdentifier: Job] = [:]
    private let output: PageOutputCoordinator
    private let choose: EaselExportChooser
    init(output: PageOutputCoordinator, choose: EaselExportChooser? = nil) { self.output = output; self.choose = choose ?? Self.chooseNative }
    func isBusy(in window: NSWindow) -> Bool { jobs[ObjectIdentifier(window)] != nil }
    func canBegin(canvas: EaselCanvasView) -> Bool {
        guard canvas.isCurrentPresentation, let store = canvas.store, let window = canvas.window else { return false }
        return window.isKeyWindow && window.attachedSheet == nil && store.canModifyLocalMetadata && !store.isShuttingDown &&
            !isBusy(in: window) && !output.isBusy(in: window)
    }
    @discardableResult func start(canvas: EaselCanvasView, format: EaselExportFormat) -> Bool {
        guard canBegin(canvas: canvas), canvas.activate(), let store = canvas.store, let window = canvas.window else { return false }
        let destination: EaselImageDestination, renderer: EaselCanvasExport
        do {
            destination = try store.easelImageDestination(for: canvas.tabID)
            guard let board = store.easelContext(for: canvas.tabID)?.easel else { throw EaselActionError.missing }
            guard let paper = canvas.canvas.background.usingColorSpace(.sRGB) else { throw EaselExportError.invalidImage }
            renderer = EaselCanvasExport(easel: board, assets: try store.easelAssets(for: destination.profileID),
                                         background: ThemeColor(paper.redComponent, paper.greenComponent, paper.blueComponent))
        } catch { store.message = "Couldn’t prepare this canvas. " + error.localizedDescription; return false }
        let worker = Task.detached(priority: .userInitiated) { try format == .png ? renderer.png() : renderer.html() }
        let job = Job(canvas: canvas, window: window, destination: destination, worker: worker)
        jobs[job.key] = job
        job.close = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self, weak job] _ in
            MainActor.assumeIsolated { if let job { self?.finish(job, cancel: true) } }
        }
        Task { [weak self, weak job] in
            do {
                let bytes = try await worker.value
                guard let self, let job, self.jobs[job.key] === job else { return }
                guard self.valid(job), !bytes.isEmpty, let window = job.window else { self.finish(job, cancel: true); return }
                job.readiness = EaselSheetReadiness(window: window, isCurrent: { [weak self, weak job] in
                    guard let self, let job, self.jobs[job.key] === job else { return false }
                    return self.valid(job)
                }, ready: { [weak self, weak job] in
                    guard let self, let job, self.jobs[job.key] === job, let window = job.window else { return }
                    let dismiss = self.choose(window, format, format.suggestedName(renderer.easel.title), EaselExportLayout(easel: renderer.easel)) { [weak self, weak job] url in
                        guard let self, let job, self.jobs[job.key] === job else { return }
                        guard let url else { self.finish(job, cancel: false); return }
                        guard self.valid(job), url.isFileURL else {
                            job.destination.store?.message = "Saving was canceled because this canvas or its window changed. Export the current canvas again."
                            self.finish(job, cancel: false); return
                        }
                        _ = self.output.writeAcceptedFile(bytes, to: url, failureMessage: "The requested canvas could not finish saving. Check the destination and try again.")
                        self.finish(job, cancel: false)
                    }
                    if self.jobs[job.key] === job { job.dismiss = dismiss } else { dismiss() }
                }, canceled: { [weak self, weak job] in
                    guard let self, let job, self.jobs[job.key] === job else { return }
                    job.destination.store?.message = "Canvas export was canceled because its window or content changed, or it waited too long. Try again."
                    self.finish(job, cancel: true)
                })
                job.readiness?.start()
            } catch {
                guard let self, let job, self.jobs[job.key] === job else { return }
                if self.valid(job), !(error is CancellationError) { job.destination.store?.message = "Couldn’t export this canvas. " + error.localizedDescription }
                self.finish(job, cancel: true)
            }
        }
        return true
    }
    private func valid(_ job: Job) -> Bool {
        guard let canvas = job.canvas, let window = job.window, canvas.window === window, canvas.isCurrentPresentation,
              let store = job.destination.store, canvas.store === store, store.focusedID == canvas.tabID else { return false }
        return store.isCurrentEaselImageDestination(job.destination)
    }
    private func finish(_ job: Job, cancel: Bool) {
        guard jobs[job.key] === job else { return }
        jobs.removeValue(forKey: job.key); job.worker.cancel()
        job.readiness?.cancel(); job.readiness = nil
        if let close = job.close { NotificationCenter.default.removeObserver(close); job.close = nil }
        let dismiss = job.dismiss; job.dismiss = nil
        if cancel { dismiss?() }
    }
    private static func chooseNative(window: NSWindow, format: EaselExportFormat, name: String, layout: EaselExportLayout, done: @escaping (URL?) -> Void) -> (() -> Void) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [format.contentType]; panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true; panel.nameFieldStringValue = name
        if format == .png {
            let label = NSTextField(labelWithString: "\(layout.pixelWidth) × \(layout.pixelHeight) pixels · Includes all cards")
            label.frame = NSRect(x: 0, y: 0, width: 360, height: 24); panel.accessoryView = label
        }
        panel.beginSheetModal(for: window) { response in done(response == .OK ? panel.url : nil) }
        return { [weak window] in if window?.attachedSheet === panel { window?.endSheet(panel, returnCode: .cancel) }; panel.orderOut(nil) }
    }
}

extension EaselCanvasView {
    func requestExport(_ format: EaselExportFormat) { if activate() { store?.easelExportRequested?(format) } }
}
