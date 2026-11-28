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
    var pendingDrawing: EaselItem? = nil
}
enum EaselDraftError: LocalizedError {
    case unavailable, conflict, drawingConflict
    var errorDescription: String? {
        switch self {
        case .unavailable: return "This note could not be saved in its original canvas. Its draft was kept."
        case .conflict: return "This note changed in another editor. Copy your draft or save it as a new note to keep both versions."
        case .drawingConflict: return "This canvas changed while you were drawing. Save your retained drawing as a new item to keep both versions."
        }
    }
}
@MainActor protocol EaselDraftEditing: AnyObject {
    func finishEaselDraftEditing()
    func discardEaselDraft(restoring item: EaselItem?)
    var hasMarkedEaselText: Bool { get }
}
extension EaselDraftEditing {
    func discardEaselDraft(restoring item: EaselItem?) {}
    var hasMarkedEaselText: Bool { false }
}

@MainActor protocol EaselDrawingHistoryRecording: AnyObject {
    func easelDrawingCommitted(_ item: EaselItem, before: Easel, after: Easel, profileID: UUID)
}

/// Dirty strings and completed drawings outlive their NSViews. Only a successful transaction or an
/// explicit discard removes one; normal tab/window/quit paths flush first.
@MainActor final class EaselDraftCoordinator: ObservableObject {
    private final class Record {
        var state: EaselDraftState
        let original: EaselItem
        weak var source: BrowserStore?
        weak var editor: (any EaselDraftEditing)?
        var timer: Task<Void, Never>?
        var drawingRevision: UUID?
        weak var drawingHistory: (any EaselDrawingHistoryRecording)?
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
    func hasDrafts(easelID: UUID, profileID: UUID) -> Bool {
        records.keys.contains { $0.easelID == easelID && $0.profileID == profileID }
    }
    func recoveryState(_ state: EaselDraftState, from source: BrowserStore? = nil) -> EaselDraftState? {
        guard let record = records[state.key], record.state.revision == state.revision,
              let source = source ?? presenter(for: record) ?? record.source,
              !source.isShuttingDown, source.activeProfileID == state.key.profileID,
              !source.profileUnavailable(state.key.profileID),
              (source.isPrivate ? source : source.metadataWriter) === owner,
              (presenter(for: record) ?? record.source) === source else { return nil }
        return record.state
    }
    func failures(in source: BrowserStore) -> [EaselDraftState] {
        records.values.filter { $0.state.failure != nil && recoveryState($0.state, from: source) != nil }
            .map(\.state).sorted { $0.key.itemID.uuidString < $1.key.itemID.uuidString }
    }
    @discardableResult func retry(_ state: EaselDraftState, from source: BrowserStore? = nil) -> Bool {
        guard recoveryState(state, from: source) != nil else { return false }
        do { try flush(state.key); return records[state.key] == nil }
        catch { report(error, for: state.key); return false }
    }
    @discardableResult func discard(_ state: EaselDraftState, from source: BrowserStore? = nil) -> Bool {
        guard recoveryState(state, from: source) != nil else { return false }
        let record = records[state.key]
        let item = record.flatMap { presenter(for: $0)?.easelContext(for: state.key.tabID)?.easel.items.first { $0.id == state.key.itemID } }
        discard(state.key)
        record?.editor?.discardEaselDraft(restoring: item)
        return true
    }
    @discardableResult func saveAsNewNote(_ state: EaselDraftState, from source: BrowserStore? = nil, recoveredTitle: String = "Recovered Easel") throws -> UUID {
        guard recoveryState(state, from: source) != nil else { throw EaselDraftError.conflict }
        return try saveAsNewNote(state.key, recoveredTitle: recoveredTitle)
    }
    @discardableResult func commitDrawing(_ item: EaselItem, context: EaselTabContext, from source: BrowserStore,
                                         history: any EaselDrawingHistoryRecording) -> Bool {
        guard !invalidated, let owner, !owner.isShuttingDown, case .drawing = item.content,
              (source.isPrivate ? source : source.metadataWriter) === owner,
              let current = source.easelContext(for: context.tabID),
              current.profileID == context.profileID, current.easel.id == context.easel.id else { return false }
        let key = EaselDraftKey(profileID: context.profileID, easelID: context.easel.id, tabID: context.tabID, itemID: item.id)
        guard records[key] == nil else { return false }
        var state = EaselDraftState(key: key, text: "")
        state.pendingDrawing = item
        let record = Record(state: state, original: item, source: source)
        record.drawingRevision = context.easel.revision; record.drawingHistory = history
        records[key] = record; revision += 1
        do { try flush(key); return records[key] == nil }
        catch { report(error, for: key); return false }
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
        scheduleAutosave(key, expected: record.state.revision)
    }
    private func scheduleAutosave(_ key: EaselDraftKey, expected: UUID) {
        guard let record = records[key] else { return }
        record.timer = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard !Task.isCancelled, let self, self.records[key]?.state.revision == expected else { return }
            if self.records[key]?.editor?.hasMarkedEaselText == true {
                self.scheduleAutosave(key, expected: expected); return
            }
            do { try self.flush(key, finishEditing: false) } catch { self.report(error, for: key) }
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
    private func flush(_ key: EaselDraftKey, finishEditing: Bool = true) throws {
        guard !flushing.contains(key), let initial = records[key] else { return }
        guard !invalidated, let owner, !owner.isShuttingDown else { throw EaselDraftError.unavailable }
        flushing.insert(key); defer { flushing.remove(key) }
        initial.timer?.cancel(); initial.timer = nil
        if finishEditing { initial.editor?.finishEaselDraftEditing() }
        guard let record = records[key] else { return }
        record.timer?.cancel(); record.timer = nil
        guard let source = presenter(for: record), let context = source.easelContext(for: key.tabID),
              context.profileID == key.profileID, context.easel.id == key.easelID else { throw EaselDraftError.unavailable }
        if let mark = record.state.pendingDrawing {
            if let saved = context.easel.items.first(where: { $0.id == mark.id }) {
                guard saved == mark else { throw EaselDraftError.drawingConflict }
                discard(key); return
            }
            guard context.easel.revision == record.drawingRevision else { throw EaselDraftError.drawingConflict }
            let after = try source.commitEaselEdits(in: key.tabID, expectedRevision: context.easel.revision, edits: [.insert(mark)])
            discard(key)
            record.drawingHistory?.easelDrawingCommitted(mark, before: context.easel, after: after, profileID: key.profileID)
            return
        }
        guard let item = context.easel.items.first(where: { $0.id == key.itemID }), case .note = item.content else { throw EaselDraftError.unavailable }
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
        record.source?.message = "This canvas has unsaved changes. " + error.localizedDescription
    }
    func discard(_ key: EaselDraftKey) {
        records.removeValue(forKey: key)?.timer?.cancel(); revision += 1
    }
    @discardableResult func saveAsNewNote(_ key: EaselDraftKey, recoveredTitle: String = "Recovered Easel") throws -> UUID {
        guard !invalidated, let record = records[key], let source = presenter(for: record) ?? record.source,
              recoveryState(record.state, from: source) != nil else { throw EaselDraftError.unavailable }
        try source.requireSpaceProfile(key.profileID)
        let context = source.easelContext(for: key.tabID)
        let old = context?.easel.items.first(where: { $0.id == key.itemID })?.frame ?? record.original.frame
        let frame = try EaselFrame(x: min(old.x + 24, EaselFrame.canvasSize - old.width), y: min(old.y + 24, EaselFrame.canvasSize - old.height), width: old.width, height: old.height)
        let note = try EaselItem(frame: frame, content: record.state.pendingDrawing?.content ?? .note(text: record.state.text))
        if let context, context.profileID == key.profileID, context.easel.id == key.easelID {
            _ = try source.commitEaselEdits(in: key.tabID, expectedRevision: context.easel.revision, edits: [.insert(note)])
        } else {
            var candidate = source.makeDocument(), library = candidate.library(for: key.profileID)
            var board = try Easel(title: recoveredTitle)
            try board.apply(.insert(note), expectedRevision: board.revision)
            library.easels = [board] + (library.easels ?? []); candidate.setLibrary(library, for: key.profileID)
            let target = source.space.id
            guard source.isPrivate || source.space.effectiveProfileID == key.profileID else { throw EaselDraftError.unavailable }
            let tab = try source.insertEaselTab(board, in: target, document: &candidate)
            try source.commitQuickDocument(candidate, beforePublish: { source.closePrimaryPeek(); source.dismissCommand() })
            source.select(tab)
        }
        _ = discard(record.state, from: source)
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
    func flushEaselBoardDrafts(in tabID: UUID) throws {
        guard let context = easelContext(for: tabID) else { throw EaselActionError.missing }
        try existingEaselDrafts?.flush(easelID: context.easel.id, profileID: context.profileID)
    }
    @discardableResult func flushEaselBoardDraftsIfPossible(in tabID: UUID) -> Bool {
        do { try flushEaselBoardDrafts(in: tabID); return true }
        catch { message = "This canvas has unsaved changes. " + error.localizedDescription; return false }
    }
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
        } catch { message = "This canvas has unsaved changes. " + error.localizedDescription; return false }
    }
}
