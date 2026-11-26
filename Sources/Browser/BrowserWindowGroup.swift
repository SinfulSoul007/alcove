import AppKit
import BrowserCore
import WebKit

enum BrowserWindowGroupError: LocalizedError {
    case staleDocument

    var errorDescription: String? {
        "The saved tabs or settings changed in another window. Try the change again."
    }
}

/// Coordinates normal window projections on the main actor. The owner retains the
/// writer and holds each registered window store through its primary lease.
@MainActor
final class BrowserWindowGroup {
    enum SharedField { case profiles, libraries, preferences }

    private struct Member {
        weak var store: BrowserStore?
    }

    private(set) weak var root: BrowserStore?
    private(set) var revision = UUID()
    private var workspace: BrowserWindowWorkspace {
        didSet {
            for tabID in Array(extensionPresentationIDs.keys) {
                let previous = oldValue.assignedWindow(for: tabID)
                let current = workspace.assignedWindow(for: tabID)
                if previous != current || (current == nil && oldValue.focusedWindowID != workspace.focusedWindowID) {
                    extensionPresentationIDs.removeValue(forKey: tabID)
                }
            }
        }
    }
    private var extensionPresentationIDs: [UUID: NSUUID] = [:]
    private var members: [UUID: Member] = [:]
    private var frames: [UUID: BrowserWindowFrame] = [:]
    private var broadcasting = false

    init(root: BrowserStore, restoring saved: BrowserWindowRestoreState? = nil) throws {
        workspace = try BrowserWindowWorkspace(session: root.session,
                                               windows: saved?.records.map(\.selection) ?? [],
                                               focusedWindowID: saved?.focusedWindowID,
                                               assignments: saved?.assignments ?? [:])
        self.root = root
        root.windowGroup = self
    }

    var stores: [BrowserStore] {
        guard let root else { return [] }
        return [root] + members.values.compactMap(\.store).filter { $0 !== root }
    }
    var focusedPrimary: BrowserStore? {
        workspace.focusedWindowID.flatMap { members[$0]?.store }
    }
    func containsPrimary(_ store: BrowserStore) -> Bool {
        guard let id = store.windowGroupID, !store.isShuttingDown else { return false }
        return members[id]?.store === store
    }

    func extensionPresenter(for tabID: UUID) -> BrowserStore? {
        if let live = liveStore(forTab: tabID), containsPrimary(live) { return live }
        if let id = workspace.assignedWindow(for: tabID) { return members[id]?.store }
        return focusedPrimary
    }

    /// An unloaded tab can change presenters twice before WebKit observes either move.
    func extensionPresentationIdentity(for tabID: UUID) -> NSUUID {
        if let identity = extensionPresentationIDs[tabID] { return identity }
        let identity = NSUUID()
        extensionPresentationIDs[tabID] = identity
        return identity
    }

    func openPrimary(copying source: BrowserStore?, focus: Bool = true, claimSelection: Bool = true,
                     popupProfileID: UUID? = nil) throws -> BrowserStore {
        guard let root, !root.isShuttingDown else { throw BrowserWindowOwnerError.closed }
        if let source, !isMember(source) { throw BrowserWindowOwnerError.closed }
        let selection = try workspace.openWindow(copying: source?.windowGroupID ?? workspace.focusedWindowID,
                                                  focus: focus, claimSelection: claimSelection, popupProfileID: popupProfileID)
        let store = attachPrimary(selection.id, root: root, popupProfileID: popupProfileID)
        publishWorkspace(workspace)
        if claimSelection, let tab = store.selectedID, workspace.assignedWindow(for: tab) == selection.id {
            claimPresentation(tabID: tab, in: store)
        }
        root.save()
        return store
    }

    func attachRestoredPrimaries(using saved: BrowserWindowRestoreState) -> [(store: BrowserStore, frame: BrowserWindowFrame?, focused: Bool)] {
        guard let root, members.isEmpty, !root.isShuttingDown else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: saved.records.map { ($0.selection.id, $0) })
        let restored = workspace.windows.map { window in
            let record = byID[window.id]
            if let frame = record?.frame, frame.isValid { frames[window.id] = frame }
            let store = attachPrimary(window.id, root: root, restoring: record)
            return (store: store, frame: frames[window.id], focused: window.id == workspace.focusedWindowID)
        }
        publishWorkspace(workspace)
        for item in restored {
            if let id = item.store.windowGroupID { item.store.splitGroups = byID[id]?.splitGroups ?? [] }
        }
        return restored
    }

    private func attachPrimary(_ id: UUID, root: BrowserStore, restoring record: BrowserWindowRestoreRecord? = nil,
                               popupProfileID: UUID? = nil) -> BrowserStore {
        let store: BrowserStore
        if root.windowGroupID == nil && popupProfileID == nil { store = root }
        else {
            store = BrowserStore(dataRoot: root.sessionURL.deletingLastPathComponent(),
                                 metadataKeyAccess: root.metadataKeyAccess, windowGroup: self)
        }
        store.windowGroupID = id
        store.extensionPopupProfileID = popupProfileID
        store.windowSidebarWidth = record?.sidebarWidth
        store.sidebarVisible = record?.sidebarVisible ?? (popupProfileID == nil)
        members[id] = Member(store: store)
        if store !== root {
            broadcasting = true
            store.profiles = root.profiles
            store.profileLibraries = root.profileLibraries
            store.preferences = root.preferences
            copyWriterState(from: root, to: store)
            store.extensionStates = root.extensionStates
            store.extensionDiagnostics = root.extensionDiagnostics
            broadcasting = false
        }
        return store
    }

    func closePrimary(_ store: BrowserStore) {
        guard let id = store.windowGroupID, members[id]?.store === store else { return }
        members.removeValue(forKey: id)
        frames.removeValue(forKey: id)
        store.windowGroupID = nil
        workspace.closeWindow(id)
        handOffPages(from: store)
        if store === root {
            store.closePrimaryWindowPages()
        } else {
            store.windowGroup = nil
            store.shutdown()
            if let root {
                root.closingPages.removeAll { $0.webView == nil }
                root.closingPages.append(contentsOf: store.closingPages.filter { $0.webView != nil })
            }
        }
        publishWorkspace(workspace)
        root?.save()
    }

    func presentation(tabID: UUID, in store: BrowserStore) -> BrowserTabPresentation {
        guard let id = store.windowGroupID, isMember(store),
              let profile = spaceProfile(forTab: tabID), !store.profileUnavailable(profile) else { return .unavailable }
        let presenter: UUID?
        if let live = liveStore(forTab: tabID) {
            guard let id = live.windowGroupID else { return .pooled }
            presenter = id
        } else { presenter = workspace.assignedWindow(for: tabID) }
        if let scope = store.extensionPopupProfileID, scope != profile || presenter != id { return .unavailable }
        if let presenter, presenter != id { return .elsewhere(windowID: presenter) }
        return .owned
    }

    @discardableResult
    func claimPresentation(tabID: UUID, in store: BrowserStore, allowPopupTransfer: Bool = false) -> Bool {
        guard let id = store.windowGroupID, isMember(store),
              let profile = spaceProfile(forTab: tabID), !store.profileUnavailable(profile),
              store.extensionPopupProfileID == nil || store.extensionPopupProfileID == profile else { return false }
        let live = liveStore(forTab: tabID)
        let previousID = live?.windowGroupID ?? workspace.assignedWindow(for: tabID)
        guard store.extensionPopupProfileID == nil || previousID == id || allowPopupTransfer else { return false }
        if let previous = live, previous !== store {
            guard let web = previous.views[tabID], web.fullscreenState == .notInFullscreen,
                  (web as? SplitDropWebView)?.websiteFullscreen?.isBorrowed != true else { return false }
            guard previous.moveView(tabID, profile: profile, to: store) else { return false }
        }
        let claimed = workspace.claim(tabID, for: id)
        if claimed {
            // A new window can already have the assignment before its first view is mounted.
            for member in stores where member !== store { member.removeFromSplit(tabID) }
        }
        if claimed && (previousID != id || live == nil) {
            for member in stores { member.revision += 1 }
            if previousID != id {
                if let previousID, let previous = members[previousID]?.store {
                    if previous.recentTabSwitcher?.sourceTabID == tabID { previous.cancelRecentTabSwitcher() }
                }
                if store.extensionPopupProfileID != nil ||
                   previousID.flatMap({ members[$0]?.store?.extensionPopupProfileID }) != nil {
                    publishWorkspace(workspace)
                }
                root?.save()
            }
        }
        return claimed
    }

    func canClaimPresentation(tabID: UUID, in store: BrowserStore) -> Bool {
        guard containsPrimary(store), let profile = spaceProfile(forTab: tabID), !store.profileUnavailable(profile),
              store.extensionPopupProfileID == nil || store.extensionPopupProfileID == profile else { return false }
        guard let live = liveStore(forTab: tabID), live !== store else { return true }
        guard let web = live.views[tabID], web.fullscreenState == .notInFullscreen,
              (web as? SplitDropWebView)?.websiteFullscreen?.isBorrowed != true else { return false }
        return live.canMoveView(tabID, profile: profile, to: store)
    }

    func revealPresenter(tabID: UUID, from source: BrowserStore) {
        guard case .elsewhere(let id) = presentation(tabID: tabID, in: source) else { return }
        guard let window = members[id]?.store?.extensionWindows[.primary]?.window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    var protectedPaneIDs: Set<UUID> {
        Set(stores.filter { $0.windowGroupID != nil }.flatMap { store in
            store.splitGroups.flatMap(\.tabIDs) + store.visiblePaneIDs
        })
    }

    func discardPage(_ id: UUID) {
        for store in stores {
            store.removeFromSplit(id)
            if store.views[id] != nil {
                store.discardView(id)
                store.revision += 1
            }
        }
    }

    private func liveStore(forTab tabID: UUID) -> BrowserStore? {
        stores.first(where: { $0.views[tabID] != nil })
    }

    private func spaceProfile(forTab tabID: UUID) -> UUID? {
        workspace.session.spaces.first(where: { $0.tabs.contains(where: { $0.id == tabID }) })?.effectiveProfileID
    }

    private func handOffPages(from closing: BrowserStore) {
        let survivors = workspace.windows.compactMap { members[$0.id]?.store }.filter { $0.extensionPopupProfileID == nil }
        for tabID in Array(closing.views.keys) {
            guard let profile = spaceProfile(forTab: tabID), !closing.profileUnavailable(profile) else { continue }
            let destination = survivors.first { $0.visiblePaneIDs.contains(tabID) }
                ?? survivors.first { $0.windowGroupID == workspace.focusedWindowID }
            if let destination, let id = destination.windowGroupID,
               closing.moveView(tabID, profile: profile, to: destination) {
                workspace.claim(tabID, for: id)
            }
        }
    }

    @discardableResult
    func focusPrimary(_ store: BrowserStore) -> Bool {
        guard let id = store.windowGroupID, members[id]?.store === store else { return false }
        if workspace.focusedWindowID != id {
            guard workspace.focusWindow(id) else { return false }
            publishWorkspace(workspace)
            root?.save()
        }
        return true
    }

    func persistenceDocument() -> BrowserDocument? {
        guard let root else { return nil }
        var document = root.makeDocument()
        document.session = workspace.session
        return document
    }

    func recordFrame(_ frame: BrowserWindowFrame, for store: BrowserStore) {
        guard frame.isValid, let id = store.windowGroupID, members[id]?.store === store, frames[id] != frame else { return }
        frames[id] = frame
        root?.save()
    }

    func sidebarLayoutDidChange(in store: BrowserStore) {
        guard containsPrimary(store) else { return }
        root?.save()
    }

    func restoreState() -> BrowserWindowRestoreState? { restoreState(for: workspace) }

    private func restoreState(for workspace: BrowserWindowWorkspace, discarding: Set<UUID> = []) -> BrowserWindowRestoreState? {
        let saved = workspace.windows.filter { members[$0.id]?.store?.extensionPopupProfileID == nil }
        guard !saved.isEmpty else { return nil }
        let records = saved.map { selection in
            let store = members[selection.id]?.store
            let groups = store.map { store in
                store.reconciledSplitGroups(in: workspace.session, previous: store.session, discarding: discarding) {
                    workspace.assignedWindow(for: $0) == selection.id
                }
            }
            return BrowserWindowRestoreRecord(selection: selection, frame: frames[selection.id],
                                              sidebarWidth: store?.windowSidebarWidth, sidebarVisible: store?.sidebarVisible,
                                              splitGroups: groups)
        }
        let savedIDs = Set(saved.map(\.id))
        return BrowserWindowRestoreState(records: records, focusedWindowID: workspace.focusedWindowID,
                                         assignments: workspace.assignments.filter { savedIDs.contains($0.value) })
    }

    func sessionDidChange(from source: BrowserStore) {
        guard !broadcasting, isMember(source) else { return }
        do {
            publishWorkspace(try replacingSession(source.session, from: source))
        } catch {
            broadcasting = true
            source.session = projectedSession(for: source)
            broadcasting = false
            source.message = error.localizedDescription
        }
    }

    func sharedFieldDidChange(_ field: SharedField, from source: BrowserStore) {
        guard !broadcasting, isMember(source) else { return }
        revision = UUID()
        broadcasting = true
        defer { broadcasting = false }
        for store in stores where store !== source {
            switch field {
            case .profiles: store.profiles = source.profiles
            case .libraries: store.profileLibraries = source.profileLibraries
            case .preferences: store.preferences = source.preferences
            }
        }
    }

    func writerStateDidChange(from source: BrowserStore) {
        guard !broadcasting, source === root else { return }
        broadcasting = true
        defer { broadcasting = false }
        for store in stores where store !== source { copyWriterState(from: source, to: store) }
    }

    func extensionStatusDidChange(from source: BrowserStore) {
        guard source === root else { return }
        for store in stores where store !== source {
            if store.extensionStates != source.extensionStates { store.extensionStates = source.extensionStates }
            if store.extensionDiagnostics != source.extensionDiagnostics { store.extensionDiagnostics = source.extensionDiagnostics }
        }
    }

    func restore(_ document: BrowserDocument, from source: BrowserStore) throws {
        guard source === root, !source.isShuttingDown else { throw CancellationError() }
        let next = try replacingSession(document.session, from: source)
        publishWorkspace(next, document: document)
    }

    func commit(_ candidate: BrowserDocument, from source: BrowserStore, discarding ids: [UUID],
                resetting spaceID: UUID?, beforePublish: (() -> Void)?) throws {
        guard let root, !root.isShuttingDown, isMember(source) else { throw CancellationError() }
        guard root.savingEnabled, let vault = root.vault else { throw ProfileError.locked }
        guard candidate.workingRevision == revision else { throw BrowserWindowGroupError.staleDocument }

        var prepared = candidate
        try prepared.repairProfiles()
        prepared.session = BrowserStore.repairedSession(prepared.session)
        let next = try replacingSession(prepared.session, from: source)
        let retained = Set(prepared.session.spaces.flatMap(\.tabs).map(\.id))
        let nextQuick = Set((prepared.profileLibraries ?? []).flatMap { $0.library.quickPages ?? [] }.map(\.id))
        let removedQuick = Set(root.allQuickPages.map(\.id)).subtracting(nextQuick).subtracting(retained)
        let discarded = Set(ids).union(removedQuick)
        var diskDocument = prepared
        diskDocument.session = next.session
        diskDocument.windowRestore = restoreState(for: next, discarding: discarded)
        do { try vault.save(diskDocument) }
        catch {
            root.savingEnabled = false
            let message = "Couldn’t save profile changes. Your existing tabs and data were kept. \(error.localizedDescription)"
            root.message = message
            source.message = message
            throw error
        }

        let recipients = stores
        for store in recipients {
            for id in discarded { store.discardView(id) }
        }
        beforePublish?()
        for store in recipients {
            store.reconcilePeeks(in: prepared, resetting: spaceID)
            store.resetSplitIfDiscardingPages(discarded, in: prepared.session)
        }
        root.hasSavedDocument = true
        root.persistedProfileIDs = Set((prepared.profiles ?? []).map(\.id))
        publishWorkspace(next, document: prepared)
    }

    private func isMember(_ store: BrowserStore) -> Bool {
        guard !store.isShuttingDown else { return false }
        if store === root { return true }
        guard let id = store.windowGroupID else { return false }
        return members[id]?.store === store
    }

    private func replacingSession(_ session: Session, from source: BrowserStore) throws -> BrowserWindowWorkspace {
        var next = workspace
        if let id = source.windowGroupID { try next.apply(session, from: id) }
        else { try next.applySharedSession(session) }
        for store in stores where !store.splitGroups.isEmpty {
            guard let id = store.windowGroupID else { continue }
            let repairs = store.splitSelectionRepairs(in: next.session) { next.assignedWindow(for: $0) == id }
            guard !repairs.isEmpty, var projection = next.session(for: id) else { continue }
            for index in projection.spaces.indices {
                if let replacement = repairs[projection.spaces[index].id] { projection.spaces[index].selected = replacement }
            }
            try next.apply(projection, from: id)
        }
        return next
    }

    private func projectedSession(for store: BrowserStore) -> Session {
        store.windowGroupID.flatMap { workspace.session(for: $0) } ?? workspace.session
    }

    private func publishWorkspace(_ next: BrowserWindowWorkspace, document: BrowserDocument? = nil) {
        workspace = next
        revision = UUID()
        let recipients = stores
        broadcasting = true
        for store in recipients {
            if store.extensionPopupProfileID != nil {
                for id in store.visiblePaneIDs where id != store.selectedID && presentation(tabID: id, in: store) != .owned {
                    store.removeFromSplit(id)
                }
            }
            let selectedSession = projectedSession(for: store)
            if let document { store.installDocumentFields(document, projecting: selectedSession) }
            else if store.session != selectedSession { store.session = selectedSession }
        }
        broadcasting = false
        if document != nil {
            for store in recipients { store.documentDidChange() }
        }
    }

    private func copyWriterState(from root: BrowserStore, to store: BrowserStore) {
        store.savingEnabled = root.savingEnabled
        store.unlocking = root.unlocking
        store.awaitingInitialMetadata = root.awaitingInitialMetadata
        store.metadataLoadError = root.metadataLoadError
        store.profileInUse = root.profileInUse
        store.persistedProfileIDs = root.persistedProfileIDs
    }
}
