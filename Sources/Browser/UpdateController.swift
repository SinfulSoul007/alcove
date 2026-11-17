import Foundation
import Combine
import CryptoKit
import BrowserCore

enum UpdateCheckResult: Equatable {
    case upToDate
    case available(UpdateOffer)
}

struct UpdateInstallerReview {
    enum Outcome: Equatable {
        case verifying, matches, sizeMismatch, checksumMismatch, unreadable
    }

    let id = UUID()
    let filename: String
    var outcome: Outcome = .verifying
}

/// Checks metadata only. Downloading and replacing an unsigned app remain explicit user actions.
@MainActor
final class UpdateController: ObservableObject {
    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)
    let installedTag: String
    @Published private(set) var checking = false
    @Published private(set) var result: UpdateCheckResult?
    @Published private(set) var authenticatedUpdate: AuthenticatedUpdate?
    @Published private(set) var installerReview: UpdateInstallerReview?
    @Published private(set) var error: String?
    @Published private(set) var lastChecked: Date?
    @Published private(set) var checkedChannel: UpdateChannel?
    private let transport: Transport
    private let signingTrust: SigningTrust

    var offer: UpdateOffer? { if case .available(let offer) = result { return offer }; return nil }
    var installerAsset: UpdateAsset? { authenticatedUpdate?.asset ?? offer?.asset }
    var releasePage: URL { UpdateCatalog.releasesURL }

    private enum SigningTrust {
        case catalogOnly, required(Curve25519.Signing.PublicKey), invalid

        static func from(bundle: Bundle) -> Self {
            guard let value = bundle.object(forInfoDictionaryKey: "AlcoveUpdateSigningPublicKey") else {
                return .catalogOnly
            }
            guard let text = value as? String, text.utf8.count == 44, let bytes = Data(base64Encoded: text),
                  let key = try? Curve25519.Signing.PublicKey(rawRepresentation: bytes) else { return .invalid }
            return .required(key)
        }
    }

    private init(installedTag: String, signingTrust: SigningTrust, transport: @escaping Transport) {
        self.installedTag = installedTag
        self.signingTrust = signingTrust
        self.transport = transport
    }
    convenience init(installedTag: String, trustedSigningKey: Curve25519.Signing.PublicKey? = nil,
                     transport: @escaping Transport) {
        self.init(installedTag: installedTag, signingTrust: trustedSigningKey.map(SigningTrust.required) ?? .catalogOnly,
                  transport: transport)
    }
    convenience init(installedTag: String, session: URLSession? = nil) {
        let session = session ?? Self.makeSession()
        self.init(installedTag: installedTag, signingTrust: .from(bundle: .main), transport: {
            try await UpdateHTTP.load($0, using: session)
        })
    }
    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: UpdateRedirectDelegate(), delegateQueue: nil)
    }

    func check(channel: UpdateChannel) async {
        guard !checking else { return }
        checking = true; result = nil; authenticatedUpdate = nil; installerReview = nil; error = nil; checkedChannel = channel
        defer { checking = false }
        var request = URLRequest(url: UpdateCatalog.apiURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Alcove-Update-Check", forHTTPHeaderField: "User-Agent")
        do {
            if case .invalid = signingTrust { throw CheckError.invalidSigningKey }
            let (data, response) = try await transport(request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, http.url == UpdateCatalog.apiURL else { throw CheckError.untrustedResponse }
            guard http.statusCode == 200 else { throw CheckError.http(http.statusCode) }
            guard data.count <= UpdateHTTP.catalogLimit else { throw UpdateHTTP.ResponseTooLarge() }
            let releases = try JSONDecoder().decode([Release].self, from: data)
            if let offer = try UpdateCatalog.latest(in: releases, installedTag: installedTag, channel: channel) {
                if case .required(let key) = signingTrust {
                    let authenticated = try await authenticate(offer, key: key)
                    try Task.checkCancellation()
                    authenticatedUpdate = authenticated
                }
                result = .available(offer)
            } else { result = .upToDate }
            lastChecked = Date()
        } catch is CancellationError {
            // Closing a caller-owned task leaves the panel idle, without a misleading result.
        } catch {
            guard !Task.isCancelled else { return }
            self.error = (error as? LocalizedError)?.errorDescription ?? "Could not read GitHub release information. Try again later or open the releases page."
        }
    }

    func verifyInstaller(at url: URL, for asset: UpdateAsset) async {
        guard !checking, installerAsset == asset, asset.sha256 != nil,
              installerReview?.outcome != .verifying else { return }
        var review = UpdateInstallerReview(filename: url.lastPathComponent)
        installerReview = review
        let worker = Task.detached(priority: .userInitiated) {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            return try? asset.verifyInstaller(at: url)
        }
        let result = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard installerReview?.id == review.id else { return }
        if Task.isCancelled {
            installerReview = nil
            return
        }
        switch result {
        case .matches: review.outcome = .matches
        case .sizeMismatch: review.outcome = .sizeMismatch
        case .checksumMismatch: review.outcome = .checksumMismatch
        case nil: review.outcome = .unreadable
        }
        installerReview = review
    }

    private func authenticate(_ offer: UpdateOffer, key: Curve25519.Signing.PublicKey) async throws -> AuthenticatedUpdate {
        let root = offer.asset.downloadURL.deletingLastPathComponent()
        let payload = try await loadSignatureAsset(UpdateReleaseManifest.payloadFilename, from: root)
        let signature = try await loadSignatureAsset(UpdateReleaseManifest.signatureFilename, from: root)
        return try UpdateReleaseManifest.authenticate(offer, payload: payload, signature: signature, trustedKey: key)
    }

    private func loadSignatureAsset(_ filename: String, from root: URL) async throws -> Data {
        let url = root.appendingPathComponent(filename)
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        let (data, response) = try await transport(request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, UpdateHTTP.accepts(response.url, for: url) else {
            throw CheckError.untrustedResponse
        }
        guard response.statusCode == 200 else { throw CheckError.missingSignatureAssets }
        guard data.count <= UpdateHTTP.limit(for: url) else { throw UpdateHTTP.ResponseTooLarge() }
        return data
    }

    private enum CheckError: LocalizedError {
        case untrustedResponse, invalidSigningKey, missingSignatureAssets, http(Int)
        var errorDescription: String? {
            switch self {
            case .untrustedResponse: return "GitHub returned an unexpected response address. Open the releases page to check manually."
            case .invalidSigningKey: return "This build’s update signing key is invalid. Check its release information manually."
            case .missingSignatureAssets: return "GitHub could not provide this release’s signed update manifest."
            case .http(403), .http(429): return "GitHub is limiting update checks. Try again later or open the releases page."
            case .http(let status): return "GitHub could not provide releases (HTTP \(status)). Try again later."
            }
        }
    }
}

private enum UpdateHTTP {
    static let catalogLimit = 4 * 1024 * 1024

    static func limit(for url: URL?) -> Int {
        switch url?.lastPathComponent {
        case UpdateReleaseManifest.payloadFilename: UpdateReleaseManifest.maximumPayloadBytes
        case UpdateReleaseManifest.signatureFilename: 64
        default: catalogLimit
        }
    }

    static func accepts(_ destination: URL?, for requested: URL) -> Bool {
        guard let destination else { return false }
        if destination == requested { return true }
        return requested.host == "github.com" && destination.scheme == "https" &&
            destination.host == "release-assets.githubusercontent.com" &&
            destination.port == nil && destination.user == nil && destination.password == nil &&
            destination.fragment == nil && destination.path.hasPrefix("/github-production-release-asset/")
    }

    static func load(_ request: URLRequest, using session: URLSession) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return (Data(), response) }
        let limit = limit(for: request.url)
        guard response.expectedContentLength <= limit else { throw ResponseTooLarge() }
        var data = Data()
        if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
        for try await byte in bytes {
            guard data.count < limit else { throw ResponseTooLarge() }
            data.append(byte)
        }
        return (data, response)
    }

    struct ResponseTooLarge: LocalizedError {
        var errorDescription: String? { "The release response is too large. Open the releases page to check manually." }
    }
}

private final class UpdateRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let acceptable = task.originalRequest?.url.map { UpdateHTTP.accepts(request.url, for: $0) } ?? false
        completionHandler(acceptable ? request : nil)
    }
}
