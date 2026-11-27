import AppKit
import WebKit
import BrowserCore

/// One exact live document owns a capture through snapshot, preview and publish.
/// A destination picker may change selection; it cannot change this source.
@MainActor final class EaselCaptureSource {
    weak var store: BrowserStore?
    weak var web: WKWebView?
    weak var window: NSWindow?
    weak var renderedWeb: WKWebView?
    private weak var reader: ReaderSession?
    let profileID: UUID, generation: UUID
    let document: NSUUID, presentation: NSUUID
    let url: URL, title: String
    let spaceID: UUID?
    init(web: WKWebView, store: BrowserStore, window: NSWindow) throws {
        guard web.window === window, window.attachedSheet == nil, store.isFocusedWebsite(web),
              store.canModifyLocalMetadata, let profile = store.profileID(for: web), let url = web.url,
              ["https", "http", "file", "about"].contains(url.scheme?.lowercased() ?? "") else { throw SearchInputError.contextChanged }
        self.web = web; self.store = store; self.window = window; profileID = profile
        generation = store.easelImageGeneration(for: profile)
        document = store.documentIdentity(for: web); presentation = store.presentationIdentity(for: web)
        self.url = url; spaceID = store.spaceID(for: web)
        var label = (web.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if label.isEmpty { label = url.host ?? "Page capture" }
        while label.utf8.count > 256 { label.removeLast() }
        title = label
        if let reader = store.readerSession(for: web) {
            guard reader.isCurrent, reader.state == .ready, reader.reader.window === window else { throw SearchInputError.contextChanged }
            self.reader = reader; renderedWeb = reader.reader
        } else { renderedWeb = web }
    }
    var isCurrent: Bool {
        guard let store, let web, let window, let renderedWeb, !store.isShuttingDown,
              !store.profileUnavailable(profileID), store.canModifyLocalMetadata,
              store.easelImageGeneration(for: profileID) == generation,
              web.window === window, web.url == url, store.profileID(for: web) == profileID,
              store.documentIdentity(for: web) === document, store.presentationIdentity(for: web) === presentation,
              store.isVisibleWebsite(web), renderedWeb.window === window else { return false }
        if let reader { return store.readerSession(for: web) === reader && reader.isCurrent && reader.state == .ready && renderedWeb === reader.reader }
        return store.readerSession(for: web) == nil && renderedWeb === web
    }
    var attributionURL: String? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil, url.absoluteString.utf8.count <= 8192 else { return nil }
        return url.absoluteString
    }
}

enum EaselCaptureDestination {
    case new(title: String)
    case existing(id: UUID, revision: UUID)
}

extension BrowserStore {
    @discardableResult func publishEaselCapture(_ raster: EaselRaster, from source: EaselCaptureSource,
                                                destination: EaselCaptureDestination) throws -> UUID {
        guard source.store === self, source.isCurrent else { throw SearchInputError.contextChanged }
        let profile = source.profileID
        if case .existing(let id, _) = destination { try existingEaselDrafts?.flush(easelID: id, profileID: profile) }
        guard source.isCurrent else { throw SearchInputError.contextChanged }
        var candidate = makeDocument(), records = candidate.library(for: profile)
        var board: Easel
        switch destination {
        case .new(let title): board = try Easel(title: title)
        case .existing(let id, let revision):
            guard let existing = records.easels?.first(where: { $0.id == id }), existing.revision == revision else { throw EaselError.staleRevision }
            board = existing
        }
        let assets = try easelAssets(for: profile), asset = try assets.put(raster.data)
        var committed = false
        defer { if !committed { try? assets.remove(asset) } }
        let width = min(640, max(120, Double(raster.pixelWidth)))
        let height = min(640, max(80, width * Double(raster.pixelHeight) / Double(raster.pixelWidth)))
        let item = try EaselItem(frame: EaselFrame(x: 80, y: 80, width: width, height: height),
                                 content: .image(assetID: asset, pixelWidth: raster.pixelWidth, pixelHeight: raster.pixelHeight,
                                                 sourceURL: source.attributionURL, sourceTitle: source.title))
        try board.apply(.insert(item), expectedRevision: board.revision)
        if let index = records.easels?.firstIndex(where: { $0.id == board.id }) { records.easels?[index] = board }
        else { records.easels = [board] + (records.easels ?? []) }
        candidate.setLibrary(records, for: profile)
        let target: UUID
        if let captured = source.spaceID, candidate.session.spaces.contains(where: { $0.id == captured && (isPrivate || $0.effectiveProfileID == profile) }) { target = captured }
        else if let space = candidate.session.spaces.first(where: { isPrivate || $0.effectiveProfileID == profile }) { target = space.id }
        else {
            var space = Space(name: profiles.first(where: { $0.id == profile })?.name ?? "Personal", tabs: [])
            space.profileID = profile; candidate.session.spaces.append(space); target = space.id
        }
        if let index = candidate.session.spaces.firstIndex(where: { $0.id == target }),
           let tab = candidate.session.spaces[index].tabs.first(where: { EaselRoute.parse($0.url)?.id == board.id }) {
            candidate.session.spaces[index].selected = tab.id; candidate.session.activateSpace(target)
        } else { _ = try insertEaselTab(board, in: target, document: &candidate) }
        guard source.isCurrent else { throw SearchInputError.contextChanged }
        try commitQuickDocument(candidate, beforePublish: { self.closePrimaryPeek(); self.dismissCommand() })
        committed = true; return board.id
    }
}

extension BrowserStore {
    func canCapturePage(_ web: WKWebView) -> Bool {
        guard !isShuttingDown, canModifyLocalMetadata, let profile = profileID(for: web),
              !profileUnavailable(profile), web.url != nil, web.window != nil else { return false }
        return readerSession(for: web).map { $0.isCurrent && $0.state == .ready } ?? true
    }
    var canRequestPageCapture: Bool { (primaryPeekView ?? currentView).map(canCapturePage) ?? false }
    func requestPageCapture() {
        guard let web = primaryPeekView ?? currentView, canCapturePage(web) else { return }
        capturePageRequested?(web)
    }
}
