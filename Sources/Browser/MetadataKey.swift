import Foundation
import Security
import CryptoKit
import LocalAuthentication
import Darwin

/// The encryption key never enters preferences, the repository, or a release artifact.
enum MetadataKey {
    // Classic login-Keychain ACL dialogs do not honor LAContext's noninteractive flag.
    // Serialize our calls and scope the public classic UI policy to this operation.
    // These public C APIs are soft-linked so an unavailable compatibility API fails closed.
    private static let interactionLock = NSLock()
    private struct ClassicInteraction {
        typealias Get = @convention(c) (UnsafeMutablePointer<UInt8>) -> OSStatus
        typealias Set = @convention(c) (UInt8) -> OSStatus
        let get: Get
        let set: Set
        static func resolve() -> ClassicInteraction? {
            let symbols = UnsafeMutableRawPointer(bitPattern: -2) // Darwin RTLD_DEFAULT
            guard let get = dlsym(symbols, "SecKeychainGetUserInteractionAllowed"),
                  let set = dlsym(symbols, "SecKeychainSetUserInteractionAllowed") else { return nil }
            return ClassicInteraction(get: unsafeBitCast(get, to: Get.self), set: unsafeBitCast(set, to: Set.self))
        }
    }
    private static func withInteractionPolicy<T>(allowInteraction: Bool, _ operation: () throws -> T) throws -> T {
        interactionLock.lock(); defer { interactionLock.unlock() }
        guard !allowInteraction else { return try operation() }
        let failure: () -> NSError = {
            NSError(domain: NSOSStatusErrorDomain, code: Int(errSecInteractionNotAllowed), userInfo: [NSLocalizedDescriptionKey: "Automatic Keychain access is unavailable. Your existing data is preserved. Choose Unlock Local Data to authorize access."])
        }
        guard let policy = ClassicInteraction.resolve() else { throw failure() }
        var previous: UInt8 = 0
        guard policy.get(&previous) == errSecSuccess,
              policy.set(0) == errSecSuccess else { throw failure() }
        let result = Result { try operation() }
        guard policy.set(previous) == errSecSuccess else { throw failure() }
        return try result.get()
    }
    static func load(createIfMissing: Bool, allowInteraction: Bool = false) throws -> SymmetricKey {
        try withInteractionPolicy(allowInteraction: allowInteraction) {
            try loadUsingContext(createIfMissing: createIfMissing, allowInteraction: allowInteraction)
        }
    }
    private static func loadUsingContext(createIfMissing: Bool, allowInteraction: Bool) throws -> SymmetricKey {
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
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Alcove couldn’t unlock its local data key. Existing data has been preserved. Choose Unlock Local Data to authorize access in macOS Keychain."])
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
