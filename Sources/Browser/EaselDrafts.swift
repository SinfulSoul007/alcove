import Foundation
import Combine
import BrowserCore

struct EaselDraftKey: Hashable {
    let profileID: UUID, easelID: UUID, tabID: UUID, itemID: UUID
}
struct EaselDraftState: Equatable {
    let key: EaselDraftKey
    var text: String
    var revision = UUID()
    var failure: String?
}
enum EaselDraftError: LocalizedError {
    case unavailable, conflict
    var errorDescription: String? {
        switch self {
        case .unavailable: return "This note could not be saved in its original canvas. Its draft was kept."
        case .conflict: return "This note changed in another editor. Copy your draft or save it as a new note to keep both versions."
        }
    }
}
@MainActor protocol EaselDraftEditing: AnyObject { func finishEaselDraftEditing() }

/// Dirty strings outlive their NSViews. Only a successful transaction or an
/// explicit discard removes one; normal tab/window/quit paths flush first.
@MainActor final class EaselDraftCoordinator: ObservableObject {
    private final class Record {
        var state: EaselDraftState
        let original: EaselItem
        weak var source: BrowserStore?
        weak var editor: (any EaselDraftEditing)?
        var timer: Task<Void, Never>?
        init(state: EaselDraftState, original: EaselItem, source: BrowserStore) {
            self.state = state; self.original = original; self.source = source
        }
        deinit { timer?.cancel() }
    }
    private weak var owner: BrowserStore?
    private var records: [EaselDraftKey: Record] = [:]
    private var flushing = Set<EaselDraftKey>()
    private var invalidated = false
    @Published private(set) var revision = 0
    init(owner: BrowserStore) { self.owner = owner }

    var dirtyTabIDs: Set<UUID> { Set(records.keys.map(\.tabID)) }
    func state(for key: EaselDraftKey) -> EaselDraftState? { records[key]?.state }
    func failures(in source: BrowserStore) -> [EaselDraftState] {
        records.values.filter { $0.state.failure != nil && (presenter(for: $0) ?? $0.source) === source }
            .map(\.state).sorted { $0.key.itemID.uuidString < $1.key.itemID.uuidString }
    }
    @discardableResult func retry(_ state: EaselDraftState) -> Bool {
        guard records[state.key]?.state.revision == state.revision else { return false }
        do { try flush(state.key); return records[state.key] == nil }
        catch { report(error, for: state.key); return false }
    }
    @discardableResult func discard(_ state: EaselDraftState) -> Bool {
        guard records[state.key]?.state.revision == state.revision else { return false }
        discard(state.key); return true
    }
    @discardableResult func saveAsNewNote(_ state: EaselDraftState) throws -> UUID {
        guard records[state.key]?.state.revision == state.revision else { throw EaselDraftError.conflict }
        return try saveAsNewNote(state.key)
    }
    func update(_ text: String, tabID: UUID, itemID: UUID, from source: BrowserStore, original: EaselItem? = nil) throws {
        guard !invalidated, let owner, !owner.isShuttingDown,
              (source.isPrivate ? source : source.metadataWriter) === owner,
              let context = source.easelContext(for: tabID) else { throw EaselDraftError.unavailable }
        let current = context.easel.items.first(where: { $0.id == itemID })
        guard let item = original ?? current, item.id == itemID, case .note = item.content else { throw EaselDraftError.unavailable }
        _ = try EaselItem(id: item.id, frame: item.frame, content: .note(text: text))
        let key = EaselDraftKey(profileID: context.profileID, easelID: context.easel.id, tabID: tabID, itemID: itemID)
        if current?.content == .note(text: text) { discard(key); return }
        let record = records[key] ?? Record(state: EaselDraftState(key: key, text: text), original: item, source: source)
        record.timer?.cancel(); record.source = source
        record.state.text = text; record.state.failure = nil; record.state.revision = UUID()
        records[key] = record; revision += 1
        let expected = record.state.revision
        record.timer = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard !Task.isCancelled, let self, self.records[key]?.state.revision == expected else { return }
            do { try self.flush(key) } catch { self.report(error, for: key) }
        }
    }
    func attach(_ editor: any EaselDraftEditing, for key: EaselDraftKey) { records[key]?.editor = editor }
    func detach(_ editor: any EaselDraftEditing, for key: EaselDraftKey) {
        if records[key]?.editor === editor { records[key]?.editor = nil }
    }
    func flush(tabID: UUID) throws { try flushMatching { $0.state.key.tabID == tabID } }
    func flush(tabIDs: Set<UUID>) throws { try flushMatching { tabIDs.contains($0.state.key.tabID) } }
    func flush(profileID: UUID) throws { try flushMatching { $0.state.key.profileID == profileID } }
    func flush(easelID: UUID, profileID: UUID) throws { try flushMatching { $0.state.key.profileID == profileID && $0.state.key.easelID == easelID } }
    func flushAll() throws { try flushMatching { _ in true } }
    func flush(from source: BrowserStore) throws { try flushMatching { (presenter(for: $0) ?? $0.source) === source } }
    private func presenter(for record: Record) -> BrowserStore? {
        let key = record.state.key
        return owner?.pageStores.first { store in
            guard let context = store.easelContext(for: key.tabID) else { return false }
            return context.profileID == key.profileID && context.easel.id == key.easelID
        }
    }
    private func flushMatching(_ matches: (Record) -> Bool) throws {
        let keys = records.values.filter(matches).map(\.state.key).sorted { $0.itemID.uuidString < $1.itemID.uuidString }
        for key in keys {
            do { try flush(key) } catch { report(error, for: key); throw error }
        }
    }
    private func flush(_ key: EaselDraftKey) throws {
        guard !flushing.contains(key), let initial = records[key] else { return }
        guard !invalidated, let owner, !owner.isShuttingDown else { throw EaselDraftError.unavailable }
        flushing.insert(key); defer { flushing.remove(key) }
        initial.timer?.cancel(); initial.timer = nil
        initial.editor?.finishEaselDraftEditing()
        guard let record = records[key] else { return }
        record.timer?.cancel(); record.timer = nil
        guard let source = presenter(for: record), let context = source.easelContext(for: key.tabID),
              context.profileID == key.profileID, context.easel.id == key.easelID,
              let item = context.easel.items.first(where: { $0.id == key.itemID }), case .note = item.content else { throw EaselDraftError.unavailable }
        if item.content == .note(text: record.state.text) { discard(key); return }
        record.source = source
        guard item.content == record.original.content else { throw EaselDraftError.conflict }
        let replacement = try EaselItem(id: item.id, frame: item.frame, content: .note(text: record.state.text))
        _ = try source.commitEaselEdits(in: key.tabID, expectedRevision: context.easel.revision, edits: [.replace(replacement)])
        discard(key)
    }
    private func report(_ error: Error, for key: EaselDraftKey) {
        guard let record = records[key] else { return }
        record.state.failure = error.localizedDescription; revision += 1
        record.source?.message = "A canvas note has unsaved changes. " + error.localizedDescription
    }
    func discard(_ key: EaselDraftKey) {
        records.removeValue(forKey: key)?.timer?.cancel(); revision += 1
    }
    @discardableResult func saveAsNewNote(_ key: EaselDraftKey) throws -> UUID {
        guard !invalidated, let record = records[key], let source = presenter(for: record),
              let context = source.easelContext(for: key.tabID), context.profileID == key.profileID,
              context.easel.id == key.easelID else { throw EaselDraftError.unavailable }
        let old = context.easel.items.first(where: { $0.id == key.itemID })?.frame ?? record.original.frame
        let frame = try EaselFrame(x: min(old.x + 24, EaselFrame.canvasSize - old.width), y: min(old.y + 24, EaselFrame.canvasSize - old.height), width: old.width, height: old.height)
        let note = try EaselItem(frame: frame, content: .note(text: record.state.text))
        _ = try source.commitEaselEdits(in: key.tabID, expectedRevision: context.easel.revision, edits: [.insert(note)])
        discard(key)
        return note.id
    }
    func invalidate(profileID: UUID) {
        for key in records.keys.filter({ $0.profileID == profileID }) { discard(key) }
    }
    func invalidate(easelID: UUID, profileID: UUID) {
        for key in records.keys.filter({ $0.profileID == profileID && $0.easelID == easelID }) { discard(key) }
    }
    func invalidate() {
        invalidated = true
        for record in records.values { record.timer?.cancel() }
        records.removeAll(); revision += 1
    }
}

extension BrowserStore {
    var existingEaselDrafts: EaselDraftCoordinator? { (isPrivate ? self : metadataWriter).retainedEaselDrafts }
    var easelDrafts: EaselDraftCoordinator {
        let writer = isPrivate ? self : metadataWriter
        if let existing = writer.retainedEaselDrafts { return existing }
        let created = EaselDraftCoordinator(owner: writer); writer.retainedEaselDrafts = created
        return created
    }
    @discardableResult func flushEaselDrafts(tabID: UUID? = nil) -> Bool {
        guard let drafts = existingEaselDrafts else { return true }
        do {
            if let tabID { try drafts.flush(tabID: tabID) } else { try drafts.flush(from: self) }
            return true
        } catch { message = "A canvas note has unsaved changes. " + error.localizedDescription; return false }
    }
}
