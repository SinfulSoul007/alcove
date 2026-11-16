import Foundation

public enum BrowserSplitAxis: String, Codable {
    case columns, rows

    public var flipped: Self { self == .columns ? .rows : .columns }
}

public struct BrowserSplitLayout: Codable, Equatable, Identifiable {
    public static let maximumPanes = 4
    public let id: UUID
    public let spaceID: UUID
    public var axis: BrowserSplitAxis
    public var tabIDs: [UUID]
    public var focusedTabID: UUID?

    public init(id: UUID = UUID(), spaceID: UUID, axis: BrowserSplitAxis, tabIDs: [UUID], focusedTabID: UUID? = nil) {
        self.id = id
        self.spaceID = spaceID
        self.axis = axis
        self.tabIDs = tabIDs
        self.focusedTabID = focusedTabID
    }

    public func neighbor(of removed: UUID, keeping available: (UUID) -> Bool) -> UUID? {
        guard let index = tabIDs.firstIndex(of: removed) else { return nil }
        return tabIDs.dropFirst(index + 1).first(where: available) ?? tabIDs.prefix(index).reversed().first(where: available)
    }

    public static func repairedGroups(_ groups: [Self], in spaces: [Space], keeping owned: (UUID) -> Bool) -> [Self] {
        guard !groups.isEmpty else { return [] }
        let requested = groups.reduce(into: [UUID: Set<UUID>]()) { result, group in
            result[group.spaceID, default: []].formUnion(group.tabIDs)
        }
        let tabsBySpace = spaces.reduce(into: [UUID: Set<UUID>]()) { result, space in
            guard let ids = requested[space.id] else { return }
            result[space.id] = Set(space.tabs.lazy.map(\.id).filter(ids.contains))
        }
        var usedGroups: Set<UUID> = []
        var usedTabs: Set<UUID> = []
        return groups.compactMap { source in
            guard !usedGroups.contains(source.id), let local = tabsBySpace[source.spaceID] else { return nil }
            var group = source
            var unique: Set<UUID> = []
            group.tabIDs = []
            for id in source.tabIDs where local.contains(id) && !usedTabs.contains(id) && owned(id) && unique.insert(id).inserted {
                group.tabIDs.append(id)
                if group.tabIDs.count == maximumPanes { break }
            }
            guard group.tabIDs.count >= 2 else { return nil }
            if let focus = group.focusedTabID, !group.tabIDs.contains(focus) { group.focusedTabID = nil }
            usedGroups.insert(group.id)
            usedTabs.formUnion(group.tabIDs)
            return group
        }
    }
}
