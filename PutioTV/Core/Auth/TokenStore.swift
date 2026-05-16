import Foundation
import Security

/// Persists the put.io OAuth token. Uses the tvOS keychain in production; on
/// simulator builds (or anywhere the keychain refuses with
/// `errSecMissingEntitlement = -34018`) falls back transparently to
/// `UserDefaults` so dev/parity flows keep working without ad-hoc signing
/// gymnastics.
protocol TokenStoring: Sendable {
    func load() -> String?
    func save(_ token: String) throws
    func clear() throws
}

struct KeychainTokenStore: TokenStoring, @unchecked Sendable {
    let service: String
    let account: String
    let defaults: UserDefaults
    let defaultsKey: String

    init(service: String = PutioTV.keychainService, account: String = "oauth_token") {
        self.service = service
        self.account = account
        self.defaults = .standard
        self.defaultsKey = "io.put.tvos.token.\(account)"
    }

    func load() -> String? {
        var query: [String: Any] = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, let token = String(data: data, encoding: .utf8) {
            return token
        }
        return defaults.string(forKey: defaultsKey)
    }

    func save(_ token: String) throws {
        guard let data = token.data(using: .utf8) else {
            throw TokenStoreError.encodingFailed
        }

        var query = baseQuery
        let attributes: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            defaults.removeObject(forKey: defaultsKey)
            return
        }

        if updateStatus == errSecItemNotFound {
            query[kSecValueData as String] = data
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            if addStatus == errSecSuccess {
                defaults.removeObject(forKey: defaultsKey)
                return
            }
            if !isEntitlementMissing(addStatus) {
                throw TokenStoreError.osStatus(addStatus)
            }
        } else if !isEntitlementMissing(updateStatus) {
            throw TokenStoreError.osStatus(updateStatus)
        }

        defaults.set(token, forKey: defaultsKey)
    }

    func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        if !(status == errSecSuccess || status == errSecItemNotFound || isEntitlementMissing(status)) {
            throw TokenStoreError.osStatus(status)
        }
        defaults.removeObject(forKey: defaultsKey)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }

    private func isEntitlementMissing(_ status: OSStatus) -> Bool {
        status == errSecMissingEntitlement || status == -34018
    }
}

enum TokenStoreError: Error, LocalizedError {
    case encodingFailed
    case osStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Could not encode the put.io token."
        case let .osStatus(status):
            return "Token-store operation failed (\(status))."
        }
    }
}
