import Foundation
import Security
import CryptoKit

// Disposable hosted diagnostic. This never accesses Alcove's real metadata namespace.
@available(macOS, deprecated: 10.10, message: "Intentional comparison of legacy login-Keychain UI controls")
@main struct OwnedKeychainInteractionProbe {
    static func main() {
        guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true",
              let id = Bundle.main.bundleIdentifier, id.hasPrefix("dev.alcove.owned-keychain-probe."),
              CommandLine.arguments.count == 2 else { exit(71) }
        setbuf(stdout, nil)
        #if PROBE_A
        let binary = "A"
        #else
        let binary = "B"
        #endif
        let mode = CommandLine.arguments[1], start = ProcessInfo.processInfo.systemUptime
        var interactionBefore = DarwinBoolean(false)
        let beforeStatus = SecKeychainGetUserInteractionAllowed(&interactionBefore)
        defer {
            var interactionAfter = DarwinBoolean(false)
            let afterStatus = SecKeychainGetUserInteractionAllowed(&interactionAfter)
            print("OWNED_KEYCHAIN_UI_POLICY_RESTORED", beforeStatus, afterStatus, interactionBefore.boolValue == interactionAfter.boolValue)
        }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: id + ".metadata", kSecAttrAccount as String: "local-v1"]
        print("OWNED_KEYCHAIN_PROBE_STARTED", binary, mode)
        if mode == "delete" {
            print("OWNED_KEYCHAIN_PROBE_DELETE", SecItemDelete(query as CFDictionary)); return
        }
        if mode == "query-no-ui" {
            var lookup = query; lookup[kSecReturnData as String] = true; lookup[kSecMatchLimit as String] = kSecMatchLimitOne
            lookup[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
            var result: CFTypeRef?
            let status = SecItemCopyMatching(lookup as CFDictionary, &result)
            emit(binary, mode, status, result as? Data, start); return
        }
        var previous = DarwinBoolean(true)
        if mode == "legacy-no-ui" {
            guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess,
                  SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { exit(72) }
        }
        defer { if mode == "legacy-no-ui" { _ = SecKeychainSetUserInteractionAllowed(previous.boolValue) } }
        do {
            let key = try MetadataKey.load(createIfMissing: mode == "create", allowInteraction: false)
            emit(binary, mode, errSecSuccess, key.withUnsafeBytes { Data($0) }, start)
        } catch { emit(binary, mode, OSStatus((error as NSError).code), nil, start) }
    }
    static func emit(_ binary: String, _ mode: String, _ status: OSStatus, _ data: Data?, _ start: TimeInterval) {
        var result: [String: Any] = ["binary": binary, "mode": mode, "status": status, "seconds": ProcessInfo.processInfo.systemUptime - start, "bytes": data?.count ?? 0]
        if let data { result["ownedRandomKeySHA256"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        let encoded = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]); print("OWNED_KEYCHAIN_PROBE_RESULT", String(decoding: encoded, as: UTF8.self))
    }
}
