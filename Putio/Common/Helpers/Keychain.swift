import Foundation
import KeychainAccess

class PutioKeychain {
    static let sharedInstance = PutioKeychain()

    let serviceKey: String = "com.putio.tvOS"
    let tokenKey: String = "access_token"
    let keychain: Keychain

    init() {
        keychain = Keychain(service: serviceKey)
    }

    func getToken() -> String? {
        return self.keychain[tokenKey]
    }

    func setToken(_ token: String) {
        self.keychain[tokenKey] = token
    }

    func clearToken() {
        self.keychain[tokenKey] = nil
    }
}
