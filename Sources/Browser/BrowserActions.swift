import AppKit
import SwiftUI
import WebKit
import BrowserCore
import UniformTypeIdentifiers

struct DownloadItem: Identifiable {
    let id = UUID()
    let name: String
    var status: String
}

extension BrowserStore {
    func findNext(backwards: Bool = false) {
        guard let web = currentView, !findText.isEmpty else { findResult = ""; return }
        let config = WKFindConfiguration(); config.backwards = backwards; config.wraps = true; config.caseSensitive = false
        web.find(findText, configuration: config) { [weak self] result in self?.findResult = result.matchFound ? "" : "No matches" }
    }
    func zoom(_ amount: Double) { if let web = currentView { web.pageZoom = min(3, max(0.5, web.pageZoom + amount)) } }
    func addBookmark() {
        guard !isPrivate, let web = currentView, let url = web.url?.absoluteString else {
            if isPrivate { message = "Bookmarks are not saved from private windows." }; return
        }
        library.bookmark(title: web.title ?? url, url: url); save(); message = "Bookmark saved."
    }
    func reopenClosed() {
        guard var tab = library.closedTabs.first else { return }
        library.closedTabs.removeFirst(); tab.id = UUID(); tab.lastAccessed = Date()
        session.spaces[spaceIndex].tabs.append(tab); select(tab.id)
    }
    func restoreArchived(_ id: UUID) {
        guard let i = library.archive.firstIndex(where: { $0.id == id }) else { return }
        var tab = library.archive.remove(at: i); tab.id = UUID(); tab.lastAccessed = Date()
        session.spaces[spaceIndex].tabs.append(tab); select(tab.id)
    }
    func setFolder(_ id: UUID) {
        let alert = NSAlert(); alert.messageText = "Pinned tab folder"; alert.informativeText = "Choose a folder name. Leave it empty to remove the tab from its folder."
        let field = NSTextField(string: tab(id)?.folder ?? ""); field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel"); alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            update(id) { $0.folder = name.isEmpty ? nil : name; if !name.isEmpty { $0.pinned = true } }
        }
    }
    func archiveOldTabs() {
        guard !isPrivate, preferences.archiveAfterDays > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(preferences.archiveAfterDays) * 86400)
        var protected = Set(session.spaces.compactMap(\.selected))
        if let splitID { protected.insert(splitID) }
        let archived = session.archiveInactive(before: cutoff, excluding: protected)
        for tab in archived { discardView(tab.id) }
        library.archive.insert(contentsOf: archived, at: 0)
        save()
    }
    func updateDownload(_ download: WKDownload, status: String) {
        if let id = downloadIDs.removeValue(forKey: ObjectIdentifier(download)), let i = downloads.firstIndex(where: { $0.id == id }) { downloads[i].status = status }
    }
    func importLegacySession() {
        guard !isPrivate, savingEnabled else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        panel.message = "Choose session.json from the first Browser prototype. Imported tabs are added as new Spaces."
        panel.begin { [weak self] result in
            guard let self, result == .OK, let url = panel.url else { return }
            do {
                let imported = try JSONDecoder().decode(Session.self, from: Data(contentsOf: url))
                for source in imported.spaces {
                    var tabs = source.tabs
                    for i in tabs.indices { tabs[i].id = UUID() }
                    self.session.spaces.append(Space(name: "Imported \(source.name)", tabs: tabs.isEmpty ? [BrowserCore.Tab()] : tabs))
                }
                self.repairSession(); self.save(); self.message = "Imported preview tabs. The original JSON file was kept; it contains unencrypted URLs."
            } catch { self.message = "Couldn’t import this session: \(error.localizedDescription)" }
        }
    }
    func clearHistory() { library.history.removeAll(); library.closedTabs.removeAll(); library.archive.removeAll(); save() }
    func clearWebsiteData() {
        let alert = NSAlert(); alert.messageText = "Clear website data and history?"
        alert.informativeText = "This signs you out of websites and closes this window’s tabs. Bookmarks are kept. Downloaded files are kept."
        alert.addButton(withTitle: "Clear Data"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        clearingData = true
        for id in Array(views.keys) { discardView(id) }
        session = Session(); splitID = nil; clearHistory(); flush()
        let dataStore = privateDataStore ?? WKWebsiteDataStore.default()
        dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { [weak self] in
            self?.clearingData = false; self?.message = "Website data and history cleared. Bookmarks and downloaded files were kept."
        }
    }
    func discardView(_ id: UUID) {
        guard let web = views.removeValue(forKey: id) else { return }
        web.navigationDelegate = nil; web.uiDelegate = nil; web.stopLoading()
        observations.removeValue(forKey: id); accessOrder.removeAll { $0 == id }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard views.values.contains(where: { $0 === webView }) else { return }
        if !isPrivate && !clearingData, let url = webView.url?.absoluteString {
            library.record(title: webView.title ?? url, url: url); save()
        }
        revision += 1
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { revision += 1 }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { message = error.localizedDescription }; revision += 1
    }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = parameters.allowsDirectories; panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.begin { result in completionHandler(result == .OK ? panel.urls : nil) }
    }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        // Prompt only for the focused tab's secure top-level origin, never grant in the background.
        guard webView === currentView, origin.protocol == "https", origin.host == webView.url?.host,
              (origin.port == 0 ? 443 : origin.port) == (webView.url?.port ?? 443),
              frame.securityOrigin.host == origin.host, frame.securityOrigin.protocol == origin.protocol,
              frame.securityOrigin.port == origin.port else { decisionHandler(.deny); return }
        let resource = type == .camera ? "camera" : (type == .microphone ? "microphone" : "camera and microphone")
        let originLabel = "https://" + origin.host + (origin.port == 0 || origin.port == 443 ? "" : ":\(origin.port)")
        let alert = NSAlert(); alert.messageText = "Allow \(originLabel) to use your \(resource)?"
        alert.informativeText = "Only allow access if you trust this website. macOS also controls Alcove’s device access. This choice applies to this request."
        alert.addButton(withTitle: "Don’t Allow"); alert.addButton(withTitle: "Allow Once")
        guard let window = webView.window else { decisionHandler(.deny); return }
        let requestedURL = webView.url
        alert.beginSheetModal(for: window) { [weak self, weak webView] result in
            let stillCurrent = webView != nil && webView === self?.currentView && webView?.url == requestedURL
            decisionHandler(result == .alertSecondButtonReturn && stillCurrent ? .grant : .deny)
        }
    }
}
