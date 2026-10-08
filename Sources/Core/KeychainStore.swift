import Foundation
import Security

/// Thin wrapper over the iOS keychain for account tokens.
///
/// Tokens are stored with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` so they
/// never travel in an iCloud or iTunes backup and are unreadable while the device
/// is locked. This matters: a Minecraft access token grants full account access.
enum KeychainStore {
    private static let service = "com.craftlauncher.ios.account"

    /// Stores or replaces a UTF-8 string. Returns false when the keychain refuses
    /// the write — the caller must surface that, never swallow it.
    @discardableResult
    static func set(_ value: String, for key: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        // Delete first: SecItemAdd fails with errSecDuplicateItem otherwise, and
        // SecItemUpdate is more code for the same outcome.
        delete(key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: data,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: kCFBooleanTrue as Any,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete(_ key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Typed accessors

    private static func tokenKey(_ accountId: String, _ kind: String) -> String {
        "\(accountId).\(kind)"
    }

    static func storeTokens(accountId: String, accessToken: String, refreshToken: String) -> Bool {
        let a = set(accessToken, for: tokenKey(accountId, "access"))
        let r = set(refreshToken, for: tokenKey(accountId, "refresh"))
        return a && r
    }

    static func accessToken(accountId: String) -> String? {
        get(tokenKey(accountId, "access"))
    }

    static func refreshToken(accountId: String) -> String? {
        get(tokenKey(accountId, "refresh"))
    }

    static func clearTokens(accountId: String) {
        delete(tokenKey(accountId, "access"))
        delete(tokenKey(accountId, "refresh"))
    }
}
