import SwiftUI
import UniformTypeIdentifiers
import BrowserCore

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
            guard let text = value as? String, let id = UUID(uuidString: text) else { return }
            Task { @MainActor in
                guard store.tab(id) != nil,let space = store.session.spaces.first(where:{$0.id == destination}),space.effectiveProfileID == profile else { return }
                if let folder,!space.folderNames.contains(folder) {return}
                if store.requestPlaceTab(id, in: destination, section: section, before: before, folder: folder) { store.selectAny(id) }
            }
        }
        return true
    }
}
