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
    public var tabIDs: [UUID] {
        didSet {
            if tabIDs != oldValue { paneFractions = nil }
        }
    }
    public var focusedTabID: UUID?
    public private(set) var paneFractions: [Double]?

    public init(id: UUID = UUID(), spaceID: UUID, axis: BrowserSplitAxis, tabIDs: [UUID], focusedTabID: UUID? = nil) {
        self.id = id
        self.spaceID = spaceID
        self.axis = axis
        self.tabIDs = tabIDs
        self.focusedTabID = focusedTabID
    }

    private enum CodingKeys: CodingKey { case id, spaceID, axis, tabIDs, focusedTabID, paneFractions }

    public init(from decoder: Decoder) throws {
        let source = try decoder.container(keyedBy: CodingKeys.self)
        id = try source.decode(UUID.self, forKey: .id)
        spaceID = try source.decode(UUID.self, forKey: .spaceID)
        axis = try source.decode(BrowserSplitAxis.self, forKey: .axis)
        tabIDs = try source.decode([UUID].self, forKey: .tabIDs)
        focusedTabID = try source.decodeIfPresent(UUID.self, forKey: .focusedTabID)
        if let fractions = try? source.decode([Double].self, forKey: .paneFractions),
           (2...Self.maximumPanes).contains(fractions.count),
           fractions.count == tabIDs.count, fractions.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 1 }),
           abs(fractions.reduce(0, +) - 1) < 1e-8 {
            paneFractions = fractions
        }
    }

    @discardableResult
    public mutating func rememberPaneSizes(_ lengths: [Double]) -> Bool {
        let total = lengths.reduce(0, +)
        guard lengths.count == tabIDs.count, (2...Self.maximumPanes).contains(lengths.count),
              total.isFinite, lengths.allSatisfy({ $0.isFinite && $0 > 0 }) else { return false }
        let fractions = lengths.map { $0 / total }
        guard fractions.allSatisfy({ $0 > 0 }) else { return false }
        paneFractions = fractions
        return true
    }

    public func fittedPaneLengths(available: Double, minimum: Double) -> [Double]? {
        guard let fractions = paneFractions, !fractions.isEmpty,
              available.isFinite, available > 0, minimum.isFinite else { return nil }
        let minimumLength = min(max(0, minimum), available / Double(fractions.count))
        var remaining = available
        var indices = Array(fractions.indices)
        var lengths = Array(repeating: minimumLength, count: fractions.count)
        while !indices.isEmpty {
            let weight = indices.reduce(0) { $0 + fractions[$1] }
            let fitted = indices.filter { remaining * (fractions[$0] / weight) >= minimumLength }
            if fitted == indices {
                for index in fitted { lengths[index] = remaining * (fractions[index] / weight) }
                break
            }
            remaining -= Double(indices.count - fitted.count) * minimumLength
            indices = fitted
        }
        return lengths
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
            var tabs: [UUID] = []
            for id in source.tabIDs where local.contains(id) && !usedTabs.contains(id) && owned(id) && unique.insert(id).inserted {
                tabs.append(id)
                if tabs.count == maximumPanes { break }
            }
            guard tabs.count >= 2 else { return nil }
            group.tabIDs = tabs
            if let focus = group.focusedTabID, !group.tabIDs.contains(focus) { group.focusedTabID = nil }
            usedGroups.insert(group.id)
            usedTabs.formUnion(group.tabIDs)
            return group
        }
    }
}
