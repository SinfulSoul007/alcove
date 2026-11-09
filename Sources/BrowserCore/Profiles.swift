import Foundation

public enum MetadataFormatError: LocalizedError {
    case unsupportedVersion
    public var errorDescription: String? { "This data needs a different version of Alcove. Update Alcove before opening it. Existing files were kept." }
}

public struct BrowserProfile: Codable, Identifiable, Equatable {
    public static let defaultID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    public static let zeroID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    public static var defaultProfile: BrowserProfile { BrowserProfile(id: defaultID, name: "Default") }
    public var id: UUID
    public var name: String
    public var icon: String
    public var pendingDeletion: Bool?
    public var pendingDataClear: Bool?
    public var isDefault: Bool { id == Self.defaultID }
    public var isPendingDeletion: Bool { pendingDeletion == true }
    public var isPendingClear: Bool { pendingDataClear == true }
    public init(id: UUID = UUID(), name: String, icon: String = "person.crop.circle") {
        self.id = id; self.name = Self.cleanedName(name); self.icon = icon; pendingDeletion = false; pendingDataClear = false
    }
    public static func cleanedName(_ name: String) -> String {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        return trimmed.isEmpty ? "Profile" : trimmed
    }
}

public struct ProfileLibrary: Codable, Identifiable {
    public var profileID: UUID
    public var library: BrowserLibrary
    public var id: UUID { profileID }
    public init(profileID: UUID, library: BrowserLibrary = BrowserLibrary()) { self.profileID = profileID; self.library = library }
}

extension Space {
    public var effectiveProfileID: UUID { profileID ?? BrowserProfile.defaultID }
}

extension BrowserDocument {
    public func library(for profileID: UUID) -> BrowserLibrary {
        profileLibraries?.first(where: { $0.profileID == profileID })?.library ?? (profileID == BrowserProfile.defaultID ? library : BrowserLibrary())
    }
    public mutating func setLibrary(_ value: BrowserLibrary, for profileID: UUID) {
        var entries = profileLibraries ?? []
        if let index = entries.firstIndex(where: { $0.profileID == profileID }) { entries[index].library = value }
        else { entries.append(ProfileLibrary(profileID: profileID, library: value)) }
        profileLibraries = entries
        if profileID == BrowserProfile.defaultID { library = value }
    }
    /// Repair metadata without moving an existing valid profile to another cookie store.
    public mutating func repairProfiles() throws {
        guard formatVersion == nil || formatVersion == 1 || formatVersion == 2 || formatVersion == 3 else { throw MetadataFormatError.unsupportedVersion }
        formatVersion = 3
        let replacementForZero = UUID()
        func valid(_ id: UUID) -> UUID { id == BrowserProfile.zeroID ? replacementForZero : id }
        var registry = profiles ?? []
        for index in registry.indices { registry[index].id = valid(registry[index].id); registry[index].name = BrowserProfile.cleanedName(registry[index].name) }
        for index in session.spaces.indices {
            if let id = session.spaces[index].profileID { session.spaces[index].profileID = valid(id) }
        }
        var spaceIDs = Set<UUID>(); var tabIDs = Set<UUID>()
        for index in session.spaces.indices {
            if !spaceIDs.insert(session.spaces[index].id).inserted { session.spaces[index].id = UUID(); spaceIDs.insert(session.spaces[index].id) }
            var localIDs = Set<UUID>()
            for tabIndex in session.spaces[index].tabs.indices {
                let old = session.spaces[index].tabs[tabIndex].id
                let firstInSpace = localIDs.insert(old).inserted
                if !tabIDs.insert(old).inserted {
                    let replacement = UUID(); session.spaces[index].tabs[tabIndex].id = replacement; tabIDs.insert(replacement)
                    if firstInSpace && session.spaces[index].selected == old { session.spaces[index].selected = replacement }
                }
            }
        }
        var entries = profileLibraries ?? []
        for index in entries.indices { entries[index].profileID = valid(entries[index].profileID) }
        let referenced = [BrowserProfile.defaultID] + registry.map(\.id) + session.spaces.map(\.effectiveProfileID) + entries.map(\.profileID)
        var ids: [UUID] = []
        for id in referenced where !ids.contains(id) { ids.append(id) }
        profiles = ids.map { id in
            var result = registry.first(where: { $0.id == id }) ?? (id == BrowserProfile.defaultID ? .defaultProfile : BrowserProfile(id: id, name: "Recovered Profile"))
            if registry.contains(where: { $0.id == id && $0.isPendingDeletion }) { result.pendingDeletion = true }
            if registry.contains(where: { $0.id == id && $0.isPendingClear }) { result.pendingDataClear = true }
            if id == BrowserProfile.defaultID { result.pendingDeletion = false }
            return result
        }
        profileLibraries = ids.map { id in
            let matching = entries.filter { $0.profileID == id }
            var result = matching.first?.library ?? (id == BrowserProfile.defaultID ? library : BrowserLibrary())
            for duplicate in matching.dropFirst() { result.mergePreservingRecords(duplicate.library) }
            return ProfileLibrary(profileID: id, library: result)
        }
        // Favorites belong to a profile, even when it has no associated Space.
        var favoriteOwners: [UUID: UUID] = [:]
        let liveOwners = Dictionary(uniqueKeysWithValues: session.spaces.flatMap { space in space.tabs.map { ($0.id, space.effectiveProfileID) } })
        let liveFavorites = Set(session.spaces.flatMap(\.tabs).filter { $0.favorite == true }.map(\.id))
        for index in (profileLibraries ?? []).indices {
            let owner = profileLibraries![index].profileID
            var favorites = profileLibraries![index].library.favoriteTabs ?? []
            let live = session.spaces.filter { $0.effectiveProfileID == owner }.flatMap(\.tabs).filter { $0.favorite == true }
            for tab in live {
                if let existing = favorites.firstIndex(where: { $0.id == tab.id }) { favorites[existing] = tab }
                else { favorites.append(tab) }
            }
            var normalized: [Tab] = []
            for var tab in favorites {
                if normalized.contains(tab) { continue }
                if favoriteOwners[tab.id] != nil || liveOwners[tab.id].map({ $0 != owner || !liveFavorites.contains(tab.id) }) == true { tab.id = UUID() }
                tab.favorite = true; tab.pinned = true; tab.folder = nil
                tab.homeURL = tab.homeURL ?? tab.url; tab.pinnedTitle = tab.pinnedTitle ?? tab.title
                favoriteOwners[tab.id] = owner; normalized.append(tab)
                for s in session.spaces.indices where session.spaces[s].effectiveProfileID == owner {
                    if let t = session.spaces[s].tabs.firstIndex(where: { $0.id == tab.id }) { session.spaces[s].tabs[t] = tab }
                }
            }
            profileLibraries![index].library.favoriteTabs = normalized
        }
        var occupied = Set(session.spaces.flatMap(\.tabs).map(\.id)).union(favoriteOwners.keys)
        for index in (profileLibraries ?? []).indices {
            let owner = profileLibraries![index].profileID
            var normalized: [QuickPage] = []; var originals: [QuickPage] = []
            for original in profileLibraries![index].library.quickPages ?? [] {
                if originals.contains(original) { continue }
                originals.append(original); var page = original
                if !occupied.insert(page.id).inserted { page.tab.id = UUID(); occupied.insert(page.id) }
                page.tab.pinned = false; page.tab.favorite = nil; page.tab.folder = nil
                page.tab.homeURL = nil; page.tab.pinnedTitle = nil
                if !session.spaces.contains(where: { $0.id == page.intendedSpaceID && $0.effectiveProfileID == owner }) { page.intendedSpaceID = nil }
                normalized.append(page)
            }
            profileLibraries![index].library.quickPages = normalized
        }
        let choices = (preferences.quickDomainChoices ?? []).map { choice in QuickDomainChoice(host: choice.host, profileID: valid(choice.profileID)) }
        preferences.quickDomainChoices = QuickBrowseRouting.repairedChoices(choices, knownProfiles: Set(ids))
        if let recent = session.lastUsedSpaces {
            session.lastUsedSpaces = recent.filter { owner, spaceID in
                ids.contains(owner) && session.spaces.contains { $0.id == spaceID && $0.effectiveProfileID == owner }
            }
        }
        library = self.library(for: BrowserProfile.defaultID)
    }
}

extension BrowserLibrary {
    public mutating func mergePreservingRecords(_ other: BrowserLibrary) {
        func pages(_ current: [PageRecord], _ incoming: [PageRecord]) -> [PageRecord] {
            var result = current
            for var record in incoming where !result.contains(record) {
                if result.contains(where: { $0.id == record.id }) { record.id = UUID() }
                result.append(record)
            }
            return result
        }
        func tabs(_ current: [Tab], _ incoming: [Tab]) -> [Tab] {
            var result = current
            for var tab in incoming where !result.contains(tab) {
                if result.contains(where: { $0.id == tab.id }) { tab.id = UUID() }
                result.append(tab)
            }
            return result
        }
        if quickPages != nil || other.quickPages != nil {
            var merged = quickPages ?? []; var originals = merged
            for original in other.quickPages ?? [] {
                if originals.contains(original) { continue }
                originals.append(original); var page = original
                if merged.contains(where: { $0.id == page.id }) { page.tab.id = UUID() }
                merged.append(page)
            }
            quickPages = merged
        }
        if favoriteTabs != nil || other.favoriteTabs != nil { favoriteTabs = tabs(favoriteTabs ?? [], other.favoriteTabs ?? []) }
        bookmarks = pages(bookmarks, other.bookmarks); history = pages(history, other.history)
        closedTabs = tabs(closedTabs, other.closedTabs); archive = tabs(archive, other.archive)
    }
}
