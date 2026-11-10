import Foundation
import CryptoKit

public enum BoostError: LocalizedError {
    case invalidSite, invalidName, invalidAppearance, codeTooLarge, invalidSelectors, capacity, payloadTooLarge, invalidImport, stale, missing
    public var errorDescription: String? {
        switch self {
        case .invalidSite: return "Enter one exact website hostname, without a scheme, path or port."
        case .invalidName: return "Give this Boost a name using 1–80 characters without control characters."
        case .invalidAppearance: return "Use six-digit hexadecimal colors and a text scale between 75% and 175%."
        case .codeTooLarge: return "Keep CSS within 64 KiB and JavaScript within 32 KiB."
        case .invalidSelectors: return "Keep up to 64 hidden elements, each with a selector of 1–1024 bytes without control characters."
        case .capacity: return "Remove a Boost before adding another. Each profile can keep up to 64."
        case .payloadTooLarge: return "This profile's Boosts exceed 1 MiB. Remove some custom code or saved looks."
        case .invalidImport: return "This is not a supported Alcove appearance. Copy a version 1 appearance and try again."
        case .stale: return "This Boost changed while you were editing. Reopen it before saving."
        case .missing: return "This Boost no longer exists."
        }
    }
}

public enum BoostFont: String, Codable, CaseIterable, Sendable { case original, system, serif, mono, rounded }

public struct BoostAppearance: Codable, Equatable, Sendable {
    public var background: String?
    public var text: String?
    public var link: String?
    public var font: BoostFont
    public var textScale: Double
    public init(background: String? = nil, text: String? = nil, link: String? = nil, font: BoostFont = .original, textScale: Double = 1) {
        self.background = background; self.text = text; self.link = link; self.font = font; self.textScale = textScale
    }
    public func validated() throws -> Self {
        func color(_ value: String?) throws -> String? {
            guard let value else { return nil }
            guard value.utf8.count == 7, value.first == "#", value.dropFirst().utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { throw BoostError.invalidAppearance }
            return value.uppercased()
        }
        guard textScale.isFinite, (0.75...1.75).contains(textScale) else { throw BoostError.invalidAppearance }
        return try Self(background: color(background), text: color(text), link: color(link), font: font, textScale: textScale)
    }
    public var css: String {
        guard let value = try? validated() else { return "" }
        var rules: [String] = []
        if let color = value.background { rules.append(":root,body{background-color:\(color)!important}") }
        if let color = value.text { rules.append("body,body *{color:\(color)!important}") }
        if let color = value.link { rules.append("a,a *{color:\(color)!important}") }
        let family: String?
        switch value.font {
        case .original: family = nil
        case .system: family = "-apple-system,BlinkMacSystemFont,sans-serif"
        case .serif: family = "Georgia,serif"
        case .mono: family = "ui-monospace,Menlo,monospace"
        case .rounded: family = "ui-rounded,-apple-system,sans-serif"
        }
        if let family { rules.append("body,body *{font-family:\(family)!important}") }
        if value.textScale != 1 {
            let percent = NumberFormatter(); percent.locale = Locale(identifier: "en_US_POSIX"); percent.maximumFractionDigits = 4
            if let size = percent.string(from: NSNumber(value: value.textScale * 100)) { rules.append("html{font-size:\(size)%!important}") }
        }
        return rules.joined(separator: "\n")
    }
}

public struct BoostContent: Codable, Equatable, Sendable {
    public var name: String
    public var host: String
    public var appearance: BoostAppearance
    public var css: String
    public var javascript: String
    public init(name: String, host: String, appearance: BoostAppearance = BoostAppearance(), css: String = "", javascript: String = "") {
        self.name = name; self.host = host; self.appearance = appearance; self.css = css; self.javascript = javascript
    }
    public func validated() throws -> Self {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard (1...80).contains(name.count), !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw BoostError.invalidName }
        guard let host = RoutingHost.normalized(host) else { throw BoostError.invalidSite }
        guard css.utf8.count <= 65536, javascript.utf8.count <= 32768 else { throw BoostError.codeTooLarge }
        return try Self(name: name, host: host, appearance: appearance.validated(), css: css, javascript: javascript)
    }
}

public struct SiteBoost: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var content: BoostContent
    public var enabled: Bool
    public var hiddenSelectors: [String]
    public var approvedJavaScriptHash: String?
    public init(id: UUID = UUID(), content: BoostContent, enabled: Bool = true, hiddenSelectors: [String] = [], approvedJavaScriptHash: String? = nil) {
        self.id = id; self.content = content; self.enabled = enabled; self.hiddenSelectors = hiddenSelectors; self.approvedJavaScriptHash = approvedJavaScriptHash
    }
    public var scriptHash: String {
        let source = id.uuidString + "\n" + content.host + "\n" + content.javascript
        return SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public var isJavaScriptApproved: Bool { !content.javascript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && approvedJavaScriptHash == scriptHash }
    public func validated() throws -> Self {
        var value = self; value.content = try content.validated()
        guard hiddenSelectors.count <= 64, hiddenSelectors.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else { throw BoostError.invalidSelectors }
        var seen = Set<String>(); value.hiddenSelectors = hiddenSelectors.filter { seen.insert($0).inserted }
        if !value.isJavaScriptApproved { value.approvedJavaScriptHash = nil }
        return value
    }
    private struct Portable: Codable {
        var version: Int
        var name: String
        var host: String
        var appearance: BoostAppearance
        var css: String
        var hiddenSelectors: [String]
    }
    public func portableData() throws -> Data {
        let value = try validated()
        return try JSONEncoder().encode(Portable(version: 1, name: value.content.name, host: value.content.host, appearance: value.content.appearance, css: value.content.css, hiddenSelectors: value.hiddenSelectors))
    }
    public static func importing(_ data: Data) throws -> Self {
        guard data.count <= 1048576 else { throw BoostError.payloadTooLarge }
        guard let value = try? JSONDecoder().decode(Portable.self, from: data), value.version == 1 else { throw BoostError.invalidImport }
        return try Self(content: BoostContent(name: value.name, host: value.host, appearance: value.appearance, css: value.css), enabled: false, hiddenSelectors: value.hiddenSelectors).validated()
    }
}

public struct BoostCatalog: Sendable {
    public let entries: [SiteBoost]
    public init(_ saved: [SiteBoost]?) {
        var result: [SiteBoost] = [], originals: [SiteBoost] = [], ids = Set<UUID>(), hosts = Set<String>(), bytes = 0
        for raw in saved ?? [] {
            guard result.count < 64 else { break }
            guard var value = try? raw.validated(), !originals.contains(value) else { continue }
            originals.append(value)
            if ids.contains(value.id) { value.id = UUID(); value.approvedJavaScriptHash = nil }
            if value.enabled && hosts.contains(value.content.host) { value.enabled = false }
            guard let size = try? JSONEncoder().encode(value).count, size <= 1048576 - bytes else { continue }
            bytes += size; ids.insert(value.id)
            if value.enabled { hosts.insert(value.content.host) }
            result.append(value)
        }
        entries = result
    }
    public func matching(_ url: URL) -> SiteBoost? {
        guard let origin = WebOrigin(url) else { return nil }
        return entries.first { $0.enabled && $0.content.host == origin.host }
    }
    public func upserting(_ raw: SiteBoost) throws -> [SiteBoost] {
        var value = try raw.validated()
        var result = entries
        if let index = result.firstIndex(where: { $0.id == value.id }) {
            if result[index].content.host != value.content.host || result[index].content.javascript != value.content.javascript { value.approvedJavaScriptHash = nil }
            result[index] = value
        } else {
            guard result.count < 64 else { throw BoostError.capacity }
            result.append(value)
        }
        if value.enabled {
            for index in result.indices where result[index].id != value.id && result[index].content.host == value.content.host { result[index].enabled = false }
        }
        let bytes = try result.reduce(0) { try $0 + JSONEncoder().encode($1).count }
        guard bytes <= 1048576 else { throw BoostError.payloadTooLarge }
        return result
    }
    public func removing(_ id: UUID) -> [SiteBoost] { entries.filter { $0.id != id } }
}
