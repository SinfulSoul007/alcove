import AppKit
import BrowserCore

enum SidebarFolderError: LocalizedError {
    case invalidName, duplicate, missing, wrongProfile, missingTab, circularFolder
    var errorDescription:String? {
        switch self {
        case .invalidName: return "Use a folder name from 1 to 80 characters, without control characters."
        case .duplicate: return "A folder with that name already exists in this Space."
        case .missing: return "That folder is no longer in this Space."
        case .wrongProfile: return "Move this tab to the same profile before adding it to a folder."
        case .missingTab: return "That tab is no longer available."
        case .circularFolder: return "Choose a destination outside this folder."
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
    @discardableResult func createTabFolder(name: String, in spaceID: UUID, parent: String? = nil,
                                           adding id: UUID? = nil) throws -> String {
        let index = try requireManagedSpace(spaceID), source = session.spaces[index]
        let tree = SidebarFolderTree(space: source)
        if let parent, !tree.names.contains(parent) { throw SidebarFolderError.missing }
        let cleaned = try uniqueFolderName(name, in: source)
        var candidate = makeDocument()
        candidate.session.spaces[index].folders = tree.names + [cleaned]
        candidate.session.spaces[index].pinnedShelfCollapsed = nil
        if let parent {
            candidate.session.spaces[index].folderParents = tree.parents.merging([cleaned: parent]) { _, new in new }
        }
        if let id { try placeFolderTab(id, folder: cleaned, in: spaceID, candidate: &candidate) }
        try commitQuickDocument(candidate)
        return cleaned
    }

    func setPinnedShelfCollapsed(_ collapsed: Bool, in spaceID: UUID) throws {
        let index = try requireManagedSpace(spaceID)
        guard (session.spaces[index].pinnedShelfCollapsed == true) != collapsed else { return }
        var candidate = makeDocument()
        candidate.session.spaces[index].pinnedShelfCollapsed = collapsed ? true : nil
        try commitQuickDocument(candidate)
    }

    func requestPinnedShelfCollapsed(_ collapsed: Bool, in spaceID: UUID) {
        do { try setPinnedShelfCollapsed(collapsed, in: spaceID) }
        catch { message = error.localizedDescription }
    }

    func moveTabFolder(_ name: String, under parent: String?, in spaceID: UUID) throws {
        let index = try requireManagedSpace(spaceID)
        let tree = SidebarFolderTree(space: session.spaces[index])
        guard tree.names.contains(name), parent.map(tree.names.contains) ?? true else { throw SidebarFolderError.missing }
        guard tree.canMove(name, under: parent) else { throw SidebarFolderError.circularFolder }
        guard tree.parents[name] != parent else { return }
        var candidate = makeDocument(), parents = tree.parents
        parents[name] = parent
        candidate.session.spaces[index].folderParents = parents.isEmpty ? nil : parents
        try commitQuickDocument(candidate)
    }

    func renameTabFolder(_ name: String, to value: String, in spaceID: UUID) throws {
        let index = try requireManagedSpace(spaceID), source = session.spaces[index]
        let tree = SidebarFolderTree(space: source)
        guard tree.names.contains(name) else { throw SidebarFolderError.missing }
        let cleaned = try uniqueFolderName(value, in: source, excluding: name)
        guard cleaned != name else { return }
        var candidate = makeDocument(), updated = source
        updated.folders = tree.names.map { $0 == name ? cleaned : $0 }
        for index in updated.tabs.indices where updated.tabs[index].folder == name {
            updated.tabs[index].folder = cleaned
        }
        updated.collapsedFolders = source.collapsedFolders?.map { $0 == name ? cleaned : $0 }
        let parents = Dictionary(uniqueKeysWithValues: tree.parents.map { child, parent in
            (child == name ? cleaned : child, parent == name ? cleaned : parent)
        })
        updated.folderParents = parents.isEmpty ? nil : parents
        candidate.session.spaces[index] = updated
        try commitQuickDocument(candidate)
    }

    func removeTabFolder(_ name: String, in spaceID: UUID) throws {
        let index = try requireManagedSpace(spaceID), source = session.spaces[index]
        let tree = SidebarFolderTree(space: source)
        guard tree.names.contains(name) else { throw SidebarFolderError.missing }
        let parent = tree.parents[name]
        var candidate = makeDocument(), updated = source, parents = tree.parents
        updated.folders = tree.names.filter { $0 != name }
        for index in updated.tabs.indices where updated.tabs[index].folder == name {
            updated.tabs[index].folder = parent
        }
        for child in tree.children(of: name) { parents[child] = parent }
        parents.removeValue(forKey: name)
        updated.folderParents = parents.isEmpty ? nil : parents
        updated.collapsedFolders = source.collapsedFolders?.filter { $0 != name }
        candidate.session.spaces[index] = updated
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
