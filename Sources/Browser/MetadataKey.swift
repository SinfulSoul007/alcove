import Foundation
import Security
import CryptoKit
import LocalAuthentication

/// The encryption key never enters preferences, the repository, or a release artifact.
enum MetadataKey {
    static func load(createIfMissing: Bool, allowInteraction: Bool = false) throws -> SymmetricKey {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "dev.openbrowser.mac") + ".metadata", kSecAttrAccount as String: "local-v1"]
        let context = LAContext(); context.interactionNotAllowed = !allowInteraction
        var lookup = query
        lookup[kSecUseAuthenticationContext as String] = context
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 { return SymmetricKey(data: data) }
        guard status == errSecItemNotFound && createIfMissing else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Alcove couldn’t unlock its local data key. Existing data has been preserved. Complete any macOS Keychain prompt, then choose Unlock Local Data."])
        }
        let key = SymmetricKey(size: .bits256)
        var insert = query
        insert[kSecUseAuthenticationContext as String] = context
        insert[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let inserted = SecItemAdd(insert as CFDictionary, nil)
        guard inserted == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(inserted), userInfo: [NSLocalizedDescriptionKey: "Alcove couldn’t create a Keychain key. Local saving is disabled to protect existing data."]) }
        return key
    }
}
