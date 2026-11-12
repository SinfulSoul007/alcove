import Foundation

/// Conservative containment for saved website approvals. It never approves file or browser URLs.
/// Unsupported declarations may still be displayed by the manifest reader, but cannot earn a grant.
public struct ExtensionMatchPattern:Equatable,Sendable {
    public let string:String
    public let schemes:Set<String>
    public let host:String
    public let includesSubdomains:Bool
    public let path:String
    public init?(_ raw:String) {
        guard raw.utf8.count <= 4096, !raw.isEmpty,
              raw.utf8.allSatisfy({33...126 ~= $0}), !raw.contains("\\"), !raw.contains("#") else { return nil }
        if raw == "<all_urls>" {
            string = raw; schemes = ["http","https","ws","wss"]; host = "*"; includesSubdomains = true; path = "/*"; return
        }
        guard let separator = raw.range(of:"://") else { return nil }
        let scheme = String(raw[..<separator.lowerBound]).lowercased()
        guard ["*","http","https","ws","wss"].contains(scheme) else { return nil }
        let remainder = raw[separator.upperBound...]
        guard let slash = remainder.firstIndex(of:"/") else { return nil }
        var authority = String(remainder[..<slash]); let resource = String(remainder[slash...])
        let wildcard = authority.hasPrefix("*.")
        if wildcard { authority.removeFirst(2) }
        let normalized:String
        if authority == "*", !wildcard { normalized = "*" }
        else {
            guard !authority.contains("*"), let valid = RoutingHost.normalized(authority),
                  !wildcard || (!valid.hasPrefix("[") && !valid.split(separator:".").allSatisfy({UInt8($0) != nil})) else { return nil }
            normalized = valid
        }
        schemes = scheme == "*" ? ["http","https"] : [scheme]
        host = normalized; includesSubdomains = wildcard || normalized == "*"; path = resource
        string = scheme + "://" + (wildcard ? "*." : "") + normalized + resource
    }
    public func covers(_ other:Self) -> Bool {
        guard other.schemes.isSubset(of:schemes) else { return false }
        if host != "*" {
            guard other.host != "*" else { return false }
            if includesSubdomains {
                guard other.host == host || other.host.hasSuffix("." + host) else { return false }
            } else { guard !other.includesSubdomains, other.host == host else { return false } }
        }
        if path == "/*" || path == other.path { return true }
        // Only prove the simple trailing-wildcard case; unknown containment fails closed.
        if path.hasSuffix("*"), !path.dropLast().contains("*") { return other.path.hasPrefix(path.dropLast()) }
        return false
    }
}
