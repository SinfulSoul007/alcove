import AppKit
import SwiftUI
import BrowserCore

extension BrowserStore {
    private func requireEaselLibrary(_ profileID: UUID) throws {
        guard activeProfileID == profileID else { throw SearchInputError.contextChanged }
        try requireSpaceProfile(profileID)
    }
    func requestNewEasel() {
        do { _ = try createEasel(); libraryVisible = false } catch { message = error.localizedDescription }
    }
    func renameLibraryEasel(_ id: UUID, profileID: UUID, title: String) throws {
        try requireEaselLibrary(profileID)
        try existingEaselDrafts?.flush(easelID: id, profileID: profileID)
        var candidate = makeDocument(), records = candidate.library(for: profileID)
        guard let index = records.easels?.firstIndex(where: { $0.id == id }), var board = records.easels?[index] else { throw EaselActionError.missing }
        try board.apply(.rename(title), expectedRevision: board.revision)
        records.easels?[index] = board
        refreshEaselTitles(board, profile: profileID, in: &candidate, library: &records)
        candidate.setLibrary(records, for: profileID)
        try commitQuickDocument(candidate)
    }
    func deleteLibraryEasel(_ id: UUID, profileID: UUID) throws {
        try requireEaselLibrary(profileID)
        var candidate = makeDocument(), records = candidate.library(for: profileID)
        guard records.easels?.contains(where: { $0.id == id }) == true else { throw EaselActionError.missing }
        var removed: [UUID] = []
        for index in candidate.session.spaces.indices where isPrivate || candidate.session.spaces[index].effectiveProfileID == profileID {
            let retiring = candidate.session.spaces[index].tabs.filter { EaselRoute.parse($0.url)?.id == id }
            removed += retiring.map(\.id)
            candidate.session.spaces[index].tabs.removeAll { EaselRoute.parse($0.url)?.id == id }
            if let selected = candidate.session.spaces[index].selected, removed.contains(selected) { candidate.session.spaces[index].selected = candidate.session.spaces[index].tabs.first?.id }
        }
        removed += (records.favoriteTabs ?? []).filter { EaselRoute.parse($0.url)?.id == id }.map(\.id)
        records.favoriteTabs?.removeAll { EaselRoute.parse($0.url)?.id == id }
        records.closedTabs.removeAll { EaselRoute.parse($0.url)?.id == id }
        records.archive.removeAll { EaselRoute.parse($0.url)?.id == id }
        records.easels?.removeAll { $0.id == id }
        candidate.setLibrary(records, for: profileID)
        try commitQuickDocument(candidate, discarding: removed, beforePublish: { self.existingEaselDrafts?.invalidate(easelID: id, profileID: profileID) })
        do { try pruneEaselAssets(for: profileID) } catch { message = "Canvas deleted. Unused image cleanup can be retried: " + error.localizedDescription }
    }
    func requestLibraryEaselRename(_ id: UUID, profileID: UUID) {
        guard activeProfileID == profileID, let board = library.easels?.first(where: { $0.id == id }) else { return }
        let alert = NSAlert(); alert.messageText = "Rename Easel"
        let field = NSTextField(string: board.title); field.frame = NSRect(x: 0, y: 0, width: 300, height: 24); field.setAccessibilityLabel("Easel title")
        alert.accessoryView = field; alert.addButton(withTitle: "Rename"); alert.addButton(withTitle: "Cancel"); alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try renameLibraryEasel(id, profileID: profileID, title: field.stringValue) } catch { message = error.localizedDescription }
    }
    func requestLibraryEaselDeletion(_ id: UUID, profileID: UUID) {
        guard activeProfileID == profileID, let board = library.easels?.first(where: { $0.id == id }) else { return }
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = "Delete “\(board.title)”?"
        alert.informativeText = "Remove this canvas, its cards and any unsaved canvas drafts from this profile. This cannot be undone."
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Delete Easel")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do { try deleteLibraryEasel(id, profileID: profileID) } catch { message = error.localizedDescription }
    }
}

struct EaselLibraryView: View {
    @ObservedObject var store: BrowserStore
    @State private var search = ""
    var body: some View {
        let profile = store.activeProfileID
        let boards = (store.library.easels ?? []).filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }.sorted { $0.modifiedAt > $1.modifiedAt }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Search Easels", text: $search).textFieldStyle(.roundedBorder)
                Button("New Easel") { store.requestNewEasel() }.disabled(!store.canManageSpace(store.space.id))
            }
            if boards.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "square.stack.3d.up").font(.largeTitle).opacity(0.5)
                    Text(search.isEmpty ? "Your canvases live here." : "No matching Easels.").font(.headline)
                    Text("Closing a tab keeps its notes and cards in this profile’s Library.").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(boards) { board in
                    HStack(spacing: 12) {
                        Image(systemName: "square.stack.3d.up").font(.title2).foregroundStyle(.secondary)
                        Button {
                            guard store.activeProfileID == profile else { return }
                            do { _ = try store.openEasel(board.id); store.libraryVisible = false } catch { store.message = error.localizedDescription }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(board.title).fontWeight(.medium)
                                Text("\(board.items.count) cards · Updated \(board.modifiedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Button { store.requestLibraryEaselRename(board.id, profileID: profile) } label: { Image(systemName: "pencil") }.help("Rename Easel").accessibilityLabel("Rename \(board.title)")
                        Button { store.requestLibraryEaselDeletion(board.id, profileID: profile) } label: { Image(systemName: "trash") }.help("Delete Easel permanently").accessibilityLabel("Delete \(board.title) permanently")
                    }.buttonStyle(.borderless).padding(.vertical, 8)
                }.disabled(!store.canModifyLocalMetadata || store.profileUnavailable(profile))
            }
        }
    }
}
