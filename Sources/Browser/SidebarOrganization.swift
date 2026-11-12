import AppKit
import BrowserCore

enum SidebarFolderError: LocalizedError {
    case invalidName, duplicate, missing, wrongProfile, missingTab
    var errorDescription:String? {
        switch self {
        case .invalidName: return "Use a folder name from 1 to 80 characters, without control characters."
        case .duplicate: return "A folder with that name already exists in this Space."
        case .missing: return "That folder is no longer in this Space."
        case .wrongProfile: return "Move this tab to the same profile before adding it to a folder."
        case .missingTab: return "That tab is no longer available."
        }
    }
}

extension BrowserStore {
    /// Commit both saved representations before publishing; a live website never changes owner or configuration.
    func saveSidebarBookmark(title:String,url:String,profileID:UUID,spaceID:UUID?,existingTabID:UUID?) throws {
        guard !isPrivate else {throw ProfileError.privateMode}
        try requireSpaceProfile(profileID)
        var candidate = makeDocument(),records = candidate.library(for:profileID)
        records.bookmark(title:title,url:url)
        if let id = existingTabID,let s = candidate.session.spaces.firstIndex(where:{$0.tabs.contains(where:{$0.id == id})}),
           let t = candidate.session.spaces[s].tabs.firstIndex(where:{$0.id == id}) {
            guard candidate.session.spaces[s].effectiveProfileID == profileID else {throw SidebarFolderError.wrongProfile}
            candidate.session.spaces[s].tabs[t].pinned = true
            candidate.session.spaces[s].tabs[t].homeURL = candidate.session.spaces[s].tabs[t].homeURL ?? url
            candidate.session.spaces[s].tabs[t].pinnedTitle = candidate.session.spaces[s].tabs[t].pinnedTitle ?? title
        } else if !((records.favoriteTabs ?? []).contains(where:{$0.id == existingTabID || $0.homeURL == url || $0.url == url})) {
            let s:Int
            if let existing = candidate.session.spaces.firstIndex(where:{$0.id == spaceID && $0.effectiveProfileID == profileID}) {s = existing}
            else if let existing = candidate.session.spaces.firstIndex(where:{$0.effectiveProfileID == profileID}) {s = existing}
            else {
                var created = Space(name:profiles.first(where:{$0.id == profileID})?.name ?? "Saved Pages");created.profileID = profileID
                candidate.session.spaces.append(created);s = candidate.session.spaces.count - 1
            }
            if !candidate.session.spaces[s].tabs.contains(where:{$0.pinned && ($0.homeURL == url || $0.url == url)}) {
                var pin = BrowserCore.Tab(title:title,url:url,pinned:true);pin.homeURL = url;pin.pinnedTitle = title
                candidate.session.spaces[s].tabs.append(pin)
            }
        }
        candidate.setLibrary(records,for:profileID)
        try commitQuickDocument(candidate);message = "Bookmarked and saved to Pinned."
    }
    private func cleanFolderName(_ value:String) throws -> String {
        let name = value.trimmingCharacters(in:.whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard !name.isEmpty, name.count <= 80, !name.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) else { throw SidebarFolderError.invalidName }
        return name
    }
    private func uniqueFolderName(_ value:String,in space:Space,excluding:String? = nil) throws -> String {
        let name = try cleanFolderName(value)
        guard !space.folderNames.contains(where:{$0 != excluding && $0.compare(name,options:[.caseInsensitive,.diacriticInsensitive]) == .orderedSame}) else {throw SidebarFolderError.duplicate}
        return name
    }
    @discardableResult func createTabFolder(name:String,in spaceID:UUID,adding id:UUID? = nil) throws -> String {
        let index = try requireManagedSpace(spaceID),cleaned = try uniqueFolderName(name,in:session.spaces[index])
        var candidate = makeDocument();candidate.session.spaces[index].folders = session.spaces[index].folderNames + [cleaned]
        if let id {try placeFolderTab(id,folder:cleaned,in:spaceID,candidate:&candidate)}
        try commitQuickDocument(candidate);return cleaned
    }
    func renameTabFolder(_ name:String,to value:String,in spaceID:UUID) throws {
        let index = try requireManagedSpace(spaceID),source = session.spaces[index]
        guard source.folderNames.contains(name) else {throw SidebarFolderError.missing}
        let cleaned = try uniqueFolderName(value,in:source,excluding:name)
        var candidate = makeDocument();candidate.session.spaces[index].folders = source.folderNames.map {$0 == name ? cleaned : $0}
        for t in candidate.session.spaces[index].tabs.indices where candidate.session.spaces[index].tabs[t].folder == name {candidate.session.spaces[index].tabs[t].folder = cleaned}
        candidate.session.spaces[index].collapsedFolders = source.collapsedFolders?.map {$0 == name ? cleaned : $0}
        try commitQuickDocument(candidate)
    }
    func removeTabFolder(_ name:String,in spaceID:UUID) throws {
        let index = try requireManagedSpace(spaceID),source = session.spaces[index]
        guard source.folderNames.contains(name) else {throw SidebarFolderError.missing}
        var candidate = makeDocument();candidate.session.spaces[index].folders = source.folderNames.filter {$0 != name}
        for t in candidate.session.spaces[index].tabs.indices where candidate.session.spaces[index].tabs[t].folder == name {candidate.session.spaces[index].tabs[t].folder = nil}
        candidate.session.spaces[index].collapsedFolders = source.collapsedFolders?.filter {$0 != name}
        try commitQuickDocument(candidate)
    }
    func setTabFolderExpanded(_ name:String,expanded:Bool,in spaceID:UUID) throws {
        let index = try requireManagedSpace(spaceID)
        guard session.spaces[index].folderNames.contains(name) else {throw SidebarFolderError.missing}
        var candidate = makeDocument(),collapsed = session.spaces[index].collapsedFolders ?? []
        collapsed.removeAll {$0 == name};if !expanded {collapsed.append(name)}
        candidate.session.spaces[index].collapsedFolders = collapsed;try commitQuickDocument(candidate)
    }
    func moveTabToFolder(_ id:UUID,folder:String?,in spaceID:UUID) throws {
        var candidate = makeDocument();try placeFolderTab(id,folder:folder,in:spaceID,candidate:&candidate)
        try commitQuickDocument(candidate)
    }
    private func placeFolderTab(_ id:UUID,folder:String?,in spaceID:UUID,candidate:inout BrowserDocument) throws {
        let index = try requireManagedSpace(spaceID),destination = candidate.session.spaces[index]
        guard let original = tab(id),let owner = profileID(for:id),quickPage(id) == nil,!original.url.isEmpty else {throw SidebarFolderError.missingTab}
        try requireSpaceProfile(owner)
        guard isPrivate || owner == destination.effectiveProfileID else {throw SidebarFolderError.wrongProfile}
        if let folder {guard destination.folderNames.contains(folder) else {throw SidebarFolderError.missing}}
        if !candidate.session.spaces.contains(where:{$0.tabs.contains(where:{$0.id == id})}) {candidate.session.spaces[index].tabs.append(original)}
        candidate.session.placeTab(id,in:spaceID,section:.pinned)
        guard let t = candidate.session.spaces[index].tabs.firstIndex(where:{$0.id == id}) else {throw SidebarFolderError.missingTab}
        candidate.session.spaces[index].tabs[t].folder = folder
        var records = candidate.library(for:owner);records.favoriteTabs?.removeAll {$0.id == id};candidate.setLibrary(records,for:owner)
    }
}
