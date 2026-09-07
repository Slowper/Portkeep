import Foundation
import Security

/// License secret in the Keychain. The plist copy is only a migration source.
enum LicenseStore {
    static let service = PortkeepDefaults.domain
    static let account = "license-key"
    static let defaultsKey = "license.key"

    static func load() -> String? {
        if let fromKeychain = readKeychain(), !fromKeychain.isEmpty { return fromKeychain }
        if let legacy = PortkeepDefaults.suite.string(forKey: defaultsKey), !legacy.isEmpty {
            try? save(legacy)
            PortkeepDefaults.suite.removeObject(forKey: defaultsKey)
            return legacy
        }
        return nil
    }

    static func save(_ secret: String) throws {
        let data = Data(secret.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw LicenseError.rejected("Couldn't store the license on this Mac.")
        }
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        PortkeepDefaults.suite.removeObject(forKey: defaultsKey)
    }

    private static func readKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
