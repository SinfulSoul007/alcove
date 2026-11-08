import Foundation
import Combine
import BrowserCore

enum UpdateCheckResult: Equatable {
    case upToDate
    case available(UpdateOffer)
}

/// Checks metadata only. Downloading and replacing an unsigned app remain explicit user actions.
@MainActor
final class UpdateController: ObservableObject {
    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)
    let installedTag: String
    @Published private(set) var checking = false
    @Published private(set) var result: UpdateCheckResult?
    @Published private(set) var error: String?
    @Published private(set) var lastChecked: Date?
    @Published private(set) var checkedChannel: UpdateChannel?
    private let transport: Transport

    var offer: UpdateOffer? { if case .available(let offer) = result { return offer }; return nil }
    var releasePage: URL { UpdateCatalog.releasesURL }

    init(installedTag: String, transport: @escaping Transport) {
        self.installedTag = installedTag
        self.transport = transport
    }
    convenience init(installedTag: String, session: URLSession? = nil) {
        let session = session ?? Self.makeSession()
        self.init(installedTag: installedTag, transport: { try await session.data(for: $0) })
    }
    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    func check(channel: UpdateChannel) async {
        guard !checking else { return }
        checking = true; result = nil; error = nil; checkedChannel = channel
        defer { checking = false }
        var request = URLRequest(url: UpdateCatalog.apiURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Alcove-Update-Check", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await transport(request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, http.url == UpdateCatalog.apiURL else { throw CheckError.untrustedResponse }
            guard http.statusCode == 200 else { throw CheckError.http(http.statusCode) }
            guard data.count <= 4 * 1024 * 1024 else { throw CheckError.responseTooLarge }
            let releases = try JSONDecoder().decode([Release].self, from: data)
            if let offer = try UpdateCatalog.latest(in: releases, installedTag: installedTag, channel: channel) {
                result = .available(offer)
            } else { result = .upToDate }
            lastChecked = Date()
        } catch is CancellationError {
            // Closing a caller-owned task leaves the panel idle, without a misleading result.
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "Could not read GitHub release information. Try again later or open the releases page."
        }
    }

    private enum CheckError: LocalizedError {
        case untrustedResponse, responseTooLarge, http(Int)
        var errorDescription: String? {
            switch self {
            case .untrustedResponse: return "GitHub returned an unexpected response address. Open the releases page to check manually."
            case .responseTooLarge: return "The release response is too large. Open the releases page to check manually."
            case .http(403), .http(429): return "GitHub is limiting update checks. Try again later or open the releases page."
            case .http(let status): return "GitHub could not provide releases (HTTP \(status)). Try again later."
            }
        }
    }
}
