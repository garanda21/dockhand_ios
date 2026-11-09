import DockhandAPI
import Foundation
import Security

struct SyncedServerCredentials: Codable, Sendable {
    var token: String
    var headers: [DockhandCustomHeader]

    private static let service = "pro.dockhand.mobile.server-sync.v1"

    static func read(_ id: String) throws -> Self? {
        var query = identity(id)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    func write(_ id: String) throws {
        var item = Self.identity(id)
        item[kSecValueData] = try JSONEncoder().encode(self)
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func deleteAll(profileID: String) {
        var query: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
            kSecAttrService: service, kSecAttrSynchronizable: true,
            kSecReturnAttributes: true, kSecMatchLimit: kSecMatchLimitAll]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return }
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  account.hasPrefix(profileID + ".") else { continue }
            query = identity(account)
            SecItemDelete(query as CFDictionary)
        }
    }

    private static func identity(_ id: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
         kSecAttrAccount: id, kSecAttrSynchronizable: true]
    }
}
