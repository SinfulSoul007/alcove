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

struct SidebarSplitHover: Equatable {
    let drag: SidebarTabDrag
    let target: BrowserSplitDropTarget
    let edge: BrowserSplitEdge
    let valid: Bool
}

struct TabDrop: DropDelegate {
    let store: BrowserStore
    let section: SidebarSection
    var before: UUID?
    var folder: String?
    var rowWidth: CGFloat = 0
    var hover: Binding<SidebarSplitHover?>?

    func validateDrop(info: DropInfo) -> Bool {
        store.canModifyLocalMetadata && !store.profileDataOperationInProgress && info.hasItemsConforming(to: SidebarTabDrag.dropTypes)
    }

    private func splitEdge(for info: DropInfo) -> BrowserSplitEdge? {
        guard before != nil, info.hasItemsConforming(to: [SidebarTabDrag.contentType]) else { return nil }
        return BrowserSplitDropGeometry.sidebarEdge(at: info.location.x, width: rowWidth)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard let edge = splitEdge(for: info) else { setHover(nil); return nil }
        guard let drag = SidebarTabDrag.preview else { setHover(nil); return DropProposal(operation: .forbidden) }
        let old = hover?.wrappedValue
        let target = old?.drag == drag ? old?.target : before.flatMap(store.splitDropTarget)
        guard let target else { setHover(nil); return DropProposal(operation: .forbidden) }
        let valid = validateDrop(info: info) && store.canSplitDrop(drag, onto: target)
        setHover(SidebarSplitHover(drag: drag, target: target, edge: edge, valid: valid))
        return DropProposal(operation: valid ? .move : .forbidden)
    }

    func dropEntered(info: DropInfo) { _ = dropUpdated(info: info) }
    func dropExited(info: DropInfo) { setHover(nil) }

    private func setHover(_ value: SidebarSplitHover?) {
        if let hover, hover.wrappedValue != value { hover.wrappedValue = value }
    }

    func performDrop(info: DropInfo) -> Bool {
        let preview = hover?.wrappedValue
        setHover(nil)
        guard validateDrop(info: info) else { return false }
        let destination = store.space.id
        let profile = store.space.effectiveProfileID
        if let provider = info.itemProviders(for: [SidebarTabDrag.contentType]).first {
            let edge = splitEdge(for: info)
            if edge != nil {
                guard let preview, preview.drag == SidebarTabDrag.preview,
                      store.canSplitDrop(preview.drag, onto: preview.target) else { return false }
            }
            SidebarTabDrag.preview = nil
            provider.loadDataRepresentation(forTypeIdentifier: SidebarTabDrag.contentType.identifier) { data, _ in
                guard let drag = SidebarTabDrag.decode(data) else { return }
                Task { @MainActor in
                    if let edge, let preview {
                        if preview.drag == drag { store.performSplitDrop(drag, onto: preview.target, edge: edge) }
                    }
                    else { _ = accept(drag, in: destination, profile: profile) }
                }
            }
            return true
        }
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        provider.loadObject(ofClass: NSString.self) { value, _ in
            guard let text = value as? String, SidebarFolderDrag(text) != nil else { return }
            Task { @MainActor in
                _ = accept(text, in: destination, profile: profile)
            }
        }
        return true
    }

    @MainActor func accept(_ drag: SidebarTabDrag, in destination: UUID, profile: UUID) -> Bool {
        guard store.validatesSidebarDrag(drag) else { return false }
        return accept(drag.tabID.uuidString, in: destination, profile: profile)
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
