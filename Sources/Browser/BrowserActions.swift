import AppKit
import SwiftUI
import WebKit
import BrowserCore
import UniformTypeIdentifiers
import CryptoKit

struct DownloadItem: Identifiable {
    let id = UUID()
    let name: String
    var status: String
}

extension BrowserStore {
    @discardableResult func unlockLocalData(keyProvider: (() throws -> SymmetricKey)? = nil, persist: @escaping (MetadataStore, BrowserDocument) throws -> Void = { try $0.save($1) }) -> Bool {
        guard !isPrivate, !savingEnabled, !unlocking else { return false }
        unlocking = true
        let url = sessionURL
        Task {
            defer { unlocking = false }
            do {
                let key = try await Task.detached { if let keyProvider { return try keyProvider() }; return try MetadataKey.load(createIfMissing: !FileManager.default.fileExists(atPath: url.path), allowInteraction: true) }.value
                guard !isShuttingDown else { return }
                let storage = MetadataStore(url: url, key: key)
                let pending = makeDocument()
                var document = try storage.load(BrowserDocument.self)
                var migratedLegacyURL: URL?
                if document == nil {
                    let legacyURL = url.deletingLastPathComponent().appendingPathComponent("session.json")
                    if FileManager.default.fileExists(atPath: legacyURL.path) {
                        let legacy = try JSONDecoder().decode(Session.self, from: Data(contentsOf: legacyURL))
                        var migratedPreferences = Preferences(); migratedPreferences.onboardingCompleted = true
                        document = BrowserDocument(session: legacy, preferences: migratedPreferences)
                        migratedLegacyURL = legacyURL
                    }
                }
                var candidate = document ?? pending
                if document != nil {
                    candidate.repairProfiles()
                    for var space in pending.session.spaces {
                        if let index = candidate.session.spaces.firstIndex(where: { $0.id == space.id && $0.effectiveProfileID == space.effectiveProfileID }) {
                            candidate.session.spaces[index] = space
                            if pending.session.selectedSpace == space.id { candidate.session.selectedSpace = space.id }
                        } else {
                            guard space.tabs.contains(where: { !$0.url.isEmpty }) else { continue }
                            let oldID = space.id; let oldSelected = space.selected
                            if candidate.session.spaces.contains(where: { $0.id == space.id }) { space.id = UUID() }
                            space.name = "Unsaved " + space.name
                            for i in space.tabs.indices where candidate.session.spaces.flatMap(\.tabs).contains(where: { $0.id == space.tabs[i].id }) {
                                let previousID = space.tabs[i].id; space.tabs[i].id = UUID()
                                if oldSelected == previousID { space.selected = space.tabs[i].id }
                            }
                            candidate.session.spaces.append(space)
                            if pending.session.selectedSpace == oldID { candidate.session.selectedSpace = space.id }
                        }
                    }
                    candidate.profiles = (candidate.profiles ?? [.defaultProfile]) + (pending.profiles ?? []).filter { profile in !(candidate.profiles ?? [.defaultProfile]).contains(where: { $0.id == profile.id }) }
                    for entry in pending.profileLibraries ?? [ProfileLibrary(profileID: BrowserProfile.defaultID, library: pending.library)] {
                        var value = candidate.library(for: entry.profileID)
                        if hasSavedDocument && persistedProfileIDs.contains(entry.profileID) { value = entry.library }
                        else { value.mergePreservingRecords(entry.library) }
                        candidate.setLibrary(value, for: entry.profileID)
                    }
                    if hasSavedDocument { candidate.preferences = pending.preferences }
                    if candidate.preferences.onboardingCompleted == nil { candidate.preferences.onboardingCompleted = true }
                }
                candidate.repairProfiles(); candidate.session = Self.repairedSession(candidate.session)
                // Commit disk state before publishing a restore. Failed retries leave live tabs intact.
                try persist(storage, candidate)
                persistedProfileIDs = Set((candidate.profiles ?? []).map(\.id))
                if document != nil {
                    for id in Array(views.keys) {
                        let owner = candidate.session.spaces.first(where: { $0.tabs.contains(where: { $0.id == id }) })
                        let tab = owner?.tabs.first(where: { $0.id == id })
                        if owner?.effectiveProfileID != viewProfileIDs[id] || tab?.url != self.tab(id)?.url { discardView(id) }
                    }
                    splitID = nil; activePaneID = nil; closePeek()
                }
                applyDocument(candidate)
                hasSavedDocument = true; vault = storage; savingEnabled = true
                onboardingVisible = OnboardingPolicy.shouldPresent(isPrivate: isPrivate, savingEnabled: savingEnabled, completed: preferences.onboardingCompleted, hasSavedDocument: hasSavedDocument)
                if let migratedLegacyURL {
                    do { try FileManager.default.removeItem(at: migratedLegacyURL) }
                    catch { message = "Your tabs were encrypted and restored, but the original legacy JSON could not be removed. It still contains readable URLs."; return }
                }
                automaticUpdatesDidChange?()
                message = "Local data unlocked. Existing saved tabs and this session’s unsaved tabs were kept."
            } catch { message = "Local data remains locked and unchanged. \(error.localizedDescription)" }
        }
        return true
    }
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
            update(id) { $0.folder = name.isEmpty ? nil : name; if !name.isEmpty { $0.pinned = true; $0.homeURL = $0.homeURL ?? $0.url; $0.pinnedTitle = $0.pinnedTitle ?? $0.title } }
        }
    }
    func archiveOldTabs() {
        guard !isPrivate, preferences.archiveAfterDays > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(preferences.archiveAfterDays) * 86400)
        var protected = Set(session.spaces.compactMap(\.selected))
        if let splitID { protected.insert(splitID) }
        var profileBeforeArchive: [UUID: UUID] = [:]
        for space in session.spaces { for tab in space.tabs { profileBeforeArchive[tab.id] = space.effectiveProfileID } }
        let archived = session.archiveInactive(before: cutoff, excluding: protected)
        for tab in archived {
            let owner = viewProfileIDs[tab.id] ?? profileBeforeArchive[tab.id] ?? BrowserProfile.defaultID
            mutateLibrary(for: owner) { $0.archive.insert(tab, at: 0) }; discardView(tab.id)
        }
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
                    var space = Space(name: "Imported \(source.name)", tabs: tabs.isEmpty ? [BrowserCore.Tab()] : tabs)
                    space.profileID = self.activeProfileID; self.session.spaces.append(space)
                }
                self.repairSession(); self.save(); self.message = "Imported preview tabs. The original JSON file was kept; it contains unencrypted URLs."
            } catch { self.message = "Couldn’t import this session: \(error.localizedDescription)" }
        }
    }
    func clearHistory() { library.history.removeAll(); library.closedTabs.removeAll(); library.archive.removeAll(); save() }
    func clearWebsiteData() {
        let profileID = activeProfileID
        let alert = NSAlert(); alert.messageText = "Clear website data and history?"
        alert.informativeText = "This signs you out and closes tabs, pins and Favorites in \(isPrivate ? "this private window" : activeProfile.name + " profile"). Other profiles, bookmarks and downloaded files are kept."
        alert.addButton(withTitle: "Clear Data"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { do { try await clearProfileData(profileID) } catch { message = error.localizedDescription } }
    }
    func discardView(_ id: UUID) {
        guard let web = views.removeValue(forKey: id) else { return }
        closingPages.removeAll { $0.webView == nil }
        if let profile = viewProfileIDs[id] { closingPages.append(ClosingProfilePage(web, profileID: profile)) }
        web.navigationDelegate = nil; web.uiDelegate = nil; web.stopLoading()
        web.loadHTMLString("", baseURL: nil); web.removeFromSuperview()
        observations.removeValue(forKey: id); accessOrder.removeAll { $0 == id }
        viewProfileIDs.removeValue(forKey: id); siteIcons.removeValue(forKey: id)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard views.values.contains(where: { $0 === webView }) else { return }
        loadSiteIcon(webView)
        if !isPrivate, let url = webView.url?.absoluteString, let owner = profileID(for: webView), clearingProfileID != owner {
            mutateLibrary(for: owner) { $0.record(title: webView.title ?? url, url: url) }; save()
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
