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
        if let local = try? credentialsForSync(profileID: profileID) { return DockhandToken.normalized(local.token) }
        return nil
    }

    static func writeToken(_ token: String, profileID: String) throws {
        var local = try credentialsForUpdate(profileID: profileID)
        local.token = DockhandToken.normalized(token)
        try installSyncedCredentials(local, profileID: profileID)
    }

    static func deleteToken(profileID: String) throws {
        try writeToken("", profileID: profileID)
    }

    static func deleteCredentials(profileID: String) {
        deleteItem(account: "dockhand-credentials." + profileID)
        deleteItem(account: account(for: profileID))
        deleteItem(account: headersAccount(for: profileID))
    }

    static func migrateLegacyTokenIfNeeded(to profileID: String) {
        guard var local = try? credentialsForSync(profileID: profileID),
              readData(account: "dockhand-credentials." + profileID) == nil,
              readToken(account: account(for: profileID)) == nil,
              let legacyToken = readLegacyToken(), !legacyToken.isEmpty else { return }
        local.token = DockhandToken.normalized(legacyToken)
        do {
            try installSyncedCredentials(local, profileID: profileID)
            deleteItem(account: legacyAccount)
        } catch {
            // Preserve the legacy item until the complete local snapshot is committed.
        }
    }

    /// Custom header names and values are stored together as one JSON item per
    /// profile. This local mirror stays readable after first unlock. When users
    /// enable sync, a separate versioned item is stored in iCloud Keychain.
    static func readCustomHeaders(profileID: String) -> [DockhandCustomHeader] {
        (try? credentialsForSync(profileID: profileID).headers) ?? []
    }

    static func writeCustomHeaders(_ headers: [DockhandCustomHeader], profileID: String) throws {
        var local = try credentialsForUpdate(profileID: profileID)
        local.headers = headers
        try installSyncedCredentials(local, profileID: profileID)
    }

    static func deleteCustomHeaders(profileID: String) throws {
        let local = try credentialsForUpdate(profileID: profileID)
        if local.token.isEmpty { deleteCredentials(profileID: profileID) }
        else { try writeCustomHeaders([], profileID: profileID) }
    }

    static func credentialsForSync(profileID: String) throws -> SyncedServerCredentials {
        func checkedData(_ account: String) throws -> Data? {
            let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
                kSecAttrService: service, kSecAttrAccount: account, kSecAttrSynchronizable: false,
                kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
            return result as? Data
        }
        if let bundle = try checkedData("dockhand-credentials." + profileID) {
            return try JSONDecoder().decode(SyncedServerCredentials.self, from: bundle)
        }
        let tokenData = try checkedData(account(for: profileID))
        let headersData = try checkedData(headersAccount(for: profileID))
        return SyncedServerCredentials(
            token: tokenData.flatMap { String(data: $0, encoding: .utf8) } ?? "",
            headers: try headersData.map { try JSONDecoder().decode([DockhandCustomHeader].self, from: $0) } ?? [])
    }

    /// Writes can safely replace a malformed saved snapshot with the new value.
    /// Keychain access errors still propagate so callers can report locked-device failures.
    private static func credentialsForUpdate(profileID: String) throws -> SyncedServerCredentials {
        do {
            return try credentialsForSync(profileID: profileID)
        } catch is DecodingError {
            return SyncedServerCredentials(token: "", headers: [])
        }
    }

    /// Commit the complete credential snapshot as one atomic Keychain update.
    static func installSyncedCredentials(_ credentials: SyncedServerCredentials, profileID: String) throws {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
            kSecAttrService: service, kSecAttrAccount: "dockhand-credentials." + profileID,
            kSecAttrSynchronizable: false]
        let attributes: [CFString: Any] = [kSecValueData: try JSONEncoder().encode(credentials),
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        // Remove legacy fragments only after the complete local snapshot exists.
        deleteItem(account: account(for: profileID))
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

    private static func deleteItem(account: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
