import Foundation
#if os(macOS)
import Security
#endif

enum SecretStore {
    static let serviceName = "ktok"

    static var recommendedBackendDescription: String {
        #if os(macOS)
        return "macOS Keychain"
        #elseif os(Windows)
        return "Windows Credential Manager target ktok/login/<alias>"
        #else
        return "Secret Service/libsecret"
        #endif
    }

    static func accountName(alias: String) -> String {
        "login:\(alias.lowercased())"
    }

    static func readPassword(alias: String, keychainPath: String? = nil) -> String? {
        #if os(macOS)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName(alias: alias),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let keychain = preferredLoginKeychain(path: keychainPath) {
            query[kSecMatchSearchList as String] = [keychain]
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
        #else
        return nil
        #endif
    }

    static func savePassword(_ password: String, alias: String, keychainPath: String? = nil) {
        #if os(macOS)
        guard let data = password.data(using: .utf8) else {
            return
        }
        let account = accountName(alias: alias)
        let keychain = preferredLoginKeychain(path: keychainPath)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
        ]
        if let keychain {
            query[kSecMatchSearchList as String] = [keychain]
        }
        let update: [String: Any] = [
            kSecValueData as String: data,
        ]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item.removeValue(forKey: kSecMatchSearchList as String)
            if let keychain {
                item[kSecUseKeychain as String] = keychain
            }
            item[kSecValueData as String] = data
            SecItemAdd(item as CFDictionary, nil)
        }
        #endif
    }

    #if os(macOS)
    private static func preferredLoginKeychain(path explicitPath: String? = nil) -> SecKeychain? {
        let path = expandedKeychainPath(explicitPath)
        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }

        var keychain: SecKeychain?
        let status = SecKeychainOpen(path, &keychain)
        guard status == errSecSuccess else {
            return nil
        }
        return keychain
    }

    private static func expandedKeychainPath(_ explicitPath: String?) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let rawPath = nonEmptyTrimmed(explicitPath)
            ?? nonEmptyTrimmed(ProcessInfo.processInfo.environment["KTOK_KEYCHAIN_PATH"])
            ?? home.appendingPathComponent("Library/Keychains/login.keychain-db").path

        if rawPath == "~" {
            return home.path
        }
        if rawPath.hasPrefix("~/") {
            return home.appendingPathComponent(String(rawPath.dropFirst(2))).path
        }
        return rawPath
    }

    private static func nonEmptyTrimmed(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
    #endif
}
