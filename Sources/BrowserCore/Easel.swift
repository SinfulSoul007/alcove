import Foundation

public enum EaselError: LocalizedError {
    case invalidFrame, invalidContent, invalidTitle, invalidDate, tooManyItems
    case duplicateItem, missingItem, invalidOrder, staleRevision
    public var errorDescription: String? {
        switch self {
        case .invalidFrame: return "Keep each item inside the canvas with a usable size."
        case .invalidContent: return "This canvas item contains unsupported or oversized content."
        case .invalidTitle: return "Give this canvas a title of at most 256 UTF-8 bytes."
        case .invalidDate: return "This canvas has an invalid modification date."
        case .tooManyItems: return "This canvas already has 500 items. Create another canvas to collect more."
        case .duplicateItem: return "This canvas contains conflicting item identities."
        case .missingItem: return "This canvas item is no longer available."
        case .invalidOrder: return "The layer order no longer matches this canvas."
        case .staleRevision: return "This canvas changed in another editor. Reopen it before editing."
        }
    }
}

public struct EaselFrame: Codable, Equatable, Sendable {
    public static let canvasSize: Double = 16384
    public let x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) throws {
        guard [x, y, width, height].allSatisfy(\.isFinite), x >= 0, y >= 0,
              (40...4096).contains(width), (40...4096).contains(height),
              x + width <= Self.canvasSize, y + height <= Self.canvasSize else { throw EaselError.invalidFrame }
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(x: c.decode(Double.self, forKey: .x), y: c.decode(Double.self, forKey: .y),
                      width: c.decode(Double.self, forKey: .width), height: c.decode(Double.self, forKey: .height))
    }
}

public enum EaselItemContent: Codable, Equatable, Sendable {
    case note(text: String)
    case link(title: String, url: String)
    case image(assetID: UUID, pixelWidth: Int, pixelHeight: Int, sourceURL: String?, sourceTitle: String?)
    case drawing(EaselDrawing)

    private static func validTitle(_ title: String) -> Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.utf8.count <= 256
    }
    private static func validURL(_ text: String) -> Bool {
        guard text.utf8.count <= 8192, !text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              let c = URLComponents(string: text), ["http", "https"].contains(c.scheme?.lowercased() ?? ""),
              let host = c.host, !host.isEmpty, c.user == nil, c.password == nil,
              c.port.map({ (1...65535).contains($0) }) ?? true, c.url != nil else { return false }
        return true
    }
    fileprivate func validate() throws {
        switch self {
        case .note(let text): guard text.utf8.count <= 16384 else { throw EaselError.invalidContent }
        case .link(let title, let url):
            guard Self.validTitle(title), Self.validURL(url) else { throw EaselError.invalidContent }
        case .image(_, let width, let height, let url, let title):
            guard (1...16384).contains(width), (1...16384).contains(height), width * height <= 40_000_000,
                  url.map(Self.validURL) ?? true, title.map(Self.validTitle) ?? true else { throw EaselError.invalidContent }
        case .drawing: break // Immutable drawing values validate at construction and decode.
        }
    }
}

public struct EaselItem: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let frame: EaselFrame
    public let content: EaselItemContent
    public init(id: UUID = UUID(), frame: EaselFrame, content: EaselItemContent) throws {
        try content.validate()
        self.id = id; self.frame = frame; self.content = content
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(UUID.self, forKey: .id), frame: c.decode(EaselFrame.self, forKey: .frame),
                      content: c.decode(EaselItemContent.self, forKey: .content))
    }
}

public enum EaselEdit: Sendable {
    case insert(EaselItem), replace(EaselItem), remove(Set<UUID>), reorder([UUID]), rename(String)
}

public struct Easel: Codable, Equatable, Identifiable, Sendable {
    public private(set) var id: UUID
    public private(set) var title: String
    public private(set) var createdAt: Date
    public private(set) var modifiedAt: Date
    public private(set) var revision: UUID
    /// Only collision recovery sets this. Separate saved board identities are never content-deduplicated.
    public private(set) var recoveredFromID: UUID?
    /// Array order is back to front. Item identities are scoped to this board.
    public private(set) var items: [EaselItem]

    public init(id: UUID = UUID(), title: String, createdAt: Date = Date(), modifiedAt: Date? = nil,
                revision: UUID = UUID(), items: [EaselItem] = []) throws {
        self.id = id; self.title = try Self.cleanTitle(title); self.createdAt = createdAt
        self.modifiedAt = modifiedAt ?? createdAt; self.revision = revision; self.items = items
        try validate()
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var input = try c.nestedUnkeyedContainer(forKey: .items)
        var items: [EaselItem] = [], drawingPoints = 0
        while !input.isAtEnd {
            guard items.count < 500 else { throw EaselError.tooManyItems }
            let item = try input.decode(EaselItem.self)
            if case .drawing(let drawing) = item.content {
                guard drawing.points.count <= 65536 - drawingPoints else { throw EaselError.invalidContent }
                drawingPoints += drawing.points.count
            }
            items.append(item)
        }
        try self.init(id: c.decode(UUID.self, forKey: .id), title: c.decode(String.self, forKey: .title),
                      createdAt: c.decode(Date.self, forKey: .createdAt), modifiedAt: c.decode(Date.self, forKey: .modifiedAt),
                      revision: c.decode(UUID.self, forKey: .revision), items: items)
        recoveredFromID = try c.decodeIfPresent(UUID.self, forKey: .recoveredFromID)
    }
    private static func cleanTitle(_ title: String) throws -> String {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 256 else { throw EaselError.invalidTitle }
        return value
    }
    private func validate() throws {
        guard createdAt.timeIntervalSinceReferenceDate.isFinite, modifiedAt.timeIntervalSinceReferenceDate.isFinite,
              modifiedAt >= createdAt else { throw EaselError.invalidDate }
        guard items.count <= 500 else { throw EaselError.tooManyItems }
        guard Set(items.map(\.id)).count == items.count else { throw EaselError.duplicateItem }
        let drawingPoints = items.reduce(0) { count, item in
            if case .drawing(let drawing) = item.content { return count + drawing.points.count }; return count
        }
        guard drawingPoints <= 65536 else { throw EaselError.invalidContent }
    }

    public mutating func apply(_ edit: EaselEdit, expectedRevision: UUID, at date: Date = Date()) throws {
        guard revision == expectedRevision else { throw EaselError.staleRevision }
        var next = self
        switch edit {
        case .insert(let item):
            guard !items.contains(where: { $0.id == item.id }) else { throw EaselError.duplicateItem }
            next.items.append(item)
        case .replace(let item):
            guard let index = items.firstIndex(where: { $0.id == item.id }) else { throw EaselError.missingItem }
            next.items[index] = item
        case .remove(let ids):
            guard ids.isSubset(of: Set(items.map(\.id))) else { throw EaselError.missingItem }
            next.items.removeAll { ids.contains($0.id) }
        case .reorder(let ids):
            guard ids.count == items.count, Set(ids).count == ids.count, Set(ids) == Set(items.map(\.id)) else { throw EaselError.invalidOrder }
            let lookup = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
            next.items = ids.compactMap { lookup[$0] }
        case .rename(let title): next.title = try Self.cleanTitle(title)
        }
        guard next != self else { return }
        guard date.timeIntervalSinceReferenceDate.isFinite else { throw EaselError.invalidDate }
        next.modifiedAt = max(modifiedAt, date); next.revision = UUID()
        try next.validate()
        self = next
    }

    /// Preserve unequal recovered drafts, even when damaged duplicate profile records reused an ID.
    public static func merged(_ current: [Easel], _ incoming: [Easel]) -> [Easel] {
        var result: [Easel] = []
        for original in current + incoming {
            if result.contains(original) { continue }
            var board = original
            if result.contains(where: { $0.id == original.id }) {
                if result.contains(where: { recovered in
                    guard recovered.recoveredFromID == original.id else { return false }
                    var compared = original; compared.id = recovered.id; compared.recoveredFromID = recovered.recoveredFromID
                    return compared == recovered
                }) { continue }
                board.recoveredFromID = original.id
            }
            while result.contains(where: { $0.id == board.id }) { board.id = UUID() }
            result.append(board)
        }
        return result
    }
}
