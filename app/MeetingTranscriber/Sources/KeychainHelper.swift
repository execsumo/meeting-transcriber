import Foundation
import Security

/// Minimal wrapper around macOS Keychain Services for storing secrets.
enum KeychainHelper {

    private static let service = "com.meetingtranscriber.app"

    // MARK: - Public API

    /// Base query for the modern data protection keychain.
    /// Uses `kSecUseDataProtectionKeychain` so items survive app re-signing
    /// (no per-binary ACL — access is team/identity-based).
    private static func baseQuery(key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    /// Store or update a value in the Keychain.
    static func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }

        let query = baseQuery(key: key)

        // Try update first (item may already exist)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)

        if status == errSecItemNotFound {
            // Item doesn't exist yet — add it
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)

            // If modern keychain fails, try legacy (fallback for older macOS)
            if addStatus != errSecSuccess {
                var legacy = query
                legacy.removeValue(forKey: kSecUseDataProtectionKeychain as String)
                legacy[kSecValueData as String] = data
                SecItemAdd(legacy as CFDictionary, nil)
            }
        }
    }

    /// Read a value from the Keychain. Returns `nil` if not found.
    /// Tries modern data protection keychain first, falls back to legacy.
    static func read(key: String) -> String? {
        var query = baseQuery(key: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        var status = SecItemCopyMatching(query as CFDictionary, &result)

        // Fallback: try legacy keychain (items saved before this change)
        if status != errSecSuccess {
            var legacy = query
            legacy.removeValue(forKey: kSecUseDataProtectionKeychain as String)
            status = SecItemCopyMatching(legacy as CFDictionary, &result)
        }

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Delete a value from the Keychain (both modern and legacy).
    static func delete(key: String) {
        let query = baseQuery(key: key)
        SecItemDelete(query as CFDictionary)

        // Also delete from legacy keychain
        var legacy = query
        legacy.removeValue(forKey: kSecUseDataProtectionKeychain as String)
        SecItemDelete(legacy as CFDictionary)
    }

    /// Check whether a value exists in the Keychain.
    static func exists(key: String) -> Bool {
        var query = baseQuery(key: key)
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            return true
        }

        // Fallback: check legacy keychain
        var legacy = query
        legacy.removeValue(forKey: kSecUseDataProtectionKeychain as String)
        return SecItemCopyMatching(legacy as CFDictionary, nil) == errSecSuccess
    }
}
