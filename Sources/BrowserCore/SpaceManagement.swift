import Foundation

public struct DeletedSpace: Codable, Identifiable, Equatable {
    public var id: UUID
    public var space: Space
    public var originalIndex: Int
    public var deletedAt: Date
    public init(space:Space,originalIndex:Int,deletedAt:Date = Date()) {
        id = UUID(); self.space = space; self.originalIndex = originalIndex; self.deletedAt = deletedAt
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
