import AppKit
import WebKit
import BrowserCore

enum ExtensionHostError:LocalizedError {
    case unavailable, closed, stale, timedOut, damaged, unsupportedIsolation, native(String)
    var errorDescription:String? {
        switch self {
        case .unavailable:return "Native extensions require macOS 15.4 or later."
        case .closed:return "This extension's browser session has closed."
        case .stale:return "The extension, its permissions or its profile changed. Try again."
        case .timedOut:return "The extension did not finish preparing in time. Retry or continue without extensions."
        case .damaged:return "Installed extension resources changed or are missing. Review the original package again."
        case .unsupportedIsolation:return "This package requires sandboxed extension pages. Alcove cannot yet verify that isolation in WebKit."
        case .native(let detail):return "WebKit could not load this extension: " + detail
        }
    }
}

enum ExtensionProfileState:Equatable {
    case preparing, ready, failed(String)
}

/// BrowserStore remains usable on macOS14 without referencing unavailable native types.
@MainActor protocol BrowserExtensionHosting:AnyObject {
    func configure(_ configuration:WKWebViewConfiguration,profileID:UUID)
    func prepare(profileID:UUID) async throws
    func requiresPreparation(profileID:UUID) -> Bool
    func matches(_ configuration:WKWebViewConfiguration,profileID:UUID) -> Bool
    func continueWithout(profileID:UUID) throws
    func browserStateChanged()
    func allowsExtensionURL(_ url:URL,profileID:UUID) -> Bool
    func configuration(for url:URL,profileID:UUID) -> WKWebViewConfiguration?
    func optionsURL(_ id:UUID,profileID:UUID) -> URL?
    func invalidate(profileID:UUID)
    func refresh()
    func shutdown()
}
extension BrowserExtensionHosting {
    func browserStateChanged() {refresh()}
    func allowsExtensionURL(_ url:URL,profileID:UUID) -> Bool {false}
    func configuration(for url:URL,profileID:UUID) -> WKWebViewConfiguration? {nil}
    func optionsURL(_ id:UUID,profileID:UUID) -> URL? {nil}
}

extension BrowserStore {
    func ensureExtensionHost() -> (any BrowserExtensionHosting)? {
        guard !isShuttingDown else {return nil}
        if let extensionHosting {return extensionHosting}
        guard !isPrivate, !awaitingInitialMetadata, vault != nil else {return nil}
        if #available(macOS 15.4,*) {
            let host = NativeBrowserExtensionHost(owner:self); extensionHosting = host; return host
        }
        return nil
    }
    func configureExtensions(_ configuration:WKWebViewConfiguration,profileID:UUID?) {
        if let privateUserContentController {configuration.userContentController = privateUserContentController}
        if #available(macOS 15.4,*) {configuration.webExtensionController = nil}
        guard let profileID, !profileUnavailable(profileID), let host = ensureExtensionHost() else {return}
        host.configure(configuration,profileID:profileID)
    }
    func prepareExtensions(profileID:UUID) async throws {
        guard !isShuttingDown else {throw ExtensionHostError.closed}
        guard !profileUnavailable(profileID), let host = ensureExtensionHost() else {
            if #available(macOS 15.4,*) {throw ProfileError.locked}
            throw ExtensionHostError.unavailable
        }
        try await host.prepare(profileID:profileID)
    }
    func retryExtensions(profileID:UUID) async throws {
        extensionHosting?.invalidate(profileID:profileID)
        try await prepareExtensions(profileID:profileID)
    }
}
