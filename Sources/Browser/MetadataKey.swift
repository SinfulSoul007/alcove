import Foundation
import Security
import CryptoKit

/// The encryption key never enters preferences, the repository, or a release artifact.
enum MetadataKey {
    static func load(createIfMissing: Bool) throws -> SymmetricKey {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.openbrowser.mac.metadata", kSecAttrAccount as String: "local-v1"]
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 { return SymmetricKey(data: data) }
        guard status == errSecItemNotFound && createIfMissing else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Alcove couldn’t unlock its local data key. Existing data has been preserved. Check Keychain access, then restart Alcove."])
        }
        let key = SymmetricKey(size: .bits256)
        var insert = query
        insert[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let inserted = SecItemAdd(insert as CFDictionary, nil)
        guard inserted == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(inserted), userInfo: [NSLocalizedDescriptionKey: "Alcove couldn’t create a Keychain key. Local saving is disabled to protect existing data."]) }
        return key
    }
}
