import Foundation
import CryptoKit

/// One system lookup per key namespace, including when every waiting window has closed.
/// Cancelling a waiter cannot cancel a synchronous Security operation.
@MainActor final class MetadataKeyAccess {
    static let shared = MetadataKeyAccess { try MetadataKey.load(createIfMissing: $0, allowInteraction: $1) }
    private let provider: (Bool, Bool) throws -> SymmetricKey
    private var pending: (id: UUID, task: Task<SymmetricKey, Error>)?
    init(provider: @escaping (Bool, Bool) throws -> SymmetricKey) { self.provider = provider }
    func load(createIfMissing: Bool, allowInteraction: Bool) async throws -> SymmetricKey {
        if let pending { return try await pending.task.value }
        let id = UUID(), provider = provider
        let task = Task.detached(priority: .userInitiated) { try provider(createIfMissing, allowInteraction) }
        pending = (id, task)
        defer { if pending?.id == id { pending = nil } }
        return try await task.value
    }
}
