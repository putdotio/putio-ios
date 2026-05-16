import Foundation
import Security

/// Persists the put.io OAuth token in the tvOS keychain. Mirrors the iOS app's
/// keychain usage but uses Apple's Security framework directly so the tvOS
/// target stays free of `KeychainAccess`-style pods.
protocol TokenStoring: Sendable {
    func load() -> String?
    func save(_ token: String) throws
    func clear() throws
}

struct KeychainTokenStore: TokenStoring {
    let service: String
    let account: String

    init(service: String = PutioTV.keychainService, account: String = "oauth_token") {
        self.service = service
        self.account = account
    }

    func load() -> String? {
        var query: [String: Any] = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ token: String) throws {
        guard let data = token.data(using: .utf8) else {
            throw TokenStoreError.encodingFailed
        }

        var query = baseQuery
        let attributes: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            throw TokenStoreError.osStatus(updateStatus)
        }

        query[kSecValueData as String] = data
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw TokenStoreError.osStatus(addStatus)
        }
    }

    func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound { return }
        throw TokenStoreError.osStatus(status)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }
}

enum TokenStoreError: Error, LocalizedError {
    case encodingFailed
    case osStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Could not encode the put.io token for the keychain."
        case let .osStatus(status):
            return "Keychain operation failed (\(status))."
        }
    }
}
