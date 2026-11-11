import Foundation
import CryptoKit
import BrowserCore

extension BrowserStore {
    var canCreateMetadataKey: Bool {
        !FileManager.default.fileExists(atPath: sessionURL.path) && !FileManager.default.fileExists(atPath: previousSessionURL.path)
    }
    // Security calls may wait indefinitely for macOS; never await them with a strong store reference.
    @discardableResult func beginInitialMetadataLoad(access: MetadataKeyAccess? = nil, allowInteraction: Bool = false) -> Bool {
        guard awaitingInitialMetadata, !unlocking, !isShuttingDown else { return false }
        unlocking = true; metadataLoadError = nil
        let access = access ?? metadataKeyAccess, create = canCreateMetadataKey
        Task { [weak self] in
            let result: Result<SymmetricKey, Error>
            do { result = .success(try await access.load(createIfMissing: create, allowInteraction: allowInteraction)) }
            catch { result = .failure(error) }
            guard let self, !self.isShuttingDown else { return }
            self.unlocking = false
            do {
                try self.restoreInitialMetadata(using: result.get())
                self.metadataLoadError = nil; self.awaitingInitialMetadata = false
                self.metadataDidLoad?()
            } catch {
                self.savingEnabled = false; self.persistedProfileIDs = []
                self.metadataLoadError = "Your saved data is still protected. Complete any macOS Keychain prompt, or choose Unlock Local Data to try again. \(error.localizedDescription)"
            }
        }
        return true
    }
    func restoreInitialMetadata(using key: SymmetricKey) throws {
        let storage = MetadataStore(url: sessionURL, key: key)
        var document = try storage.load(BrowserDocument.self)
        if document == nil { document = try MetadataStore(url: previousSessionURL, key: key).load(BrowserDocument.self) }
        var migratedLegacyURL: URL?
        if document != nil { hasSavedDocument = true }
        else {
            let legacyURL = sessionURL.deletingLastPathComponent().appendingPathComponent("session.json")
            if FileManager.default.fileExists(atPath: legacyURL.path) {
                hasSavedDocument = true
                var migrated = BrowserDocument(session: try JSONDecoder().decode(Session.self, from: Data(contentsOf: legacyURL)))
                migrated.preferences.onboardingCompleted = true; document = migrated; migratedLegacyURL = legacyURL
            }
        }
        var prepared = document ?? BrowserDocument(); try prepared.repairProfiles(); prepared.session = Self.repairedSession(prepared.session)
        if let document {
            persistedProfileIDs.formUnion((document.profiles ?? []).map(\.id).filter { $0 != BrowserProfile.zeroID })
            persistedProfileIDs.formUnion(document.session.spaces.map(\.effectiveProfileID).filter { $0 != BrowserProfile.zeroID })
            persistedProfileIDs.formUnion((document.profileLibraries ?? []).map(\.profileID).filter { $0 != BrowserProfile.zeroID })
        }
        // Save recovered identifiers before WebKit can create a named website store.
        let canonical = JSONEncoder(); canonical.outputFormatting = [.sortedKeys]
        let previous = try document.map { try canonical.encode($0) }
        let current = try canonical.encode(prepared)
        if !FileManager.default.fileExists(atPath: sessionURL.path) || previous != current { try storage.save(prepared) }
        try applyDocument(prepared)
        vault = storage
        persistedProfileIDs = Set((prepared.profiles ?? []).map(\.id))
        if let migratedLegacyURL {
            do { try FileManager.default.removeItem(at: migratedLegacyURL) }
            catch {
                let warning = "Your tabs were encrypted and restored, but the original legacy JSON could not be removed. It still contains readable URLs."
                message = [message, warning].compactMap { $0 }.joined(separator: "\n")
            }
        }
        startArchiveTimer()
        savingEnabled = true
        onboardingVisible = OnboardingPolicy.shouldPresent(isPrivate: isPrivate, savingEnabled: savingEnabled, completed: preferences.onboardingCompleted, hasSavedDocument: hasSavedDocument)
        if hasSavedDocument && preferences.onboardingCompleted == nil { preferences.onboardingCompleted = true }
    }
}
