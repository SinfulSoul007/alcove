import BrowserCore
import Foundation
import WebKit

@MainActor
private struct CleanupPage {
    weak var store: BrowserStore?
    weak var web: WKWebView?
    let document: NSUUID
    let presentation: NSUUID

    init(store: BrowserStore, web: WKWebView) {
        self.store = store
        self.web = web
        document = store.documentIdentity(for: web)
        presentation = store.presentationIdentity(for: web)
    }

    func matchesAvailableDocument(in owner: BrowserStore?, tabID: UUID) -> Bool {
        guard let store, let web, store === owner,
              store.views[tabID] === web, store.documentIdentity(for: web) === document,
              store.presentationIdentity(for: web) === presentation else { return false }
        return !web.isLoading && web.cameraCaptureState == .none && web.microphoneCaptureState == .none
            && web.window?.attachedSheet == nil
    }
}

private struct CleanupTab {
    let tab: BrowserCore.Tab
    let spaceID: UUID
    let profileID: UUID
    let page: CleanupPage?
}

extension BrowserStore {
    func scheduleTabSuspension(afterOpening id: UUID, retaining sourceID: UUID?) {
        guard canSuspendBackgroundTabs else { return }
        var exclusions: Set<UUID> = [id]
        if let sourceID { exclusions.insert(sourceID) }
        if pendingTabSuspensionExclusions != nil {
            pendingTabSuspensionExclusions?.formUnion(exclusions)
            return
        }
        pendingTabSuspensionExclusions = exclusions
        // A sidebar render can construct a pane. Defer eviction until after that render returns.
        Task { @MainActor [weak self] in self?.checkBackgroundTabSuspension() }
    }

    private var canSuspendBackgroundTabs: Bool {
        preferences.suspendTabs && views.count > 6 && canCleanUpTabs
    }

    private var suspensionExclusions: Set<UUID> {
        var protected = pendingTabSuspensionExclusions ?? []
        protected.formUnion(visiblePaneIDs)
        protected.formUnion(splitGroups.flatMap(\.tabIDs))
        if let windowGroup { protected.formUnion(windowGroup.protectedPaneIDs) }
        return protected
    }

    private func hasSuspendableProfile(_ id: UUID) -> Bool {
        guard quickProfileID(id) == nil, let profile = profileID(for: id),
              viewProfileIDs[id] == profile else { return false }
        return !profileUnavailable(profile)
    }

    private func checkBackgroundTabSuspension() {
        guard canSuspendBackgroundTabs else { pendingTabSuspensionExclusions = nil; return }
        let excluded = suspensionExclusions
        var pages: [(id: UUID, snapshot: CleanupPage)] = []
        var requests: [(id: UUID, web: WKWebView)] = []
        for id in accessOrder where !excluded.contains(id) {
            guard let web = views[id], hasSuspendableProfile(id) else { continue }
            let snapshot = CleanupPage(store: self, web: web)
            guard snapshot.matchesAvailableDocument(in: self, tabID: id) else { continue }
            pages.append((id, snapshot))
            requests.append((id, web))
        }
        checkIdlePages(requests) { store, idle in
            let excluded = store.suspensionExclusions
            store.pendingTabSuspensionExclusions = nil
            for (id, snapshot) in pages where idle.contains(id) && !excluded.contains(id) {
                guard store.canSuspendBackgroundTabs else { break }
                if store.hasSuspendableProfile(id), snapshot.matchesAvailableDocument(in: store, tabID: id) {
                    store.discardView(id)
                }
            }
        }
    }

    func clearTodayTabs() {
        guard canCleanUpTabs, !clearingToday else { return }
        let spaceID = space.id
        let candidates = cleanupTabs(in: [space]) { !$0.pinned && !$0.url.isEmpty }
        guard !candidates.isEmpty else { return }
        clearingToday = true
        checkIdleTabs(candidates) { store, idle in
            store.clearingToday = false
            guard store.canCleanUpTabs, store.space.id == spaceID else { return }
            for id in idle { store.close(id) }
        }
    }

    func archiveOldTabs() {
        let days = preferences.archiveAfterDays
        guard !isPrivate, canCleanUpTabs, days > 0, !archivingOldTabs else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        let excluded = archiveExclusions
        let candidates = cleanupTabs(in: session.spaces) { tab in
            guard !tab.pinned, !tab.url.isEmpty, !excluded.contains(tab.id), let visited = tab.lastAccessed else { return false }
            return visited < cutoff
        }
        guard !candidates.isEmpty else { return }
        archivingOldTabs = true
        checkIdleTabs(candidates) { store, idle in
            store.archivingOldTabs = false
            guard store.canCleanUpTabs else { return }
            guard store.preferences.archiveAfterDays == days else { store.archiveOldTabs(); return }
            let protected = store.archiveExclusions
            let approved = Set(idle).subtracting(protected)
            guard !approved.isEmpty else { return }
            var owners: [UUID: UUID] = [:]
            var exclusions = protected
            for space in store.session.spaces {
                for tab in space.tabs {
                    if approved.contains(tab.id) { owners[tab.id] = space.effectiveProfileID }
                    else { exclusions.insert(tab.id) }
                }
            }
            let archived = store.session.archiveInactive(before: cutoff, excluding: exclusions)
            for tab in archived {
                let profile = owners[tab.id] ?? BrowserProfile.defaultID
                store.mutateLibrary(for: profile) { $0.archive.insert(tab, at: 0) }
                store.discardSharedView(tab.id)
            }
            if !archived.isEmpty { store.save() }
        }
    }

    private var canCleanUpTabs: Bool {
        !isShuttingDown && !awaitingInitialMetadata && canModifyLocalMetadata
            && !profileDataOperationInProgress
    }

    private var archiveExclusions: Set<UUID> {
        var protected = Set(session.spaces.compactMap(\.selected))
        protected.formUnion(splitGroups.flatMap(\.tabIDs))
        if let windowGroup { protected.formUnion(windowGroup.protectedPaneIDs) }
        return protected
    }

    private func cleanupTabs(in spaces: [Space], where isEligible: (BrowserCore.Tab) -> Bool) -> [CleanupTab] {
        let live = cleanupPageOwners()
        var candidates: [CleanupTab] = []
        for space in spaces where !profileUnavailable(space.effectiveProfileID) {
            for tab in space.tabs where isEligible(tab) {
                let page = live[tab.id].flatMap { owner in
                    owner.views[tab.id].map { CleanupPage(store: owner, web: $0) }
                }
                candidates.append(CleanupTab(tab: tab, spaceID: space.id, profileID: space.effectiveProfileID, page: page))
            }
        }
        return candidates
    }

    private func cleanupPageOwners() -> [UUID: BrowserStore] {
        var owners: [UUID: BrowserStore] = [:]
        for store in pageStores {
            for id in store.views.keys { owners[id] = store }
        }
        return owners
    }

    private func checkIdleTabs(_ candidates: [CleanupTab], then complete: @escaping (BrowserStore, [UUID]) -> Void) {
        var unloaded = Set<UUID>()
        var requests: [(id: UUID, web: WKWebView)] = []
        for candidate in candidates {
            let id = candidate.tab.id
            if let page = candidate.page {
                if let web = page.web, page.matchesAvailableDocument(in: page.store, tabID: id) {
                    requests.append((id, web))
                }
            } else { unloaded.insert(id) }
        }
        checkIdlePages(requests) { store, idle in
            complete(store, store.validIdleTabs(candidates, idle: idle.union(unloaded)))
        }
    }

    private func checkIdlePages(_ requests: [(id: UUID, web: WKWebView)],
                                then complete: @escaping (BrowserStore, Set<UUID>) -> Void) {
        var idle = Set<UUID>()
        var pending = Set(requests.map(\.id))
        var finished = false
        let finish = { [weak self] in
            guard !finished else { return }
            finished = true
            guard let self else { return }
            complete(self, idle)
        }
        for (id, web) in requests {
            web.requestMediaPlaybackState { state in
                guard !finished, pending.remove(id) != nil else { return }
                if state == .paused || state == .none { idle.insert(id) }
                if pending.isEmpty { finish() }
            }
        }
        if pending.isEmpty { finish(); return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            finish() // Missing replies leave the page open.
        }
    }

    private func validIdleTabs(_ candidates: [CleanupTab], idle: Set<UUID>) -> [UUID] {
        guard canCleanUpTabs, !idle.isEmpty else { return [] }
        let live = cleanupPageOwners()
        var current: [UUID: (tab: BrowserCore.Tab, spaceID: UUID, profileID: UUID)] = [:]
        for space in session.spaces where !profileUnavailable(space.effectiveProfileID) {
            for tab in space.tabs where idle.contains(tab.id) {
                current[tab.id] = (tab, space.id, space.effectiveProfileID)
            }
        }
        return candidates.compactMap { candidate in
            let id = candidate.tab.id
            guard let location = current[id], !location.tab.pinned,
                  location.spaceID == candidate.spaceID, location.profileID == candidate.profileID,
                  location.tab.url == candidate.tab.url, location.tab.lastAccessed == candidate.tab.lastAccessed else { return nil }
            if let page = candidate.page { return page.matchesAvailableDocument(in: live[id], tabID: id) ? id : nil }
            return live[id] == nil ? id : nil
        }
    }
}
