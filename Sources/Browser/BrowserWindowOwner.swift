import Foundation
import BrowserCore

enum ExternalLinkDestination: Equatable { case quick(UUID), space(UUID), pending }
enum BrowserWindowOwnerError: LocalizedError {
    case closed, privateDispatch, queueFull
    var errorDescription: String? {
        switch self {
        case .queueFull: return "Too many links are waiting for local data. Unlock Alcove, then open this link again."
        case .closed: return "This browser window has already closed."
        case .privateDispatch: return "External links must open through a normal browser window."
        }
    }
}

/// One data writer survives until its last primary or compact window closes.
@MainActor final class BrowserWindowOwner {
    let id = UUID()
    let store: BrowserStore
    private var primaryLeases: Set<UUID> = []
    private var quickLeases: [UUID: UUID] = [:]
    private(set) var isClosed = false
    private(set) var pendingExternalURLs: [URL] = []
    private let onLastWindow: () -> Void
    var leaseCount: Int { primaryLeases.count + quickLeases.count }
    init(store: BrowserStore, onLastWindow: @escaping () -> Void = {}) {
        self.store = store; self.onLastWindow = onLastWindow
    }
    func acquirePrimary() throws -> UUID {
        guard !isClosed else { throw BrowserWindowOwnerError.closed }
        let token = UUID(); primaryLeases.insert(token); return token
    }
    func acquireQuick(_ id: UUID) throws -> UUID {
        guard !isClosed else { throw BrowserWindowOwnerError.closed }
        guard store.quickPage(id) != nil else { throw QuickBrowseError.missing }
        if let token = quickLeases[id] { return token }
        let token = UUID(); quickLeases[id] = token; return token
    }
    func release(_ token: UUID) {
        guard !isClosed else { return }
        var removed = primaryLeases.remove(token) != nil
        if let id = quickLeases.first(where: { $0.value == token })?.key { quickLeases.removeValue(forKey: id); removed = true }
        guard removed, leaseCount == 0 else { return }
        isClosed = true; pendingExternalURLs = []; store.shutdown(); onLastWindow()
    }
    func drainExternalLinks() -> [ExternalLinkDestination] {
        guard !isClosed, !store.awaitingInitialMetadata, store.savingEnabled else { return [] }
        let urls = pendingExternalURLs; pendingExternalURLs = []
        var destinations: [ExternalLinkDestination] = []
        for url in urls {
            do { destinations.append(try dispatchExternal(url)) }
            catch { store.message = "A waiting link could not open. " + error.localizedDescription }
        }
        return destinations
    }
    func dispatchExternal(_ url: URL) throws -> ExternalLinkDestination {
        guard !isClosed else { throw BrowserWindowOwnerError.closed }
        guard !store.isPrivate else { throw BrowserWindowOwnerError.privateDispatch }
        guard QuickBrowseRouting.host(for: url) != nil else { throw QuickBrowseError.invalidAddress }
        if store.awaitingInitialMetadata {
            guard pendingExternalURLs.count < 64, url.absoluteString.utf8.count <= 16384,
                  pendingExternalURLs.reduce(0, { $0 + $1.absoluteString.utf8.count }) + url.absoluteString.utf8.count <= 1048576 else { throw BrowserWindowOwnerError.queueFull }
            pendingExternalURLs.append(url); return .pending
        }
        return try store.openExternalPage(url)
    }
}
