import Foundation
import BrowserCore

enum ExternalLinkDestination: Equatable { case quick(UUID), space(UUID) }
enum BrowserWindowOwnerError: LocalizedError {
    case closed, privateDispatch
    var errorDescription: String? {
        switch self {
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
        isClosed = true; store.shutdown(); onLastWindow()
    }
    func dispatchExternal(_ url: URL) throws -> ExternalLinkDestination {
        guard !isClosed else { throw BrowserWindowOwnerError.closed }
        guard !store.isPrivate else { throw BrowserWindowOwnerError.privateDispatch }
        return try store.openExternalPage(url)
    }
}
