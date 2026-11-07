import AppKit
import SwiftUI
import WebKit
import BrowserCore

@MainActor
final class BrowserStore: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    @Published var session = Session()
    @Published var commandVisible = false
    @Published var command = ""
    @Published var sidebarVisible = true
    @Published var splitID: UUID?
    @Published var message: String?
    @Published var revision = 0
    private var views: [UUID: WKWebView] = [:]
    private var accessOrder: [UUID] = []
    private var observations: [UUID: [NSKeyValueObservation]] = [:]
    private var saveTask: Task<Void, Never>?
    private let sessionURL: URL
    var spaceIndex: Int { session.spaces.firstIndex { $0.id == session.selectedSpace } ?? 0 }
    var space: Space { session.spaces[spaceIndex] }
    var selectedID: UUID? { space.selected }
    var selectedTab: BrowserCore.Tab? { space.tabs.first { $0.id == selectedID } }
    var currentView: WKWebView? { selectedID.flatMap { views[$0] } }

    override init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OpenBrowser", isDirectory: true)
        sessionURL = root.appendingPathComponent("session.json")
        super.init()
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: sessionURL.path) {
                let loaded = try JSONDecoder().decode(Session.self, from: Data(contentsOf: sessionURL))
                if !loaded.spaces.isEmpty && loaded.spaces.allSatisfy({ !$0.tabs.isEmpty }) {
                    session = loaded
                    if !session.spaces.contains(where: { $0.id == session.selectedSpace }) { session.selectedSpace = session.spaces[0].id }
                    for i in session.spaces.indices {
                        if !session.spaces[i].tabs.contains(where: { $0.id == session.spaces[i].selected }) { session.spaces[i].selected = session.spaces[i].tabs.first?.id }
                    }
                }
            }
        } catch { message = "Couldn’t restore the saved session: \(error.localizedDescription)" }
    }
    func save() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }
    func flush() {
        do { try JSONEncoder().encode(session).write(to: sessionURL, options: .atomic) }
        catch { message = "Couldn’t save your session: \(error.localizedDescription)" }
    }
    func select(_ id: UUID) {
        session.spaces[spaceIndex].selected = id
        if splitID == id { splitID = nil }
        save()
    }
    func selectSpace(_ id: UUID) { splitID = nil; session.selectedSpace = id; save() }
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
        if splitID == id { splitID = nil }
        views[id]?.stopLoading(); views.removeValue(forKey: id); observations.removeValue(forKey: id)
        accessOrder.removeAll { $0 == id }
        session.close(id, in: space.id)
        if splitID == selectedID { splitID = nil }
        save()
    }
    func togglePin(_ id: UUID) {
        guard let i = session.spaces[spaceIndex].tabs.firstIndex(where: { $0.id == id }) else { return }
        session.spaces[spaceIndex].tabs[i].pinned.toggle(); save()
    }
    func move(_ id: UUID, to destination: UUID) {
        guard let source = session.spaces[spaceIndex].tabs.first(where: { $0.id == id }), let d = session.spaces.firstIndex(where: { $0.id == destination }), d != spaceIndex else { return }
        session.spaces[d].tabs.append(source)
        session.close(id, in: space.id)
        if splitID == id || splitID == selectedID { splitID = nil }; save()
    }
    func showCommand(new: Bool = false) {
        if new { _ = newTab() }
        command = selectedTab?.url ?? ""; commandVisible = true
    }
    func navigate(_ input: String) {
        guard let url = Address.resolve(input) else { return }
        commandVisible = false
        let id = selectedID ?? newTab()
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
        let web = WKWebView(frame: .zero, configuration: config)
        web.allowsBackForwardNavigationGestures = true
        web.isInspectable = true
        web.navigationDelegate = self; web.uiDelegate = self
        views[id] = web
        observations[id] = [
            web.observe(\.title, options: [.new]) { [weak self] web, _ in
                Task { @MainActor in self?.update(id) { $0.title = web.title ?? web.url?.host ?? "Page" } }
            },
            web.observe(\.url, options: [.new]) { [weak self] web, _ in
                Task { @MainActor in if let url = web.url { self?.update(id) { $0.url = url.absoluteString } } }
            },
            web.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.revision += 1 } },
            web.observe(\.isLoading, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.revision += 1 } }
        ]
        if let value = tab(id)?.url, !value.isEmpty, let url = URL(string: value) { web.load(URLRequest(url: url)) }
        // Keep active and split panes alive; suspended tabs retain their last URL, but lose in-memory page state.
        while views.count > 6, let victim = accessOrder.first(where: { $0 != id && $0 != selectedID && $0 != splitID && views[$0]?.isLoading == false }) {
            views[victim]?.stopLoading(); views.removeValue(forKey: victim); observations.removeValue(forKey: victim)
            accessOrder.removeAll { $0 == victim }
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
        decisionHandler(action.shouldPerformDownload ? .download : .allow)
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(response.canShowMIMEType ? .allow : .download)
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = suggestedFilename
        panel.begin { result in completionHandler(result == .OK ? panel.url : nil) }
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) { message = "Download failed: \(error.localizedDescription)" }
    func downloadDidFinish(_ download: WKDownload) { message = "Download finished." }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { message = error.localizedDescription }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { message = "This page stopped responding. Use Reload to try again." }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let id = newTab()
        let popup = view(for: id, configuration: configuration)
        return popup
    }
    func webViewDidClose(_ webView: WKWebView) { if let id = views.first(where: { $0.value === webView })?.key { close(id) } }
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
