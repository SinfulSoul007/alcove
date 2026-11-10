import Foundation

/// Network identity accepted by the browser, without DNS lookups.
public struct WebOrigin: Equatable, Sendable {
    public let scheme: String
    public let host: String
    public let port: Int
    public init?(_ url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let rawHost = parts.host, let host = RoutingHost.normalized(rawHost),
              parts.port.map({ (0...65535).contains($0) }) ?? true else { return nil }
        self.scheme = scheme; self.host = host; port = parts.port ?? (scheme == "https" ? 443 : 80)
    }
}
