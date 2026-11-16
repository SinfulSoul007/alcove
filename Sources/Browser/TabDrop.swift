import SwiftUI
import UniformTypeIdentifiers
import BrowserCore

struct SidebarFolderDrag: Equatable {
    let spaceID: UUID
    let name: String
    var text: String { "alcove-folder:\(spaceID.uuidString):\(name)" }

    init(spaceID: UUID, name: String) {
        self.spaceID = spaceID
        self.name = name
    }

    init?(_ text: String) {
        let parts = text.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "alcove-folder",
              let spaceID = UUID(uuidString: String(parts[1])), !parts[2].isEmpty else { return nil }
        self.init(spaceID: spaceID, name: String(parts[2]))
    }
}

struct TabDrop: DropDelegate {
    let store: BrowserStore
    let section: SidebarSection
    var before: UUID?
    var folder: String?
    func validateDrop(info: DropInfo) -> Bool { store.canModifyLocalMetadata && !store.profileDataOperationInProgress && info.hasItemsConforming(to: [.text]) }
    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info), let provider = info.itemProviders(for: [.text]).first else { return false }
        let destination = store.space.id
        let profile = store.space.effectiveProfileID
        provider.loadObject(ofClass: NSString.self) { value, _ in
            guard let text = value as? String else { return }
            Task { @MainActor in
                _ = accept(text, in: destination, profile: profile)
            }
        }
        return true
    }

    @MainActor func accept(_ text: String, in destination: UUID, profile: UUID) -> Bool {
        guard let space = store.session.spaces.first(where: { $0.id == destination }),
              space.effectiveProfileID == profile else { return false }
        if let folder, !space.folderNames.contains(folder) { return false }
        if let drag = SidebarFolderDrag(text) {
            guard section == .pinned, drag.spaceID == destination else { return false }
            do { try store.moveTabFolder(drag.name, under: folder, in: destination); return true }
            catch { store.message = error.localizedDescription; return false }
        }
        guard let id = UUID(uuidString: text), store.tab(id) != nil,
              store.requestPlaceTab(id, in: destination, section: section, before: before, folder: folder, fromDrop: true) else { return false }
        if store.space.id == destination { store.selectAny(id) }
        return true
    }
}
