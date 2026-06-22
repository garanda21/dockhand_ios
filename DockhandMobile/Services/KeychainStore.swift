import Foundation
import Security

enum KeychainStore {
    private static let service = "pro.dockhand.mobile"
    private static let legacyAccount = "dockhand-token"

    static func readToken(profileID: String) -> String? {
        readToken(account: account(for: profileID)) ?? readLegacyToken()
    }

    static func writeToken(_ token: String, profileID: String) {
        writeToken(token, account: account(for: profileID))
    }

    static func deleteToken(profileID: String) {
        deleteToken(account: account(for: profileID))
    }

    private static func account(for profileID: String) -> String {
        "dockhand-token.\(profileID)"
    }

    private static func readLegacyToken() -> String? {
        readToken(account: legacyAccount)
    }

    private static func readToken(account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    private static func writeToken(_ token: String, account: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]

        if token.isEmpty {
            SecItemDelete(query as CFDictionary)
            return
        }

        let data = Data(token.utf8)
        let attributes: [CFString: Any] = [kSecValueData: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var item = query
            item[kSecValueData] = data
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    private static func deleteToken(account: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
