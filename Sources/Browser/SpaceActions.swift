import AppKit
import BrowserCore

extension BrowserStore {
    func requireSpaceProfile(_ profileID:UUID) throws {
        guard !isShuttingDown else { throw CancellationError() }
        guard canModifyLocalMetadata else { throw ProfileError.locked }
        guard !profileDataOperationInProgress else { throw ProfileError.busy }
        if isPrivate { guard profileID == BrowserProfile.defaultID else { throw ProfileError.privateMode }; return }
        guard profiles.contains(where:{$0.id == profileID}) else { throw ProfileError.missing }
        guard !profileUnavailable(profileID) else { throw ProfileError.pending }
    }
    func requireManagedSpace(_ id:UUID) throws -> Int {
        guard let index = session.spaces.firstIndex(where:{$0.id == id}) else { throw SpaceManagementError.missingSpace }
        try requireSpaceProfile(isPrivate ? BrowserProfile.defaultID : session.spaces[index].effectiveProfileID)
        return index
    }
    func canManageSpace(_ id:UUID) -> Bool { (try? requireManagedSpace(id)) != nil }
    private func commitSpaceDocument(_ candidate:BrowserDocument,discarding ids:[UUID] = [],resetting spaceID:UUID? = nil,beforePublish:(() -> Void)? = nil) throws {
        if isPrivate {
            let reset = spaceID == space.id || ids.contains(where:{$0 == splitID || $0 == selectedID})
            try commitQuickDocument(candidate,discarding:ids,beforePublish:{
                beforePublish?()
                if reset { self.splitID = nil; self.activePaneID = nil }
            })
        } else { try commitProfileDocument(candidate,discarding:ids,resetting:spaceID,beforePublish:beforePublish) }
    }
    @discardableResult func createSpace(name:String,profileID:UUID? = nil) throws -> UUID {
        let owner = isPrivate ? BrowserProfile.defaultID : (profileID ?? activeProfileID)
        try requireSpaceProfile(owner)
        var candidate = makeDocument(); SpaceSymbol.stabilize(in:&candidate.session)
        let position = min(spaceIndex + 1,candidate.session.spaces.count)
        var created = Space(name:try SpaceSymbol.cleanedName(name)); created.profileID = owner; created.icon = SpaceSymbol.defaultName(at:position)
        candidate.session.spaces.insert(created,at:position); candidate.session.activateSpace(created.id)
        try commitSpaceDocument(candidate,beforePublish:{ self.closePrimaryPeek(); self.splitID = nil; self.activePaneID = nil })
        return created.id
    }
    func renameSpace(_ id:UUID,name:String) throws {
        let index = try requireManagedSpace(id), cleaned = try SpaceSymbol.cleanedName(name)
        guard session.spaces[index].name != cleaned else { return }
        var candidate = makeDocument(); candidate.session.spaces[index].name = cleaned; try commitSpaceDocument(candidate)
    }
    func setSpaceIcon(_ id:UUID,icon:String) throws {
        let index = try requireManagedSpace(id)
        guard SpaceSymbol(rawValue:icon) != nil else { throw SpaceManagementError.invalidIcon }
        guard session.spaces[index].icon != icon else { return }
        var candidate = makeDocument(); candidate.session.spaces[index].icon = icon; try commitSpaceDocument(candidate)
    }
    func moveSpace(_ id:UUID,to position:Int) throws {
        let index = try requireManagedSpace(id)
        guard session.spaces.indices.contains(position) else { throw SpaceManagementError.invalidPosition }
        guard index != position else { return }
        var candidate = makeDocument(); SpaceSymbol.stabilize(in:&candidate.session)
        let moved = candidate.session.spaces.remove(at:index); candidate.session.spaces.insert(moved,at:position)
        try commitSpaceDocument(candidate)
    }
    @discardableResult func deleteSpace(_ id:UUID,now:Date = Date()) throws -> UUID {
        let index = try requireManagedSpace(id)
        let owner = isPrivate ? BrowserProfile.defaultID : session.spaces[index].effectiveProfileID
        var candidate = makeDocument(); SpaceSymbol.stabilize(in:&candidate.session)
        let removed = candidate.session.spaces.remove(at:index)
        var snapshot = removed; snapshot.profileID = owner; snapshot.tabs.removeAll {$0.favorite == true}
        if !snapshot.tabs.contains(where:{$0.id == snapshot.selected}) { snapshot.selected = snapshot.tabs.first?.id }
        let record = DeletedSpace(space:snapshot,originalIndex:index,deletedAt:now)
        var records = candidate.library(for:owner); records.deletedSpaces = [record] + (records.deletedSpaces ?? []); candidate.setLibrary(records,for:owner)
        if candidate.session.spaces.isEmpty {
            var replacement = Space(name:"Personal"); replacement.profileID = owner; replacement.icon = SpaceSymbol.defaultName(at:0)
            candidate.session.spaces = [replacement]; candidate.session.activateSpace(replacement.id)
        } else if candidate.session.selectedSpace == id {
            let same = candidate.session.spaces.first(where:{$0.effectiveProfileID == owner})
            candidate.session.activateSpace((same ?? candidate.session.spaces[min(index,candidate.session.spaces.count - 1)]).id)
        }
        try commitSpaceDocument(candidate,discarding:removed.tabs.filter{$0.favorite != true}.map(\.id),resetting:id)
        lastSpaceDeletion = DeletedSpaceReference(profileID:owner,recordID:record.id)
        message = "\(removed.name) moved to Recently Deleted. Saved tabs and pins can be restored."
        return record.id
    }
    @discardableResult func restoreDeletedSpace(_ recordID:UUID,profileID:UUID) throws -> UUID {
        try requireSpaceProfile(profileID)
        var candidate = makeDocument(); var records = candidate.library(for:profileID)
        guard let index = records.deletedSpaces?.firstIndex(where:{$0.id == recordID}),let record = records.deletedSpaces?[index] else { throw SpaceManagementError.missingSnapshot }
        SpaceSymbol.stabilize(in:&candidate.session)
        var restored = record.space; restored.profileID = profileID
        restored.name = (try? SpaceSymbol.cleanedName(restored.name)) ?? "Recovered Space"
        if candidate.session.spaces.contains(where:{$0.id == restored.id}) { restored.id = UUID() }
        var occupied = Set(candidate.session.spaces.flatMap(\.tabs).map(\.id)).union(views.keys)
        for library in candidate.profileLibraries ?? [] {
            occupied.formUnion((library.library.favoriteTabs ?? []).map(\.id)); occupied.formUnion((library.library.quickPages ?? []).map(\.id))
        }
        let previousSelected = restored.selected; var selectionMapped = false
        for tabIndex in restored.tabs.indices {
            let previousID = restored.tabs[tabIndex].id
            if !occupied.insert(previousID).inserted { restored.tabs[tabIndex].id = UUID(); occupied.insert(restored.tabs[tabIndex].id) }
            if previousID == previousSelected && !selectionMapped { restored.selected = restored.tabs[tabIndex].id; selectionMapped = true }
            // Favorites live in the profile library. A malformed old snapshot must not clone them.
            restored.tabs[tabIndex].favorite = nil
        }
        restored.icon = restored.icon ?? SpaceSymbol.defaultName(at:record.originalIndex)
        candidate.session.spaces.insert(restored,at:max(0,min(record.originalIndex,candidate.session.spaces.count)))
        candidate.session.activateSpace(restored.id)
        records.deletedSpaces?.remove(at:index); candidate.setLibrary(records,for:profileID)
        try commitSpaceDocument(candidate,beforePublish:{ self.closePrimaryPeek(); self.splitID = nil; self.activePaneID = nil })
        if lastSpaceDeletion == DeletedSpaceReference(profileID:profileID,recordID:recordID) { lastSpaceDeletion = nil }
        message = "\(restored.name) restored. Saved pages reopen with their original profile."
        return restored.id
    }
    func permanentlyDeleteSpace(_ recordID:UUID,profileID:UUID) throws {
        try requireSpaceProfile(profileID)
        var candidate = makeDocument(); var records = candidate.library(for:profileID)
        guard records.deletedSpaces?.contains(where:{$0.id == recordID}) == true else { throw SpaceManagementError.missingSnapshot }
        records.deletedSpaces?.removeAll {$0.id == recordID}; candidate.setLibrary(records,for:profileID)
        try commitSpaceDocument(candidate)
        if lastSpaceDeletion == DeletedSpaceReference(profileID:profileID,recordID:recordID) { lastSpaceDeletion = nil }
        message = "Deleted Space removed permanently."
    }
    var canUndoSpaceDeletion: Bool {
        guard let lastSpaceDeletion, (try? requireSpaceProfile(lastSpaceDeletion.profileID)) != nil else { return false }
        return library(for:lastSpaceDeletion.profileID).deletedSpaces?.contains(where:{$0.id == lastSpaceDeletion.recordID}) == true
    }
    @discardableResult func undoSpaceDeletion() -> Bool {
        guard let lastSpaceDeletion, canUndoSpaceDeletion else { return false }
        do { try restoreDeletedSpace(lastSpaceDeletion.recordID,profileID:lastSpaceDeletion.profileID); return true }
        catch { message = error.localizedDescription; return false }
    }
}
