import AppKit
import BrowserCore
import UniformTypeIdentifiers

struct BookmarkExportSource: Sendable {
    let profileName: String
    let spaces: [Space]
    let favorites: [BrowserCore.Tab]
    let bookmarks: [PageRecord]
    func render() throws -> BookmarkHTMLExport {
        try Task.checkCancellation()
        return try BookmarkHTMLExport(spaces: spaces, favorites: favorites, bookmarks: bookmarks)
    }
}

extension BrowserStore {
    var canExportBookmarkHTML: Bool { canExportBookmarks(profileID: activeProfileID) }
    func canExportBookmarks(profileID: UUID) -> Bool {
        !isPrivate && !awaitingInitialMetadata && extensionPopupProfileID == nil &&
            (try? requireSpaceProfile(profileID)) != nil
    }
    func bookmarkExportSource(profileID: UUID) throws -> BookmarkExportSource {
        guard !isPrivate else { throw ProfileError.privateMode }
        guard !awaitingInitialMetadata, extensionPopupProfileID == nil else { throw ProfileError.locked }
        try requireSpaceProfile(profileID)
        guard let profile = profiles.first(where: { $0.id == profileID }) else { throw ProfileError.missing }
        return BookmarkExportSource(profileName: profile.name,
                                    spaces: session.spaces.filter { $0.effectiveProfileID == profileID },
                                    favorites: favorites(for: profileID), bookmarks: library(for: profileID).bookmarks)
    }
}

typealias BookmarkExportChooser = (NSWindow, String, BookmarkHTMLExport, @escaping (URL?) -> Void) -> (() -> Void)

private struct BookmarkExportRetention {
    private struct SpaceHeading: Hashable { let id: UUID; let name: String }
    private struct FolderHeading: Hashable { let spaceID: UUID; let name: String; let parent: String? }
    private struct Link: Hashable {
        let id: UUID, title: String, address: String
        init(_ tab: BrowserCore.Tab) { id = tab.id; title = tab.sidebarTitle; address = tab.homeURL ?? tab.url }
        init(_ record: PageRecord) { id = record.id; title = record.title; address = record.url }
    }
    private let spaces: Set<SpaceHeading>, folders: Set<FolderHeading>
    private let favorites: Set<Link>, pins: Set<Link>, bookmarks: Set<Link>
    init(_ source: BookmarkExportSource) {
        spaces = Set(source.spaces.map { SpaceHeading(id: $0.id, name: $0.name) })
        folders = Set(source.spaces.flatMap { space in
            let tree = SidebarFolderTree(space: space)
            return tree.names.map { FolderHeading(spaceID: space.id, name: $0, parent: tree.parents[$0]) }
        })
        favorites = Set(source.favorites.map(Link.init))
        pins = Set(source.spaces.flatMap(\.tabs).filter { $0.pinned && $0.favorite != true }.map(Link.init))
        bookmarks = Set(source.bookmarks.map(Link.init))
    }
    func isRetained(by source: BookmarkExportSource) -> Bool {
        let current = Self(source)
        return spaces.isSubset(of: current.spaces) && folders.isSubset(of: current.folders) && favorites.isSubset(of: current.favorites) &&
            pins.isSubset(of: current.pins) && bookmarks.isSubset(of: current.bookmarks)
    }
}

@MainActor final class BookmarkExportController {
    @MainActor private final class Job {
        let key: ObjectIdentifier, profileID: UUID
        weak var store: BrowserStore?
        weak var window: NSWindow?
        let stillOwned: () -> Bool
        let worker: Task<BookmarkHTMLExport, Error>
        let retention: BookmarkExportRetention
        var closing: NSObjectProtocol?
        var dismiss: (() -> Void)?
        init(store: BrowserStore, window: NSWindow, profileID: UUID, source: BookmarkExportSource, worker: Task<BookmarkHTMLExport, Error>, stillOwned: @escaping () -> Bool) {
            key = ObjectIdentifier(window); self.profileID = profileID; self.store = store; self.window = window
            self.worker = worker; self.stillOwned = stillOwned
            retention = BookmarkExportRetention(source)
        }
        deinit { worker.cancel(); if let closing { NotificationCenter.default.removeObserver(closing) } }
    }
    private var jobs: [ObjectIdentifier: Job] = [:]
    private let output: PageOutputCoordinator
    private let choose: BookmarkExportChooser
    init(output: PageOutputCoordinator, choose: BookmarkExportChooser? = nil) {
        self.output = output; self.choose = choose ?? Self.chooseNative
    }
    func isBusy(in window: NSWindow) -> Bool { jobs[ObjectIdentifier(window)] != nil }
    func canBegin(store: BrowserStore, window: NSWindow) -> Bool {
        store.canExportBookmarkHTML && window.attachedSheet == nil && !isBusy(in: window) && !output.isBusy(in: window)
    }
    @discardableResult
    func start(store: BrowserStore, window: NSWindow, stillOwned: @escaping () -> Bool) -> Bool {
        guard canBegin(store: store, window: window), stillOwned() else { return false }
        let source: BookmarkExportSource
        do { source = try store.bookmarkExportSource(profileID: store.activeProfileID) }
        catch { store.message = "Couldn’t export bookmarks. \(error.localizedDescription)"; return false }
        let worker = Task.detached(priority: .userInitiated) { try source.render() }
        let job = Job(store: store, window: window, profileID: store.activeProfileID, source: source, worker: worker, stillOwned: stillOwned)
        jobs[job.key] = job
        job.closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self, weak job] _ in
            MainActor.assumeIsolated { if let job { self?.finish(job, cancel: true) } }
        }
        Task { [weak self, weak job] in
            let result = await worker.result
            guard let self, let job, self.valid(job), let window = job.window else {
                if let self, let job { self.finish(job, cancel: true) }; return
            }
            switch result {
            case .failure(let error):
                self.finish(job, cancel: false)
                if !(error is CancellationError) { job.store?.message = "Couldn’t export bookmarks. \(error.localizedDescription)" }
            case .success(let export):
                guard window.attachedSheet == nil, !self.output.isBusy(in: window) else { self.finish(job, cancel: true); return }
                let dismiss = self.choose(window, source.profileName, export) { [weak self, weak job] destination in
                    guard let self, let job, self.jobs[job.key] === job else { return }
                    guard let destination else { self.finish(job, cancel: false); return }
                    guard destination.isFileURL, self.valid(job) else {
                        if job.stillOwned(), job.store?.isShuttingDown == false { job.store?.message = "Export was cancelled because its saved pages or profile changed. Try exporting again." }
                        self.finish(job, cancel: false); return
                    }
                    self.finish(job, cancel: false)
                    self.output.writeAcceptedFile(export.data, to: destination, failureMessage: "Could not export bookmarks. Check the destination and try again.")
                }
                if self.jobs[job.key] === job { job.dismiss = dismiss } else { dismiss() }
            }
        }
        return true
    }
    private func valid(_ job: Job) -> Bool {
        guard jobs[job.key] === job, job.window != nil, job.stillOwned(),
              let source = try? job.store?.bookmarkExportSource(profileID: job.profileID) else { return false }
        return job.retention.isRetained(by: source)
    }
    private func finish(_ job: Job, cancel: Bool) {
        guard jobs[job.key] === job else { return }
        jobs.removeValue(forKey: job.key); job.worker.cancel()
        if let closing = job.closing { NotificationCenter.default.removeObserver(closing); job.closing = nil }
        let dismiss = job.dismiss; job.dismiss = nil
        if cancel { dismiss?() }
    }
    static func savePanel(profileName: String, export: BookmarkHTMLExport) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]; panel.allowsOtherFileTypes = false
        panel.nameFieldStringValue = "Alcove Bookmarks.html"; panel.isExtensionHidden = false; panel.canCreateDirectories = true
        panel.message = "Export \(export.bookmarkCount) saved pages from the \(profileName) profile. This HTML file is readable outside Alcove."
        if export.skippedLinkCount > 0 { panel.message += " Skipping \(export.skippedLinkCount) unsupported addresses." }
        return panel
    }
    private static func chooseNative(window: NSWindow, profileName: String, export: BookmarkHTMLExport, completion: @escaping (URL?) -> Void) -> (() -> Void) {
        let panel = savePanel(profileName: profileName, export: export)
        panel.beginSheetModal(for: window) { [weak panel] result in completion(result == .OK ? panel?.url : nil) }
        return { [weak panel] in panel?.cancel(nil) }
    }
}

extension AppDelegate {
    @objc func exportBookmarks() {
        guard activeQuick == nil, let window = activeBrowserWindow, let store = windows[window] else { return }
        bookmarkExports.start(store: store, window: window) { [weak self, weak window, weak store] in
            guard let self, let window, let store else { return false }
            return self.windows[window] === store
        }
    }
}
