import Foundation
import Darwin

/// Browser host identity, without DNS or network access.
public enum RoutingHost {
    public static func normalized(_ raw: String) -> String? {
        guard raw.utf8.count <= 4096 else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().precomposedStringWithCanonicalMapping
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters).union(CharacterSet(charactersIn: "/\\@?#%"))
        guard !text.isEmpty, !text.unicodeScalars.contains(where: forbidden.contains) else { return nil }
        if text.contains(":") {
            let literal: String
            if text.hasPrefix("[") || text.hasSuffix("]") {
                guard text.hasPrefix("["), text.hasSuffix("]") else { return nil }
                literal = String(text.dropFirst().dropLast())
            } else { literal = text }
            var address = in6_addr()
            guard literal.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return nil }
            let bytes = withUnsafeBytes(of: address) { Array($0) }
            let pieces = stride(from: 0, to: 16, by: 2).map { UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]) }
            var bestStart = 0, bestCount = 0, index = 0
            while index < 8 {
                if pieces[index] != 0 { index += 1; continue }
                let start = index
                while index < 8 && pieces[index] == 0 { index += 1 }
                if index - start > bestCount { bestStart = start; bestCount = index - start }
            }
            let result: String
            if bestCount >= 2 {
                result = pieces[..<bestStart].map { String($0, radix: 16) }.joined(separator: ":") + "::" + pieces[(bestStart + bestCount)...].map { String($0, radix: 16) }.joined(separator: ":")
            } else { result = pieces.map { String($0, radix: 16) }.joined(separator: ":") }
            return "[" + result + "]"
        }
        guard !text.contains("["), !text.contains("]") else { return nil }
        var parts = URLComponents(); parts.scheme = "https"; parts.host = text
        guard var host = parts.url?.host?.lowercased(), !host.contains("%") else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !host.isEmpty, host.utf8.count <= 253, labels.allSatisfy({ label in
            !label.isEmpty && label.utf8.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-") && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }) else { return nil }
        let last = labels.last!
        let endsInNumber = last.utf8.allSatisfy { (48...57).contains($0) }
            || (last.hasPrefix("0x") && last.dropFirst(2).utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) })
        guard endsInNumber else { return host }
        guard labels.count <= 4 else { return nil }
        var numbers: [UInt64] = []
        for label in labels {
            var digits = String(label); var radix = 10
            if digits.hasPrefix("0x") { digits.removeFirst(2); radix = 16 }
            else if digits.count >= 2 && digits.hasPrefix("0") { digits.removeFirst(); radix = 8 }
            guard let number = digits.isEmpty ? 0 : UInt64(digits, radix: radix) else { return nil }
            numbers.append(number)
        }
        guard numbers.dropLast().allSatisfy({ $0 <= 255 }), let tail = numbers.last,
              tail < (UInt64(1) << UInt64(8 * (5 - numbers.count))) else { return nil }
        var ipv4 = tail
        for (index, number) in numbers.dropLast().enumerated() { ipv4 += number << UInt64(8 * (3 - index)) }
        return [24,16,8,0].map { String((ipv4 >> $0) & 255) }.joined(separator: ".")
    }
}

public enum LinkRuleKind: String, Codable, Sendable { case contains, equals }
public enum LinkDestination: Codable, Equatable, Hashable, Sendable { case quickBrowse, mostRecentSpace, space(UUID) }
public enum LinkRuleError: LocalizedError {
    case invalidPattern, duplicateCondition, tooManyRules, missingRule, invalidPosition
    public var errorDescription: String? {
        switch self {
        case .invalidPattern: return "Enter a URL pattern using 1–2048 bytes without control characters. Equals needs a web address."
        case .duplicateCondition: return "Another route already uses this match condition. Edit or move that route."
        case .tooManyRules: return "Remove a route before adding another. You can keep up to 128."
        case .missingRule: return "This route no longer exists."
        case .invalidPosition: return "Choose a position inside the route list."
        }
    }
}

private struct RoutingAddress {
    let scheme: String
    let full: String, withoutScheme: String, root: Bool
    var equalFull: String { root ? String(full.dropLast()) : full }
    var equalWithoutScheme: String { root ? String(withoutScheme.dropLast()) : withoutScheme }
    init?(_ url: URL) {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let origin = WebOrigin(url) else { return nil }
        let scheme = origin.scheme, host = origin.host
        parts.scheme = scheme; parts.host = host
        if (scheme == "http" && parts.port == 80) || (scheme == "https" && parts.port == 443) { parts.port = nil }
        parts.percentEncodedPath = Self.path(parts.percentEncodedPath)
        guard let canonical = parts.url?.absoluteString else { return nil }
        self.scheme = scheme; full = canonical; withoutScheme = String(canonical.dropFirst(scheme.count + 3))
        root = parts.percentEncodedPath == "/" && parts.percentEncodedQuery == nil && parts.percentEncodedFragment == nil
    }
    private static func path(_ raw: String) -> String {
        let path = raw.hasPrefix("/") ? String(raw.dropFirst()) : raw
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        var kept: [String] = []
        for (index, segment) in segments.enumerated() {
            let text = segment.lowercased(), final = index == segments.count - 1
            if text == "." || text == "%2e" {
                if final { kept.append("") }
            } else if ["..", ".%2e", "%2e.", "%2e%2e"].contains(text) {
                if !kept.isEmpty { kept.removeLast() }
                if final { kept.append("") }
            } else { kept.append(String(segment)) }
        }
        return "/" + kept.joined(separator: "/")
    }
    static func pattern(_ pattern: String, kind: LinkRuleKind, scheme: String = "https") -> String? {
        let lower = pattern.lowercased(), explicit = lower.hasPrefix("https://") || lower.hasPrefix("http://")
        if explicit, let url = URL(string: pattern), let address = RoutingAddress(url) {
            if kind == .equals { return address.equalFull }
            let suppliedPath = URLComponents(string: pattern)?.percentEncodedPath
            return address.root && suppliedPath == "" ? address.equalFull : address.full
        }
        if kind == .contains { return RoutingHost.normalized(pattern) ?? pattern }
        guard !pattern.contains("://"), let url = URL(string: scheme + "://" + pattern), let address = RoutingAddress(url) else { return nil }
        return address.equalWithoutScheme
    }
}

public struct LinkRule: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: LinkRuleKind
    public var pattern: String
    public var destination: LinkDestination
    public var enabled: Bool
    public init(id: UUID = UUID(), kind: LinkRuleKind = .contains, pattern: String, destination: LinkDestination = .mostRecentSpace, enabled: Bool = true) {
        self.id = id; self.kind = kind; self.pattern = pattern; self.destination = destination; self.enabled = enabled
    }
    public func validated() throws -> LinkRule {
        var value = self; value.pattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard !value.pattern.isEmpty, value.pattern.utf8.count <= 2048,
              !value.pattern.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              RoutingAddress.pattern(value.pattern, kind: value.kind) != nil,
              RoutingAddress.pattern(value.pattern, kind: value.kind, scheme: "http") != nil else { throw LinkRuleError.invalidPattern }
        return value
    }
}

public struct LinkRuleCatalog: Sendable {
    private struct Prepared: Sendable { let rule: LinkRule, text: String, httpText: String }
    private struct ConditionKey: Hashable { let kind: String, http: String, https: String }
    public let entries: [LinkRule]
    private let prepared: [Prepared]
    private static let locale = Locale(identifier: "en_US_POSIX")
    private static func key(_ rule: LinkRule, _ text: String, _ httpText: String) -> ConditionKey {
        ConditionKey(kind: rule.kind.rawValue, http: httpText.folding(options: .caseInsensitive, locale: locale), https: text.folding(options: .caseInsensitive, locale: locale))
    }
    public init(_ saved: [LinkRule]?) {
        var result: [Prepared] = [], ids = Set<UUID>(), conditions = Set<ConditionKey>()
        for raw in saved ?? [] {
            guard result.count < 128 else { break }
            guard let rule = try? raw.validated(), let text = RoutingAddress.pattern(rule.pattern, kind: rule.kind),
                  let httpText = RoutingAddress.pattern(rule.pattern, kind: rule.kind, scheme: "http"),
                  !ids.contains(rule.id), !conditions.contains(Self.key(rule,text,httpText)) else { continue }
            ids.insert(rule.id); conditions.insert(Self.key(rule,text,httpText)); result.append(Prepared(rule:rule,text:text,httpText:httpText))
        }
        prepared = result; entries = result.map(\.rule)
    }
    public func matching(_ url: URL) -> LinkRule? {
        guard let address = RoutingAddress(url) else { return nil }
        for item in prepared where item.rule.enabled {
            if item.rule.kind == .contains {
                if address.full.range(of:item.text,options:.caseInsensitive,locale:Self.locale) != nil { return item.rule }
            } else {
                let pattern = address.scheme == "http" ? item.httpText : item.text
                if address.equalFull.compare(pattern,options:.caseInsensitive,locale:Self.locale) == .orderedSame || address.equalWithoutScheme.compare(pattern,options:.caseInsensitive,locale:Self.locale) == .orderedSame { return item.rule }
            }
        }
        return nil
    }
    public func upserting(_ raw: LinkRule) throws -> [LinkRule] {
        let rule = try raw.validated(), text = RoutingAddress.pattern(rule.pattern,kind:rule.kind)!, httpText = RoutingAddress.pattern(rule.pattern,kind:rule.kind,scheme:"http")!
        guard !prepared.contains(where:{ $0.rule.id != rule.id && Self.key($0.rule,$0.text,$0.httpText) == Self.key(rule,text,httpText) }) else { throw LinkRuleError.duplicateCondition }
        var result = entries
        if let index = result.firstIndex(where:{$0.id==rule.id}) { result[index] = rule }
        else { guard result.count < 128 else { throw LinkRuleError.tooManyRules }; result.append(rule) }
        return result
    }
    public func removing(_ id: UUID) -> [LinkRule] { entries.filter { $0.id != id } }
    public func moving(_ id: UUID, to destination: Int) throws -> [LinkRule] {
        guard let source = entries.firstIndex(where:{$0.id==id}) else { throw LinkRuleError.missingRule }
        guard entries.indices.contains(destination) else { throw LinkRuleError.invalidPosition }
        var result = entries; result.insert(result.remove(at:source),at:destination); return result
    }
}
