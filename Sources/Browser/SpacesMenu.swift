import AppKit
import BrowserCore

extension AppDelegate {
    func menuNeedsUpdate(_ menu:NSMenu) { if menu === spacesMenu { rebuildSpacesMenu(menu) } }
    func rebuildSpacesMenu(_ menu:NSMenu) {
        menu.removeAllItems()
        func add(_ title:String,_ action:Selector) { let item = NSMenuItem(title:title,action:action,keyEquivalent:""); item.target = self; menu.addItem(item) }
        add("New Space…",#selector(newSpace)); add("Manage Spaces…",#selector(manageSpaces)); add("Recently Deleted Spaces",#selector(recentlyDeletedSpaces))
        menu.addItem(.separator()); add("Rename Space…",#selector(renameCurrentSpace)); add("Move Space Left",#selector(moveCurrentSpaceLeft)); add("Move Space Right",#selector(moveCurrentSpaceRight)); add("Delete Space…",#selector(deleteCurrentSpace)); add("Undo Space Deletion",#selector(undoSpaceDeletion))
        guard let store = activeStore ?? normalOwner?.store,!store.awaitingInitialMetadata else { return }
        menu.addItem(.separator())
        for space in store.session.spaces {
            let profile = store.profiles.first(where:{$0.id == space.effectiveProfileID})?.name ?? "Profile"
            let title = store.isPrivate ? space.name : String(space.name.prefix(40)) + " · " + String(profile.prefix(20))
            let item = NSMenuItem(title:title,action:#selector(selectSpaceMenu(_:)),keyEquivalent:"")
            item.target = self; item.representedObject = space.id; item.state = store.session.selectedSpace == space.id ? .on : .off
            item.toolTip = store.isPrivate ? space.name : space.name + " · " + profile
            menu.addItem(item)
        }
    }
    @objc func manageSpaces() { primaryForActive().showSpacesManager() }
    @objc func recentlyDeletedSpaces() { primaryForActive().showSpacesManager(deleted:true) }
    @objc func renameCurrentSpace() { guard activeQuick == nil,let store = activeStore else { return }; store.requestRenameSpace(store.space.id) }
    @objc func deleteCurrentSpace() { guard activeQuick == nil,let store = activeStore else { return }; store.requestDeleteSpace(store.space.id) }
    @objc func undoSpaceDeletion() { _ = activeStore?.undoSpaceDeletion() }
    @objc func moveCurrentSpaceLeft() { moveCurrentSpace(-1) }
    @objc func moveCurrentSpaceRight() { moveCurrentSpace(1) }
    private func moveCurrentSpace(_ offset:Int) {
        guard activeQuick == nil,let store = activeStore else { return }
        do { try store.moveSpace(store.space.id,to:store.spaceIndex + offset) } catch { store.message = error.localizedDescription }
    }
    @objc func selectSpaceMenu(_ sender:NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        let store = primaryForActive()
        guard store.session.spaces.contains(where:{$0.id == id}) else { return }
        store.selectSpace(id)
    }
}
