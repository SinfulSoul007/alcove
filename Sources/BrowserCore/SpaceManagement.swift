import Foundation

public struct DeletedSpace: Codable, Identifiable, Equatable {
    public var id: UUID
    public var space: Space
    public var originalIndex: Int
    public var deletedAt: Date
    // Acknowledges one collision repair, so a later deliberate route selection stays valid.
    public var routingCollisionHandled: Bool?
    public init(space:Space,originalIndex:Int,deletedAt:Date = Date()) {
        id = UUID(); self.space = space; self.originalIndex = originalIndex; self.deletedAt = deletedAt
    }
}

extension DeletedSpace {
    static func uniqueSnapshots(_ records:[DeletedSpace]) -> [DeletedSpace] {
        var result:[DeletedSpace] = []
        for var record in records {
            if let index = result.firstIndex(where:{$0.space == record.space && $0.originalIndex == record.originalIndex && $0.deletedAt == record.deletedAt}) {
                if record.routingCollisionHandled == true { result[index].routingCollisionHandled = true }
                continue
            }
            while result.contains(where:{$0.id == record.id}) { record.id = UUID() }
            result.append(record)
        }
        return result
    }
}

extension BrowserDocument {
    public func hasUnhandledSpaceRoutingCollision(_ id:UUID) -> Bool {
        session.spaces.contains(where:{$0.id == id}) && (profileLibraries ?? []).contains { entry in
            (entry.library.deletedSpaces ?? []).contains {$0.space.id == id && $0.routingCollisionHandled != true}
        }
    }
    /// Keep matching routes enabled but unavailable rather than silently selecting either account.
    @discardableResult public mutating func protectDeletedSpaceRoutes() -> Bool {
        let live = Set(session.spaces.map(\.id))
        var ambiguous = Set<UUID>()
        for index in (profileLibraries ?? []).indices {
            for recordIndex in (profileLibraries![index].library.deletedSpaces ?? []).indices {
                let record = profileLibraries![index].library.deletedSpaces![recordIndex]
                if live.contains(record.space.id) && record.routingCollisionHandled != true {
                    ambiguous.insert(record.space.id)
                    profileLibraries![index].library.deletedSpaces![recordIndex].routingCollisionHandled = true
                }
            }
        }
        guard !ambiguous.isEmpty else { return false }
        var occupied = live.union((profileLibraries ?? []).flatMap { ($0.library.deletedSpaces ?? []).map { $0.space.id } })
        var unavailable:[UUID:UUID] = [:]
        for id in ambiguous {
            var replacement = UUID(); while occupied.contains(replacement) { replacement = UUID() }
            occupied.insert(replacement); unavailable[id] = replacement
        }
        func repaired(_ destination:LinkDestination) -> LinkDestination {
            if case .space(let id) = destination, let replacement = unavailable[id] { return .space(replacement) }
            return destination
        }
        preferences.linkRules = preferences.linkRules?.map { var rule = $0; rule.destination = repaired(rule.destination); return rule }
        if let destination = preferences.linkDefaultDestination { preferences.linkDefaultDestination = repaired(destination) }
        library = self.library(for:BrowserProfile.defaultID)
        return true
    }
}
public struct DeletedSpaceReference: Equatable, Hashable {
    public var profileID: UUID
    public var recordID: UUID
    public init(profileID:UUID,recordID:UUID) { self.profileID = profileID; self.recordID = recordID }
}
public enum SpaceManagementError: LocalizedError {
    case missingSpace, missingSnapshot, emptyName, invalidIcon, invalidPosition
    public var errorDescription: String? {
        switch self {
        case .missingSpace: return "This Space no longer exists."
        case .missingSnapshot: return "This deleted Space is no longer available to restore."
        case .emptyName: return "Give this Space a name."
        case .invalidIcon: return "Choose one of the available Space icons."
        case .invalidPosition: return "This Space’s position changed. Try moving it again."
        }
    }
}
public enum SpaceSymbol: String, CaseIterable, Identifiable {
    case circle = "circle.fill", moon = "moon.fill", leaf = "leaf.fill", sun = "sun.max.fill", star = "star.fill", square = "square.fill"
    case work = "briefcase.fill", sparkles, study = "graduationcap.fill", code = "chevron.left.forwardslash.chevron.right", heart = "heart.fill", globe, travel = "paperplane.fill"
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .circle: return "Circle"
        case .moon: return "Moon"
        case .leaf: return "Leaf"
        case .sun: return "Sun"
        case .star: return "Star"
        case .square: return "Square"
        case .work: return "Work"
        case .sparkles: return "Sparkles"
        case .study: return "Study"
        case .code: return "Code"
        case .heart: return "Heart"
        case .globe: return "Globe"
        case .travel: return "Travel"
        }
    }
    public static func defaultName(at index:Int) -> String {
        let initial:[SpaceSymbol] = [.circle,.moon,.leaf,.sun,.star,.square]
        return initial[max(0,index) % initial.count].rawValue
    }
    public static func stabilize(in session:inout Session) {
        for index in session.spaces.indices where session.spaces[index].icon == nil { session.spaces[index].icon = defaultName(at:index) }
    }
    public static func cleanedName(_ name:String) throws -> String {
        let value = String(name.trimmingCharacters(in:.whitespacesAndNewlines).prefix(60))
        guard !value.isEmpty else { throw SpaceManagementError.emptyName }; return value
    }
}
