import Foundation
import BrowserCore

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
    private var workspace: BrowserWindowWorkspace
    private var members: [UUID: Member] = [:]
    private var broadcasting = false

    init(root: BrowserStore) throws {
        workspace = try BrowserWindowWorkspace(session: root.session)
        self.root = root
        root.windowGroup = self
    }

    private var stores: [BrowserStore] {
        guard let root else { return [] }
        return [root] + members.values.compactMap(\.store).filter { $0 !== root }
    }

    func openPrimary(copying source: BrowserStore?) throws -> BrowserStore {
        guard let root, !root.isShuttingDown else { throw BrowserWindowOwnerError.closed }
        if let source, !isMember(source) { throw BrowserWindowOwnerError.closed }
        let store: BrowserStore
        if root.windowGroupID == nil { store = root }
        else {
            store = BrowserStore(dataRoot: root.sessionURL.deletingLastPathComponent(),
                                 metadataKeyAccess: root.metadataKeyAccess, windowGroup: self)
        }
        let selection = try workspace.openWindow(copying: source?.windowGroupID ?? workspace.focusedWindowID)
        store.windowGroupID = selection.id
        members[selection.id] = Member(store: store)
        if store !== root {
            broadcasting = true
            store.profiles = root.profiles
            store.profileLibraries = root.profileLibraries
            store.preferences = root.preferences
            copyWriterState(from: root, to: store)
            broadcasting = false
        }
        publishWorkspace(workspace)
        return store
    }

    func closePrimary(_ store: BrowserStore) {
        guard let id = store.windowGroupID, members[id]?.store === store else { return }
        members.removeValue(forKey: id)
        store.windowGroupID = nil
        workspace.closeWindow(id)
        if store === root {
            store.closePrimaryWindowPages()
        } else {
            store.windowGroup = nil
            store.shutdown()
        }
        publishWorkspace(workspace)
    }

    @discardableResult
    func focusPrimary(_ store: BrowserStore) -> Bool {
        guard let id = store.windowGroupID, members[id]?.store === store else { return false }
        if workspace.focusedWindowID != id {
            workspace.focusWindow(id)
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
        var diskDocument = prepared
        diskDocument.session = next.session
        do { try vault.save(diskDocument) }
        catch {
            root.savingEnabled = false
            let message = "Couldn’t save profile changes. Your existing tabs and data were kept. \(error.localizedDescription)"
            root.message = message
            source.message = message
            throw error
        }

        let retained = Set(prepared.session.spaces.flatMap(\.tabs).map(\.id))
        let nextQuick = Set((prepared.profileLibraries ?? []).flatMap { $0.library.quickPages ?? [] }.map(\.id))
        let removedQuick = Set(root.allQuickPages.map(\.id)).subtracting(nextQuick).subtracting(retained)
        let discarded = Set(ids).union(removedQuick)
        let recipients = stores
        for store in recipients {
            for id in discarded { store.discardView(id) }
        }
        beforePublish?()
        for store in recipients {
            store.reconcilePeeks(in: prepared, resetting: spaceID)
            if spaceID == store.space.id || discarded.contains(where: { $0 == store.splitID || $0 == store.selectedID }) {
                store.splitID = nil
                store.activePaneID = nil
            }
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
