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

    static func readPassword(alias: String) -> String? {
        #if os(macOS)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName(alias: alias),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
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

    static func savePassword(_ password: String, alias: String) {
        #if os(macOS)
        guard let data = password.data(using: .utf8) else {
            return
        }
        let account = accountName(alias: alias)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [
            kSecValueData as String: data,
        ]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            SecItemAdd(item as CFDictionary, nil)
        }
        #endif
    }
}
