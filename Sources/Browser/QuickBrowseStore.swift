import AppKit
import WebKit
import BrowserCore

enum QuickBrowseError: LocalizedError {
    case missing, invalidAddress, consentRequired
    var errorDescription: String? {
        switch self {
        case .missing: return "This Quick Browse page is no longer open."
        case .invalidAddress: return "Enter a web address or search query. Only http and https links can open in Quick Browse."
        case .consentRequired: return "Changing profiles reloads this page. Confirm the move first; unsaved forms cannot be transferred."
        }
    }
}

private struct QuickArchiveSnapshot {
    let id: UUID
    let profileID: UUID
    let url: String
    let lastActiveAt: Date
    let viewID: ObjectIdentifier?
    let peekID: ObjectIdentifier?
}
private struct QuickArchiveMediaRequest {
    let snapshot: QuickArchiveSnapshot
    weak var web: WKWebView?
}

extension BrowserStore {
    func effectiveQuickPage(_ value: QuickPage) -> QuickPage {
        var page = value
        if let interaction = quickActivityTimes[page.id], interaction > page.lastActiveAt { page.lastActiveAt = interaction }
        return page
    }
    var allQuickPages: [QuickPage] { profileLibraries.flatMap { $0.library.quickPages ?? [] }.map(effectiveQuickPage) }
    func quickPages(for profileID: UUID) -> [QuickPage] { (library(for: isPrivate ? BrowserProfile.defaultID : profileID).quickPages ?? []).map(effectiveQuickPage) }
    func pruneQuickActivity() {
        let ids = Set(profileLibraries.flatMap { $0.library.quickPages ?? [] }.map(\.id))
        quickActivityTimes = quickActivityTimes.filter { ids.contains($0.key) }
        if let id = focusedQuickPageID, !ids.contains(id) { focusedQuickPageID = nil }
        if isPrivate && ids.isEmpty { archiveTimer?.invalidate(); archiveTimer = nil }
    }
    func quickPage(_ id: UUID) -> QuickPage? { allQuickPages.first { $0.id == id } }
    func quickProfileID(_ id: UUID) -> UUID? {
        guard let entry = profileLibraries.first(where: { $0.library.quickPages?.contains(where: { $0.id == id }) == true }) else { return nil }
        return isPrivate ? BrowserProfile.defaultID : entry.profileID
    }
    func quickContext(for web: WKWebView) -> (id: UUID, profileID: UUID, intendedSpaceID: UUID?)? {
        if web === peekView, let parent = peekParentQuickID, let profile = peekProfileID,
           quickProfileID(parent) == profile { return (parent, profile, peekSpaceID) }
        guard let id = views.first(where: { $0.value === web })?.key, let profile = quickProfileID(id), let page = quickPage(id) else { return nil }
        return (id, profile, page.intendedSpaceID)
    }
    func requireQuickProfile(_ profileID: UUID) throws {
        guard !isShuttingDown else { throw CancellationError() }
        if isPrivate { guard !profileUnavailable(BrowserProfile.defaultID) else { throw ProfileError.pending }; return }
        guard profiles.contains(where: { $0.id == profileID }) else { throw ProfileError.missing }
        guard !profileUnavailable(profileID) else { throw ProfileError.pending }
    }
    func commitQuickDocument(_ document: BrowserDocument, discarding ids: [UUID] = [], beforePublish: (() -> Void)? = nil) throws {
        guard !isShuttingDown else { throw CancellationError() }
        if isPrivate {
            for id in ids { discardView(id) }
            beforePublish?()
            session = Self.repairedSession(document.session); profileLibraries = document.profileLibraries ?? []
            preferences = document.preferences; pruneQuickActivity(); quickPagesDidChange?()
        } else { try commitProfileDocument(document, discarding: ids, beforePublish: beforePublish) }
    }
    @discardableResult func openQuickPage(url: URL? = nil, profileID: UUID? = nil, intendedSpaceID: UUID? = nil, configuration: WKWebViewConfiguration? = nil) throws -> UUID {
        let owner = isPrivate ? BrowserProfile.defaultID : (profileID ?? activeProfileID)
        try requireQuickProfile(owner)
        if let url {
            guard QuickBrowseRouting.host(for: url) != nil else { throw QuickBrowseError.invalidAddress }
            if let existing = quickPages(for: owner).first(where: { $0.tab.url == url.absoluteString || $0.requestedURL == url.absoluteString }) {
                touchQuickPage(existing.id); quickPageRequested?(existing.id); return existing.id
            }
        }
        let target = session.spaces.first(where: { $0.id == intendedSpaceID && (isPrivate || $0.effectiveProfileID == owner) })?.id
            ?? (activeProfileID == owner ? space.id : session.spaces.first(where: { $0.effectiveProfileID == owner })?.id)
        let page = QuickPage(tab: BrowserCore.Tab(title: url?.host ?? "New Quick Browse", url: url?.absoluteString ?? ""), intendedSpaceID: target)
        var candidate = makeDocument(); var records = candidate.library(for: owner)
        records.quickPages = (records.quickPages ?? []) + [page]; candidate.setLibrary(records, for: owner)
        try commitQuickDocument(candidate, beforePublish: {
            if let configuration {
                configuration.websiteDataStore = self.websiteDataStore(forProfile: owner)
                configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
                self.registerView(WKWebView(frame: .zero, configuration: configuration), for: page.id, profile: owner)
            }
        })
        startArchiveTimer(); quickPageRequested?(page.id); return page.id
    }
    func touchQuickPage(_ id: UUID, now: Date = Date()) {
        guard let page = quickPage(id) else { return }
        quickActivityTimes[id] = max(page.lastActiveAt, now)
        save()
    }
    func navigateQuickPage(_ id: UUID, input: String) throws {
        guard let owner = quickProfileID(id) else { throw QuickBrowseError.missing }
        try requireQuickProfile(owner)
        guard let url = Address.resolve(input), QuickBrowseRouting.host(for: url) != nil else { throw QuickBrowseError.invalidAddress }
        let existing = views[id]
        mutateLibrary(for: owner) { records in
            guard let index = records.quickPages?.firstIndex(where: { $0.id == id }) else { return }
            records.quickPages?[index].tab.url = url.absoluteString; records.quickPages?[index].tab.title = url.host ?? "Page"
            records.quickPages?[index].requestedURL = url.absoluteString; records.quickPages?[index].lastActiveAt = Date()
        }
        save()
        if let existing { existing.load(URLRequest(url: url)) } else { _ = view(for: id) }
    }
    func archivedQuickTab(_ page: QuickPage) -> BrowserCore.Tab? {
        var tab = page.tab
        if URL(string: tab.url).flatMap({ QuickBrowseRouting.host(for: $0) }) == nil {
            guard let original = page.requestedURL, URL(string: original).flatMap({ QuickBrowseRouting.host(for: $0) }) != nil else { return nil }
            tab.url = original
        }
        tab.lastAccessed = page.lastActiveAt; tab.archiveSource = "quickBrowse"; tab.pinned = false; tab.favorite = nil; tab.folder = nil
        return tab
    }
    func closeQuickPage(_ id: UUID) throws {
        guard let owner = quickProfileID(id), let page = quickPage(id) else { return }
        try requireQuickProfile(owner)
        var candidate = makeDocument(); var records = candidate.library(for: owner)
        records.quickPages?.removeAll { $0.id == id }
        if let archived = archivedQuickTab(page) { records.archive.insert(archived, at: 0) }
        candidate.setLibrary(records, for: owner)
        try commitQuickDocument(candidate, discarding: [id], beforePublish: {
            if self.peekParentQuickID == id { self.closePeek() }
        })
        if focusedQuickPageID == id { focusedQuickPageID = nil }
    }
    @discardableResult func promoteQuickPage(_ id: UUID, to destination: UUID? = nil, allowProfileChange: Bool = false) throws -> UUID {
        guard let owner = quickProfileID(id), let page = quickPage(id) else { throw QuickBrowseError.missing }
        try requireQuickProfile(owner)
        var candidate = makeDocument()
        var index: Int
        if let destination {
            guard let found = candidate.session.spaces.firstIndex(where: { $0.id == destination }) else { throw ProfileError.missing }
            index = found
        } else if let found = candidate.session.spaces.firstIndex(where: { $0.id == page.intendedSpaceID && (isPrivate || $0.effectiveProfileID == owner) })
            ?? candidate.session.spaces.firstIndex(where: { isPrivate || $0.effectiveProfileID == owner }) { index = found }
        else {
            let name = profiles.first(where: { $0.id == owner })?.name ?? "Personal"
            var target = Space(name: name, tabs: []); target.profileID = owner; candidate.session.spaces.append(target); index = candidate.session.spaces.count - 1
        }
        let targetProfile = isPrivate ? BrowserProfile.defaultID : candidate.session.spaces[index].effectiveProfileID
        try requireQuickProfile(targetProfile)
        let crossing = owner != targetProfile
        guard !crossing || allowProfileChange else { throw QuickBrowseError.consentRequired }
        var records = candidate.library(for: owner); records.quickPages?.removeAll { $0.id == id }; candidate.setLibrary(records, for: owner)
        var tab = page.tab; tab.pinned = false; tab.favorite = nil; tab.folder = nil; tab.homeURL = nil; tab.pinnedTitle = nil; tab.archiveSource = nil; tab.lastAccessed = Date()
        var discard = crossing ? [id] : []
        if candidate.session.spaces[index].tabs.count == 1, let blank = candidate.session.spaces[index].tabs.first, blank.url.isEmpty && !blank.pinned {
            discard.append(blank.id); candidate.session.spaces[index].tabs = []
        }
        candidate.session.spaces[index].tabs.append(tab); candidate.session.spaces[index].selected = id
        let spaceID = candidate.session.spaces[index].id; candidate.session.selectedSpace = spaceID
        try commitQuickDocument(candidate, discarding: discard, beforePublish: {
            if !crossing { self.views[id]?.removeFromSuperview() }
            if self.peekParentQuickID == id {
                if crossing { self.closePeek() }
                else { self.peekParentQuickID = nil; self.peekSpaceID = spaceID }
            }
            self.splitID = nil; self.activePaneID = nil
        })
        if focusedQuickPageID == id { focusedQuickPageID = nil }
        return spaceID
    }
    func changeQuickProfile(_ id: UUID, to profileID: UUID, rememberHost: Bool = false, allowReload: Bool = false) throws {
        guard let owner = quickProfileID(id), var page = quickPage(id) else { throw QuickBrowseError.missing }
        if isPrivate && profileID != BrowserProfile.defaultID { throw ProfileError.privateMode }
        try requireQuickProfile(owner); try requireQuickProfile(profileID)
        let crossing = owner != profileID
        guard !crossing || allowReload else { throw QuickBrowseError.consentRequired }
        guard crossing || rememberHost else { return }
        var candidate = makeDocument()
        if crossing {
            var previous = candidate.library(for: owner); previous.quickPages?.removeAll { $0.id == id }; candidate.setLibrary(previous, for: owner)
            page.intendedSpaceID = session.spaces.first(where: { $0.effectiveProfileID == profileID })?.id; page.lastActiveAt = Date()
            var target = candidate.library(for: profileID); target.quickPages = (target.quickPages ?? []) + [page]; candidate.setLibrary(target, for: profileID)
        }
        if rememberHost, !isPrivate, let url = URL(string: page.tab.url), let host = QuickBrowseRouting.host(for: url) {
            var choices = candidate.preferences.quickDomainChoices ?? []; choices.removeAll { QuickBrowseRouting.normalizedHost($0.host) == host }
            choices.insert(QuickDomainChoice(host: host, profileID: profileID), at: 0); candidate.preferences.quickDomainChoices = choices
        }
        try commitQuickDocument(candidate, discarding: crossing ? [id] : [], beforePublish: {
            if crossing && self.peekParentQuickID == id { self.closePeek() }
        })
    }
    private func quickPeek(_ id: UUID) -> WKWebView? { peekParentQuickID == id ? peekView : nil }
    private func quickHasCapture(_ id: UUID) -> Bool {
        [views[id], quickPeek(id)].compactMap { $0 }.contains { $0.cameraCaptureState != .none || $0.microphoneCaptureState != .none }
    }
    private func matchesQuickArchive(_ item: QuickArchiveSnapshot, cutoff: Date) -> Bool {
        guard !isShuttingDown, !profileUnavailable(item.profileID), quickProfileID(item.id) == item.profileID,
              let page = quickPage(item.id), page.tab.url == item.url, page.lastActiveAt == item.lastActiveAt,
              page.lastActiveAt < cutoff, item.id != focusedQuickPageID,
              views[item.id]?.window?.isKeyWindow != true, views[item.id]?.window?.attachedSheet == nil,
              quickPeek(item.id)?.window?.attachedSheet == nil,
              views[item.id]?.isLoading != true, quickPeek(item.id)?.isLoading != true else { return false }
        return views[item.id].map(ObjectIdentifier.init) == item.viewID && quickPeek(item.id).map(ObjectIdentifier.init) == item.peekID
    }
    private func commitQuickArchive(_ snapshots: [QuickArchiveSnapshot], cutoff: Date, now: Date) {
        guard !isShuttingDown, isPrivate || savingEnabled, !profileDataOperationInProgress,
              QuickBrowsePolicy.archiveCutoff(hours: preferences.quickBrowseArchiveHours, now: now) == cutoff else { return }
        var selected: [UUID: [QuickPage]] = [:]
        for item in snapshots where matchesQuickArchive(item, cutoff: cutoff) {
            if quickHasCapture(item.id) { touchQuickPage(item.id, now: now); continue }
            if let page = quickPage(item.id) { selected[item.profileID, default: []].append(page) }
        }
        guard !selected.isEmpty else { return }
        // Build the candidate after every asynchronous WebKit reply, never from an old window snapshot.
        var candidate = makeDocument(); var expiredIDs: Set<UUID> = []
        for (owner, pages) in selected {
            let ids = Set(pages.map(\.id)); expiredIDs.formUnion(ids)
            var records = candidate.library(for: owner); records.quickPages?.removeAll { ids.contains($0.id) }
            for page in pages { if let archived = archivedQuickTab(page) { records.archive.insert(archived, at: 0) } }
            candidate.setLibrary(records, for: owner)
        }
        do {
            try commitQuickDocument(candidate, discarding: Array(expiredIDs), beforePublish: {
                if let parent = self.peekParentQuickID, expiredIDs.contains(parent) { self.closePeek() }
            })
        } catch { message = "Quick windows stayed open because their archive could not be saved. \(error.localizedDescription)" }
    }
    func archiveInactiveQuickPages(now: Date = Date()) {
        guard !isShuttingDown, isPrivate || savingEnabled, !profileDataOperationInProgress, quickArchiveProbeID == nil,
              let cutoff = QuickBrowsePolicy.archiveCutoff(hours: preferences.quickBrowseArchiveHours, now: now) else { return }
        var snapshots: [QuickArchiveSnapshot] = []; var requests: [QuickArchiveMediaRequest] = []
        let owners = isPrivate ? [BrowserProfile.defaultID] : profileLibraries.map(\.profileID)
        for owner in owners where !profileUnavailable(owner) {
            for page in quickPages(for: owner) where page.lastActiveAt < cutoff && page.id != focusedQuickPageID {
                guard views[page.id]?.window?.isKeyWindow != true, views[page.id]?.window?.attachedSheet == nil,
                      quickPeek(page.id)?.window?.attachedSheet == nil,
                      views[page.id]?.isLoading != true, quickPeek(page.id)?.isLoading != true else { continue }
                if quickHasCapture(page.id) { touchQuickPage(page.id, now: now); continue }
                let item = QuickArchiveSnapshot(id: page.id, profileID: owner, url: page.tab.url, lastActiveAt: page.lastActiveAt,
                                                viewID: views[page.id].map(ObjectIdentifier.init), peekID: quickPeek(page.id).map(ObjectIdentifier.init))
                snapshots.append(item)
                for web in [views[page.id], quickPeek(page.id)].compactMap({ $0 }) { requests.append(QuickArchiveMediaRequest(snapshot: item, web: web)) }
            }
        }
        guard !snapshots.isEmpty else { return }
        guard !requests.isEmpty else { commitQuickArchive(snapshots, cutoff: cutoff, now: now); return }
        let token = UUID(); quickArchiveProbeID = token
        var outstanding: [UUID: Int] = [:]; var blocked: Set<UUID> = []
        for request in requests { outstanding[request.snapshot.id, default: 0] += 1 }
        let finish: @MainActor () -> Void = { [weak self] in
            guard let self, self.quickArchiveProbeID == token else { return }
            self.quickArchiveProbeID = nil
            let ready = snapshots.filter { !blocked.contains($0.id) && outstanding[$0.id, default: 0] == 0 }
            self.commitQuickArchive(ready, cutoff: cutoff, now: now)
        }
        for request in requests {
            let item = request.snapshot
            guard let web = request.web else { blocked.insert(item.id); outstanding[item.id, default: 0] -= 1; continue }
            web.requestMediaPlaybackState { [weak self, weak web] state in
                guard let self, self.quickArchiveProbeID == token else { return }
                if web == nil || !self.matchesQuickArchive(item, cutoff: cutoff) || !(self.isPrivate || self.savingEnabled) {
                    blocked.insert(item.id)
                } else if state == .playing || self.quickHasCapture(item.id) {
                    blocked.insert(item.id); self.touchQuickPage(item.id, now: now)
                }
                outstanding[item.id, default: 0] -= 1
                if outstanding.values.allSatisfy({ $0 == 0 }) { finish() }
            }
        }
        if outstanding.values.allSatisfy({ $0 == 0 }) { finish() }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            finish() // Unanswered live pages are retained; later timer ticks may try again.
        }
    }
    @discardableResult func restoreQuickArchive(_ id: UUID, profileID: UUID) throws -> UUID {
        let owner = isPrivate ? BrowserProfile.defaultID : profileID; try requireQuickProfile(owner)
        var candidate = makeDocument(); var records = candidate.library(for: owner)
        guard var tab = records.archive.first(where: { $0.id == id }), let url = URL(string: tab.url), QuickBrowseRouting.host(for: url) != nil else { throw QuickBrowseError.invalidAddress }
        let existing = records.quickPages?.first(where: { $0.tab.url == tab.url || $0.requestedURL == tab.url })
        tab.id = UUID(); tab.pinned = false; tab.favorite = nil; tab.archiveSource = nil; tab.homeURL = nil; tab.pinnedTitle = nil; tab.folder = nil
        let page = QuickPage(tab: tab, intendedSpaceID: session.spaces.first(where: { isPrivate || $0.effectiveProfileID == owner })?.id)
        records.archive.removeAll { $0.id == id }
        if existing == nil { records.quickPages = (records.quickPages ?? []) + [page] }
        candidate.setLibrary(records, for: owner); try commitQuickDocument(candidate)
        let result = existing?.id ?? page.id; startArchiveTimer(); quickPageRequested?(result); return result
    }
}
