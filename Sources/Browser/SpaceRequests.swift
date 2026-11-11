import AppKit
import BrowserCore

struct DeletedSpaceEntry: Identifiable {
    let profileID: UUID
    let record: DeletedSpace
    var id: String { profileID.uuidString + ":" + record.id.uuidString }
}
extension BrowserStore {
    var deletedSpaceEntries: [DeletedSpaceEntry] {
        profileLibraries.flatMap { entry in (entry.library.deletedSpaces ?? []).map { DeletedSpaceEntry(profileID:entry.profileID,record:$0) } }.sorted {$0.record.deletedAt > $1.record.deletedAt}
    }
    func showSpacesManager(deleted:Bool = false) {
        guard !isShuttingDown else { return }
        dismissCommand(); spacesShowingDeleted = deleted; presentedPanel = .spaces
    }
    func customizeSpace(_ id:UUID) {
        guard canManageSpace(id) else { return }
        selectSpace(id); presentedPanel = .appearance
    }
    func requestRenameSpace(_ id:UUID) {
        guard let index = try? requireManagedSpace(id) else { return }
        let owner = session.spaces[index].effectiveProfileID
        let alert = NSAlert(); alert.messageText = "Rename Space"; alert.informativeText = "Choose a name for \(session.spaces[index].name)."
        let field = NSTextField(string:session.spaces[index].name); field.frame = NSRect(x:0,y:0,width:300,height:24)
        alert.accessoryView = field; alert.addButton(withTitle:"Save"); alert.addButton(withTitle:"Cancel"); alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn,
              let current = session.spaces.first(where:{$0.id == id}), current.effectiveProfileID == owner else { return }
        do { try renameSpace(id,name:field.stringValue) } catch { message = error.localizedDescription }
    }
    func requestDeleteSpace(_ id:UUID) {
        guard let index = try? requireManagedSpace(id) else { return }
        let source = session.spaces[index]
        let alert = NSAlert(); alert.messageText = "Delete \(source.name)?"
        alert.informativeText = "Saved tabs, pins and the Space’s theme will move to Recently Deleted. Profile logins and Favorites stay intact. Unsaved forms and page state will close and cannot be restored."
        alert.addButton(withTitle:"Move to Recently Deleted"); alert.addButton(withTitle:"Cancel"); alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn,
              session.spaces.first(where:{$0.id == id})?.effectiveProfileID == source.effectiveProfileID else { return }
        do { try deleteSpace(id) } catch { message = error.localizedDescription }
    }
    func requestPermanentlyDeleteSpace(_ recordID:UUID,profileID:UUID) {
        guard (try? requireSpaceProfile(profileID)) != nil,
              let record = library(for:profileID).deletedSpaces?.first(where:{$0.id == recordID}) else { return }
        let alert = NSAlert(); alert.messageText = "Permanently delete \(record.space.name)?"
        alert.informativeText = "This removes this saved Space and its recovery copy of tabs, pins and theme. This cannot be undone. Other Spaces, profile logins and Favorites are kept."
        alert.addButton(withTitle:"Delete Permanently"); alert.addButton(withTitle:"Cancel"); alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try permanentlyDeleteSpace(recordID,profileID:profileID) } catch { message = error.localizedDescription }
    }
    @discardableResult func acceptSpaceDrop(_ text:String,target:UUID,after:Bool) -> Bool {
        guard !isShuttingDown,canModifyLocalMetadata,!profileDataOperationInProgress,
              let targetIndex = session.spaces.firstIndex(where:{$0.id == target}) else { return false }
        if text.hasPrefix("alcove-space:"),let id = UUID(uuidString:String(text.dropFirst("alcove-space:".count))),
           let sourceIndex = session.spaces.firstIndex(where:{$0.id == id}) {
            if id == target { return true }
            let insertion = targetIndex + (after ? 1 : 0)
            let position = insertion - (sourceIndex < insertion ? 1 : 0)
            do { try moveSpace(id,to:max(0,min(position,session.spaces.count - 1))); return true }
            catch { message = error.localizedDescription; return false }
        }
        if let tabID = UUID(uuidString:text),tab(tabID) != nil { return requestMoveTab(tabID,to:target) }
        return false
    }
}
