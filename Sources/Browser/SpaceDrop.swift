import SwiftUI
import UniformTypeIdentifiers

struct SpaceDrop: DropDelegate {
    let store: BrowserStore
    let target: UUID
    var midpoint: Double = 10
    func validateDrop(info:DropInfo) -> Bool { store.canModifyLocalMetadata && !store.profileDataOperationInProgress && info.hasItemsConforming(to:[.text]) }
    func performDrop(info:DropInfo) -> Bool {
        guard validateDrop(info:info),let provider = info.itemProviders(for:[.text]).first else { return false }
        let after = info.location.x > midpoint
        provider.loadObject(ofClass:NSString.self) { [weak store] value,_ in
            guard let text = value as? String else { return }
            Task { @MainActor in _ = store?.acceptSpaceDrop(text,target:target,after:after) }
        }
        return true
    }
}
