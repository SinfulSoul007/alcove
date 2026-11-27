import Foundation

/// Parsing supplies an identifier only. The tab's real profile and presentation
/// must authorize the subsequent catalog lookup.
public struct EaselRoute: Equatable, Sendable {
    public let id: UUID
    public init(id: UUID) { self.id = id }
    public var url: URL { URL(string: "alcove://easel/" + id.uuidString.lowercased())! }
    public static func parse(_ text: String) -> EaselRoute? {
        let prefix = "alcove://easel/"
        guard text.lowercased().hasPrefix(prefix) else { return nil }
        let identifier = String(text.dropFirst(prefix.count))
        guard let id = UUID(uuidString: identifier), identifier.lowercased() == id.uuidString.lowercased() else { return nil }
        return EaselRoute(id: id)
    }
    public static func isNative(_ text: String) -> Bool {
        guard let colon = text.firstIndex(of: ":") else { return false }
        return text[..<colon].lowercased() == "alcove"
    }
}
