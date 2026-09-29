import DockhandAPI
import Foundation
import Security

enum DockhandToken {
    static func normalized(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

enum KeychainStore {
    private static let service = "pro.dockhand.mobile"
    private static let legacyAccount = "dockhand-token"

    static func readToken(profileID: String) -> String? {
        readToken(account: account(for: profileID)).map(DockhandToken.normalized)
    }

    static func writeToken(_ token: String, profileID: String) {
        writeToken(DockhandToken.normalized(token), account: account(for: profileID))
    }

    static func deleteToken(profileID: String) {
        deleteItem(account: account(for: profileID))
    }

    static func migrateLegacyTokenIfNeeded(to profileID: String) {
        let targetAccount = account(for: profileID)
        guard readToken(account: targetAccount) == nil,
              let legacyToken = readLegacyToken(),
              !legacyToken.isEmpty else {
            return
        }

        writeToken(DockhandToken.normalized(legacyToken), account: targetAccount)
        deleteItem(account: legacyAccount)
    }

    /// Custom header names and values are stored together as one JSON item per
    /// profile. The item never leaves this device (no backups, no iCloud sync)
    /// and stays readable after first unlock so background refresh keeps working.
    static func readCustomHeaders(profileID: String) -> [DockhandCustomHeader] {
        guard let data = readData(account: headersAccount(for: profileID)),
              let headers = try? JSONDecoder().decode([DockhandCustomHeader].self, from: data) else {
            return []
        }
        return headers
    }

    static func writeCustomHeaders(_ headers: [DockhandCustomHeader], profileID: String) {
        let account = headersAccount(for: profileID)
        guard !headers.isEmpty, let data = try? JSONEncoder().encode(headers) else {
            deleteItem(account: account)
            return
        }
        writeData(data, account: account, accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
    }

    static func deleteCustomHeaders(profileID: String) {
        deleteItem(account: headersAccount(for: profileID))
    }

    private static func headersAccount(for profileID: String) -> String {
        "dockhand-headers.\(profileID)"
    }

    private static func account(for profileID: String) -> String {
        "dockhand-token.\(profileID)"
    }

    private static func readLegacyToken() -> String? {
        readToken(account: legacyAccount)
    }

    private static func readToken(account: String) -> String? {
        readData(account: account).flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func readData(account: String) -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return data
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

        writeData(Data(token.utf8), account: account, accessibility: nil)
    }

    private static func writeData(_ data: Data, account: String, accessibility: CFString?) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]

        var attributes: [CFString: Any] = [kSecValueData: data]
        if let accessibility {
            attributes[kSecAttrAccessible] = accessibility
        }
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecItemNotFound {
            let item = query.merging(attributes) { _, new in new }
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    private static func deleteItem(account: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
