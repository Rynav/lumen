import Foundation
import Security

/// Keychain Services synchronizes access; this value holds no mutable state or cached secrets.
public struct KeychainStore: Sendable {
    public enum StoreError: Error, LocalizedError, Sendable {
        case keychain(OSStatus)
        case invalidData

        public var errorDescription: String? {
            switch self {
            case .keychain(let status):
                return (SecCopyErrorMessageString(status, nil) as String?)
                    ?? "Keychain operation failed (\(status))."
            case .invalidData:
                return "The saved credential data could not be read."
            }
        }
    }

    private let service: String

    public init(service: String = "app.lumen.credentials") {
        self.service = service
    }

    public func loadAPIKey(for profileID: UUID) throws -> String? {
        guard let data = try read(account: account(profileID, "apiKey")) else { return nil }
        guard let key = String(data: data, encoding: .utf8) else { throw StoreError.invalidData }
        return key
    }

    public func saveAPIKey(_ key: String, for profileID: UUID) throws {
        try save(Data(key.utf8), account: account(profileID, "apiKey"))
    }

    public func deleteAPIKey(for profileID: UUID) throws {
        try delete(account: account(profileID, "apiKey"))
    }

    public func loadHeaders(for profileID: UUID) throws -> [String: String] {
        guard let data = try read(account: account(profileID, "headers")) else { return [:] }
        do {
            return try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            throw StoreError.invalidData
        }
    }

    public func saveHeaders(_ headers: [String: String], for profileID: UUID) throws {
        try save(JSONEncoder().encode(headers), account: account(profileID, "headers"))
    }

    public func deleteHeaders(for profileID: UUID) throws {
        try delete(account: account(profileID, "headers"))
    }

    private func account(_ id: UUID, _ field: String) -> String {
        "\(id.uuidString).\(field)"
    }

    private func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
    }

    private func read(account: String) throws -> Data? {
        var query = query(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
        guard let data = result as? Data else { throw StoreError.invalidData }
        return data
    }

    private func save(_ data: Data, account: String) throws {
        let query = query(account: account)
        let attributes = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
            if status == errSecDuplicateItem {
                status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            }
        }
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
    }

    private func delete(account: String) throws {
        let status = SecItemDelete(query(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.keychain(status)
        }
    }
}
