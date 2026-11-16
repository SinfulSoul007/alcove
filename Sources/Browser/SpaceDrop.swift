import SwiftUI
import UniformTypeIdentifiers

struct SpaceDrop: DropDelegate {
    let store: BrowserStore
    let target: UUID
    var midpoint: Double = 10
    func validateDrop(info:DropInfo) -> Bool { store.canModifyLocalMetadata && !store.profileDataOperationInProgress && info.hasItemsConforming(to: SidebarTabDrag.dropTypes) }
    func performDrop(info:DropInfo) -> Bool {
        guard validateDrop(info: info) else { return false }
        let after = info.location.x > midpoint
        if let provider = info.itemProviders(for: [SidebarTabDrag.contentType]).first {
            guard let profile = store.session.spaces.first(where: { $0.id == target })?.effectiveProfileID else { return false }
            SidebarTabDrag.preview = nil
            provider.loadDataRepresentation(forTypeIdentifier: SidebarTabDrag.contentType.identifier) { [weak store] data, _ in
                guard let drag = SidebarTabDrag.decode(data) else { return }
                Task { @MainActor in
                    guard let store, store.validatesSidebarDrag(drag),
                          store.session.spaces.first(where: { $0.id == target })?.effectiveProfileID == profile else { return }
                    _ = store.acceptSpaceDrop(drag.tabID.uuidString, target: target, after: after)
                }
            }
            return true
        }
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        provider.loadObject(ofClass:NSString.self) { [weak store] value,_ in
            guard let text = value as? String, text.hasPrefix("alcove-space:") else { return }
            Task { @MainActor in _ = store?.acceptSpaceDrop(text,target:target,after:after) }
        }
        return true
    }
}
