import AppKit
import BrowserCore

extension BrowserStore {
    private func folderPrompt(title:String,value:String = "",action:String) -> String? {
        let alert = NSAlert();alert.messageText = title;alert.informativeText = "Folders organize the pinned tabs in this Space."
        let field = NSTextField(string:value);field.placeholderString = "Folder name";field.frame = NSRect(x:0,y:0,width:280,height:24)
        alert.accessoryView = field;alert.addButton(withTitle:action);alert.addButton(withTitle:"Cancel");alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else {return nil}
        return field.stringValue
    }
    func requestNewTabFolder(in target:UUID? = nil,adding id:UUID? = nil) {
        let spaceID = target ?? space.id
        guard let index = try? requireManagedSpace(spaceID) else {return}
        let owner = session.spaces[index].effectiveProfileID
        let source = id.flatMap {tabID in session.spaces.first(where:{$0.tabs.contains(where:{$0.id == tabID})})?.id}
        guard let name = folderPrompt(title:"New Folder",action:"Create Folder") else {return}
        guard session.spaces.first(where:{$0.id == spaceID})?.effectiveProfileID == owner else {message = "This Space changed profiles. Try again.";return}
        if let id {
            guard profileID(for:id) == owner,session.spaces.first(where:{$0.tabs.contains(where:{$0.id == id})})?.id == source else {message = "The source tab changed. Try again.";return}
        }
        do {_ = try createTabFolder(name:name,in:spaceID,adding:id)} catch {message = error.localizedDescription}
    }
    func requestRenameTabFolder(_ name:String,in spaceID:UUID) {
        guard let index = try? requireManagedSpace(spaceID) else {return}
        let owner = session.spaces[index].effectiveProfileID
        guard let value = folderPrompt(title:"Rename Folder",value:name,action:"Rename") else {return}
        guard session.spaces.first(where:{$0.id == spaceID})?.effectiveProfileID == owner else {message = "This Space changed profiles. Try again.";return}
        do {try renameTabFolder(name,to:value,in:spaceID)} catch {message = error.localizedDescription}
    }
}
