import Foundation
import KeychainAccess

class PutioKeychain {
    static let sharedInstance = PutioKeychain()

    /// 2.58.0's literal service. `APP_KEYCHAIN_SERVICE` falls back to `io.put.dev`
    /// in every build, since Info.plist carries no `PUTIO_APP_IDENTIFIER`, so
    /// without this an upgrade from 2.58.0 signs everyone out.
    static let shipped258ServiceKey = "com.putio.tvOS"

    let serviceKey: String
    let tokenKey: String = "access_token"
    let keychain: Keychain
    private let legacyKeychain: Keychain?

    init(serviceKey: String = APP_KEYCHAIN_SERVICE, legacyServiceKey: String? = PutioKeychain.shipped258ServiceKey) {
        self.serviceKey = serviceKey
        keychain = Keychain(service: serviceKey)
        legacyKeychain = legacyServiceKey.flatMap { $0 == serviceKey ? nil : Keychain(service: $0) }
    }

    /// Moves 2.58.0's token over only when `adoptsShipped258Token`. Elsewhere it
    /// is one a 3.x sign-out left behind, since 3.x cleared only its own service,
    /// so it is deleted unused.
    func getToken(adoptsShipped258Token: Bool = false) -> String? {
        if let token = keychain[tokenKey] {
            return token
        }

        guard let legacyKeychain, let token = legacyKeychain[tokenKey] else { return nil }
        guard adoptsShipped258Token else {
            legacyKeychain[tokenKey] = nil
            return nil
        }
        keychain[tokenKey] = token
        // Moved only once the copy reads back, so a failed write keeps the session.
        if keychain[tokenKey] == token {
            legacyKeychain[tokenKey] = nil
        }
        return token
    }

    func setToken(_ token: String) {
        self.keychain[tokenKey] = token
    }

    func clearToken() {
        self.keychain[tokenKey] = nil
        legacyKeychain?[tokenKey] = nil
    }
}
