import AppKit
import WebKit
import BrowserCore

enum ExtensionHostError:LocalizedError {
    case unavailable, closed, stale, timedOut, damaged, unsupportedIsolation, unsupportedPrivatePage, unsupportedWebsitePopup, unsupportedPrivateRequestBlocking, native(String)
    var errorDescription:String? {
        switch self {
        case .unavailable:return "Native extensions require macOS 15.4 or later."
        case .closed:return "This extension's browser session has closed."
        case .stale:return "The extension, its permissions or its profile changed. Try again."
        case .timedOut:return "The extension did not finish preparing in time. Retry or continue without extensions."
        case .damaged:return "Installed extension resources changed or are missing. Review the original package again."
        case .unsupportedIsolation:return "This package requires sandboxed extension pages. Alcove cannot yet verify that isolation in WebKit."
        case .unsupportedPrivatePage:return "Extension tabs and options cannot yet open in private windows. Open this extension's options explicitly from a normal window."
        case .unsupportedPrivateRequestBlocking:return "Private access for request-blocking extensions needs a newer system WebKit. Update macOS to use this extension privately. Normal browsing remains available."
        case .unsupportedWebsitePopup:return "Website popups from extension pages are not available yet. Open the website in a regular tab."
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
    func sourceDocumentChanged(_ web:WKWebView)
    func allowsExtensionURL(_ url:URL,profileID:UUID) -> Bool
    func configuration(for url:URL,profileID:UUID) -> WKWebViewConfiguration?
    func optionsURL(_ id:UUID,profileID:UUID) -> URL?
    func actionSummaries(for web:WKWebView,profileID:UUID) -> [BrowserExtensionActionSummary]
    func performAction(_ id:UUID,from web:WKWebView,profileID:UUID,anchor:NSView) throws
    func commandSummaries(for web:WKWebView,profileID:UUID) -> [BrowserExtensionCommandSummary]
    func performCommand(_ id:UUID,command:String,from web:WKWebView,profileID:UUID,anchor:NSView) throws
    func performCommand(for event:NSEvent,from web:WKWebView,profileID:UUID,anchor:NSView) throws -> Bool
    func contextMenuGroups(for target:BrowserExtensionTabTarget,profileID:UUID) -> [BrowserExtensionMenuGroup]
    func invalidate(profileID:UUID)
    func refresh()
    func shutdown()
}
extension BrowserExtensionHosting {
    func browserStateChanged() {refresh()}
    func sourceDocumentChanged(_ web:WKWebView) {browserStateChanged()}
    func allowsExtensionURL(_ url:URL,profileID:UUID) -> Bool {false}
    func configuration(for url:URL,profileID:UUID) -> WKWebViewConfiguration? {nil}
    func optionsURL(_ id:UUID,profileID:UUID) -> URL? {nil}
    func actionSummaries(for web:WKWebView,profileID:UUID) -> [BrowserExtensionActionSummary] {[]}
    func performAction(_ id:UUID,from web:WKWebView,profileID:UUID,anchor:NSView) throws {throw ExtensionHostError.unavailable}
    func commandSummaries(for web:WKWebView,profileID:UUID) -> [BrowserExtensionCommandSummary] {[]}
    func performCommand(_ id:UUID,command:String,from web:WKWebView,profileID:UUID,anchor:NSView) throws {throw ExtensionHostError.unavailable}
    func performCommand(for event:NSEvent,from web:WKWebView,profileID:UUID,anchor:NSView) throws -> Bool {false}
    func contextMenuGroups(for target:BrowserExtensionTabTarget,profileID:UUID) -> [BrowserExtensionMenuGroup] {[]}
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
