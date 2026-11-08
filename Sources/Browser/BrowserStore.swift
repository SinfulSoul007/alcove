import AppKit
import SwiftUI
import WebKit
import BrowserCore
import CryptoKit

@MainActor
final class BrowserStore: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    @Published var session = Session()
    @Published var commandVisible = false
    @Published var command = ""
    var commandOpensNewTab = false
    @Published var sidebarVisible = true
    @Published var splitID: UUID?
    @Published var activePaneID: UUID?
    @Published var message: String?
    @Published var revision = 0
    @Published var library = BrowserLibrary()
    @Published var preferences = Preferences()
    @Published var libraryVisible = false
    @Published var settingsVisible = false
    @Published var findVisible = false
    @Published var findText = ""
    @Published var findResult = ""
    @Published var downloads: [DownloadItem] = []
    @Published var clearingData = false
    @Published var peekView: WKWebView?
    var peekObservations: [NSKeyValueObservation] = []
    @Published var siteIcons: [UUID: NSImage] = [:]
    let isPrivate: Bool
    let privateDataStore: WKWebsiteDataStore?
    var vault: MetadataStore?
    var savingEnabled = true
    @Published var unlocking = false
    var downloadIDs: [ObjectIdentifier: UUID] = [:]
    var archiveTimer: Timer?
    var views: [UUID: WKWebView] = [:]
    var accessOrder: [UUID] = []
    var observations: [UUID: [NSKeyValueObservation]] = [:]
    private var saveTask: Task<Void, Never>?
    let sessionURL: URL
    var spaceIndex: Int { session.spaces.firstIndex { $0.id == session.selectedSpace } ?? 0 }
    var space: Space { session.spaces[spaceIndex] }
    var selectedID: UUID? { space.selected }
    var focusedID: UUID? { activePaneID == splitID && splitID != nil ? splitID : selectedID }
    var selectedTab: BrowserCore.Tab? { space.tabs.first { $0.id == focusedID } }
    var currentView: WKWebView? { focusedID.flatMap { views[$0] } }
    func focusPane(_ id: UUID) { if id == selectedID || id == splitID { activePaneID = id } }

    init(isPrivate: Bool = false, dataRoot: URL? = nil, keyProvider: (Bool) throws -> SymmetricKey = { try MetadataKey.load(createIfMissing: $0) }) {
        self.isPrivate = isPrivate
        privateDataStore = isPrivate ? .nonPersistent() : nil
        let root = dataRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OpenBrowser", isDirectory: true)
        sessionURL = root.appendingPathComponent("session.sealed")
        super.init()
        guard !isPrivate else { return }
        do {
            let exists = FileManager.default.fileExists(atPath: sessionURL.path)
            let key = try keyProvider(!exists)
            let storage = MetadataStore(url: sessionURL, key: key)
            vault = storage
            if let document = try storage.load(BrowserDocument.self) {
                session = document.session; library = document.library; preferences = document.preferences
            } else {
                let legacyURL = root.appendingPathComponent("session.json")
                if FileManager.default.fileExists(atPath: legacyURL.path) {
                    session = try JSONDecoder().decode(Session.self, from: Data(contentsOf: legacyURL))
                    repairSession()
                    try storage.save(BrowserDocument(session: session))
                    try FileManager.default.removeItem(at: legacyURL)
                }
            }
            repairSession()
            archiveTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in Task { @MainActor in self?.archiveOldTabs() } }
        } catch { savingEnabled = false; message = "Local data is locked or unreadable. Saving is disabled to preserve it. \(error.localizedDescription)" }
    }
    func repairSession() {
        if session.spaces.isEmpty { session = Session() }
        if !session.spaces.contains(where: { $0.id == session.selectedSpace }) { session.selectedSpace = session.spaces[0].id }
        for i in session.spaces.indices {
            if session.spaces[i].tabs.isEmpty { session.spaces[i].tabs = [BrowserCore.Tab()] }
            if !session.spaces[i].tabs.contains(where: { $0.id == session.spaces[i].selected }) { session.spaces[i].selected = session.spaces[i].tabs.first?.id }
        }
    }
    func save() {
        guard !isPrivate, savingEnabled else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }
    func flush() {
        guard !isPrivate, savingEnabled else { return }
        do { try vault?.save(BrowserDocument(session: session, library: library, preferences: preferences)) }
        catch { savingEnabled = false; message = "Couldn’t save your data. Existing data is preserved. \(error.localizedDescription)" }
    }
    func select(_ id: UUID) {
        guard session.spaces[spaceIndex].tabs.contains(where: { $0.id == id }) else { return }
        session.spaces[spaceIndex].selected = id; activePaneID = nil
        update(id) { $0.lastAccessed = Date() }
        if activePaneID == id { activePaneID = nil }
        if splitID == id { splitID = nil }
        save()
    }
    func selectSpace(_ id: UUID) { activePaneID = nil; splitID = nil; session.selectedSpace = id; save() }
    func addSpace() {
        let alert = NSAlert(); alert.messageText = "Create a Space"; alert.informativeText = "Give this collection of tabs a name."
        let field = NSTextField(string: ""); field.placeholderString = "Work, Personal, Research…"; field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field; alert.addButton(withTitle: "Create"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            let newSpace = Space(name: name); session.spaces.append(newSpace); selectSpace(newSpace.id)
        }
    }
    @discardableResult func newTab(url: URL? = nil) -> UUID {
        let tab = BrowserCore.Tab(title: url?.host ?? "New Tab", url: url?.absoluteString ?? "")
        session.spaces[spaceIndex].tabs.append(tab); select(tab.id)
        return tab.id
    }
    func close(_ id: UUID) {
        guard let owner = session.spaces.first(where: { $0.tabs.contains(where: { $0.id == id }) })?.id else { return }
        if let tab = tab(id), tab.pinned {
            update(id) { $0.url = $0.homeURL ?? $0.url; $0.title = $0.pinnedTitle ?? $0.title }
            discardView(id)
            if activePaneID == id { activePaneID = nil }
        if splitID == id { splitID = nil }
            if let s = session.spaces.firstIndex(where: { $0.id == owner }), session.spaces[s].selected == id {
                if let next = session.spaces[s].tabs.first(where: { $0.id != id && !$0.pinned }) { session.spaces[s].selected = next.id }
                else { let empty = BrowserCore.Tab(); session.spaces[s].tabs.append(empty); session.spaces[s].selected = empty.id }
            }
            save(); return
        }
        if let tab = tab(id), !tab.url.isEmpty {
            library.closedTabs.insert(tab, at: 0)
            library.closedTabs = Array(library.closedTabs.prefix(30))
        }
        if activePaneID == id { activePaneID = nil }
        if splitID == id { splitID = nil }
        discardView(id)
        session.close(id, in: owner)
        if splitID == selectedID { splitID = nil }
        save()
    }
    func togglePin(_ id: UUID) {
        update(id) {
            $0.pinned.toggle()
            if $0.pinned { $0.homeURL = $0.url; $0.pinnedTitle = $0.title }
            else { $0.favorite = nil; $0.folder = nil; $0.homeURL = nil; $0.pinnedTitle = nil }
        }
    }
    var favorites: [BrowserCore.Tab] { session.spaces.flatMap(\.tabs).filter { $0.favorite == true } }
    func selectAny(_ id: UUID) {
        if let owner = session.spaces.first(where: { $0.tabs.contains(where: { $0.id == id }) }) {
            if owner.id != space.id { selectSpace(owner.id) }; select(id)
        }
    }
    func toggleFavorite(_ id: UUID) {
        update(id) {
            $0.favorite = !($0.favorite ?? false)
            if $0.favorite == true { $0.pinned = true; $0.homeURL = $0.homeURL ?? $0.url; $0.pinnedTitle = $0.pinnedTitle ?? $0.title }
        }
    }
    func removeFromSidebar(_ id: UUID) {
        update(id) { $0.pinned = false; $0.favorite = nil }; close(id)
    }
    func move(_ id: UUID, to destination: UUID) {
        guard let source = session.spaces[spaceIndex].tabs.first(where: { $0.id == id }), let d = session.spaces.firstIndex(where: { $0.id == destination }), d != spaceIndex else { return }
        session.spaces[d].tabs.append(source)
        session.close(id, in: space.id)
        if splitID == id || splitID == selectedID { splitID = nil }; save()
    }
    func showCommand(new: Bool = false) {
        commandOpensNewTab = new
        command = new ? "" : (selectedTab?.url ?? ""); commandVisible = true
    }
    func navigate(_ input: String) {
        guard let url = Address.resolve(input) else { return }
        commandVisible = false
        let id = commandOpensNewTab && selectedTab?.url.isEmpty != true ? newTab() : (focusedID ?? newTab())
        commandOpensNewTab = false
        update(id) { $0.url = url.absoluteString; $0.title = url.host ?? "Page" }
        view(for: id).load(URLRequest(url: url))
    }
    func update(_ id: UUID, change: (inout BrowserCore.Tab) -> Void) {
        for s in session.spaces.indices {
            if let t = session.spaces[s].tabs.firstIndex(where: { $0.id == id }) {
                change(&session.spaces[s].tabs[t]); save(); return
            }
        }
    }
    func tab(_ id: UUID) -> BrowserCore.Tab? { session.spaces.flatMap(\.tabs).first { $0.id == id } }
    func view(for id: UUID, configuration: WKWebViewConfiguration? = nil) -> WKWebView {
        accessOrder.removeAll { $0 == id }; accessOrder.append(id)
        if let existing = views[id] { return existing }
        let config = configuration ?? WKWebViewConfiguration()
        if let privateDataStore { config.websiteDataStore = privateDataStore }
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let web = WKWebView(frame: .zero, configuration: config)
        web.allowsBackForwardNavigationGestures = true
        web.isInspectable = false
        web.navigationDelegate = self; web.uiDelegate = self
        views[id] = web
        observations[id] = [
            web.observe(\.title, options: [.new]) { [weak self] web, _ in
                Task { @MainActor in self?.update(id) {
                        $0.title = web.title ?? web.url?.host ?? "Page"
                        if $0.pinned && ($0.pinnedTitle == nil || $0.pinnedTitle == web.url?.host) { $0.pinnedTitle = $0.title }
                    } }
            },
            web.observe(\.url, options: [.new]) { [weak self] web, _ in
                Task { @MainActor in if let url = web.url { self?.update(id) { $0.url = url.absoluteString } } }
            },
            web.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.revision += 1 } },
            web.observe(\.isLoading, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.revision += 1 } }
        ]
        if let value = tab(id)?.url, !value.isEmpty, let url = URL(string: value) { web.load(URLRequest(url: url)) }
        // Keep active and split panes alive; suspended tabs retain their last URL, but lose in-memory page state.
        while preferences.suspendTabs && views.count > 6, let victim = accessOrder.first(where: { $0 != id && $0 != selectedID && $0 != splitID && views[$0]?.isLoading == false }) {
            discardView(victim)
        }
        return web
    }
    func toggleSplit() {
        if splitID != nil { splitID = nil; return }
        splitID = space.tabs.first(where: { $0.id != selectedID && !$0.url.isEmpty })?.id
        if splitID == nil { message = "Open a second website, then choose Split View." }
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        guard ["https", "http", "about", "blob", "data"].contains(url.scheme?.lowercased() ?? "") else {
            decisionHandler(.cancel); message = "This prototype only opens web links (http and https)."; return
        }
        if action.navigationType == .linkActivated && action.modifierFlags.contains(.shift) && ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            decisionHandler(.cancel); openPeek(url); return
        }
        decisionHandler(action.shouldPerformDownload ? .download : .allow)
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(response.canShowMIMEType ? .allow : .download)
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = URL(fileURLWithPath: suggestedFilename).lastPathComponent
        panel.begin { [weak self] result in
            guard let self, result == .OK, let url = panel.url else { completionHandler(nil); return }
            let item = DownloadItem(name: url.lastPathComponent, status: "Downloading…")
            self.downloads.insert(item, at: 0); self.downloadIDs[ObjectIdentifier(download)] = item.id
            completionHandler(url)
        }
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) { updateDownload(download, status: "Failed: \(error.localizedDescription)"); message = "Download failed: \(error.localizedDescription)" }
    func downloadDidFinish(_ download: WKDownload) { updateDownload(download, status: "Finished"); message = "Download finished." }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { message = error.localizedDescription }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { message = "This page stopped responding. Use Reload to try again." }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let id = newTab()
        let popup = view(for: id, configuration: configuration)
        return popup
    }
    func webViewDidClose(_ webView: WKWebView) { if webView === peekView { closePeek(); return }; if let id = views.first(where: { $0.value === webView })?.key { close(id) } }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert(); alert.messageText = frame.request.url?.host ?? "Website"; alert.informativeText = message; alert.runModal(); completionHandler()
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert(); alert.messageText = frame.request.url?.host ?? "Website"; alert.informativeText = message
        alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Cancel"); completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert(); alert.messageText = prompt
        let field = NSTextField(string: defaultText ?? ""); field.frame = NSRect(x: 0, y: 0, width: 280, height: 24); alert.accessoryView = field
        alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Cancel"); completionHandler(alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
    }
}
