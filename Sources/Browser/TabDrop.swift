import SwiftUI
import UniformTypeIdentifiers
import BrowserCore

struct TabDrop: DropDelegate {
    let store: BrowserStore
    let section: SidebarSection
    var before: UUID?
    var folder: String?
    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.text]) }
    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        provider.loadObject(ofClass: NSString.self) { value, _ in
            guard let text = value as? String, let id = UUID(uuidString: text) else { return }
            Task { @MainActor in
                guard store.tab(id) != nil else { return }
                if store.placeTab(id, in: store.space.id, section: section, before: before, folder: folder) { store.selectAny(id); store.save() }
            }
        }
        return true
    }
}
