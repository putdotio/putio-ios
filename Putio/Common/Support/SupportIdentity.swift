import Foundation
import Intercom

protocol SupportMessenger {
    var isUserLoggedIn: Bool { get }
    var loggedInUserID: String? { get }
    func setUserHash(_ hash: String)
    func setDeviceToken(_ token: Data)
    func loginUser(id: String, completion: @escaping (Result<Void, Error>) -> Void)
    func logout()
    func present()
}

struct IntercomMessenger: SupportMessenger {
    static var ifEnabled: SupportMessenger? {
        INTERCOM_ENABLED ? IntercomMessenger() : nil
    }

    var isUserLoggedIn: Bool { Intercom.isUserLoggedIn() }

    var loggedInUserID: String? { Intercom.fetchLoggedInUserAttributes()?.userId }

    func setUserHash(_ hash: String) {
        Intercom.setUserHash(hash)
    }

    func setDeviceToken(_ token: Data) {
        Intercom.setDeviceToken(token, completion: nil)
    }

    func loginUser(id: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let attributes = ICMUserAttributes()
        attributes.userId = id
        Intercom.loginUser(with: attributes, completion: completion)
    }

    func logout() {
        Intercom.logout()
    }

    func present() {
        Intercom.present()
    }
}

struct SupportLoginAttempt: Equatable {
    enum Branch: String {
        case fresh
        case switchedNilID
        case switchedOtherID
        case sameIDNotLoggedIn
    }

    let branch: Branch
    let hashEmpty: Bool
    let deviceTokenSetBeforeSignIn: Bool
}

struct SupportLoginFailure: Equatable {
    enum Category: String {
        case network
        case rejected
    }

    let category: Category
    let code: Int
    let source: String
    let attempt: SupportLoginAttempt

    init(_ error: Error, attempt: SupportLoginAttempt) {
        let error = error as NSError
        let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
        category = [error.domain, underlying?.domain].contains(NSURLErrorDomain) ? .network : .rejected
        code = error.code
        source = Self.source(of: error.domain)
        self.attempt = attempt
    }

    var error: NSError { NSError(domain: "io.put.support-login.\(category.rawValue)", code: code) }

    var context: String {
        [
            attempt.branch.rawValue,
            attempt.hashEmpty ? "hash_empty" : "hash_set",
            attempt.deviceTokenSetBeforeSignIn ? "token_before" : "no_token_before",
            source
        ].joined(separator: ".")
    }

    private static func source(of domain: String) -> String {
        if domain == NSURLErrorDomain { return "url" }
        guard domain.hasPrefix("io.intercom.") else { return "other" }
        let kind = domain.split(separator: ".").last.map { String($0.filter { $0.isASCII && $0.isLetter }.prefix(20)) } ?? ""
        return kind.isEmpty ? "intercom" : "intercom_\(kind)"
    }
}

enum SupportIdentity {
    static func signOut(after failure: LoginFailure?, messenger: SupportMessenger?) {
        guard failure != .sessionLoad else { return }
        messenger?.logout()
    }

    static func signIn(
        accountID: Int,
        userHash: String,
        deviceTokenSet: Bool = false,
        messenger: SupportMessenger?,
        report: @escaping (SupportLoginFailure) -> Void = { SentryTelemetry.capture(.supportLogin, error: $0.error, context: $0.context) }
    ) {
        guard let messenger else { return }
        let userID = String(accountID)
        let loggedInUserID = messenger.loggedInUserID
        let branch: SupportLoginAttempt.Branch

        if messenger.isUserLoggedIn {
            if loggedInUserID == userID {
                return messenger.setUserHash(userHash)
            }
            branch = loggedInUserID == nil ? .switchedNilID : .switchedOtherID
            messenger.logout()
        } else {
            branch = loggedInUserID == userID ? .sameIDNotLoggedIn : .fresh
        }

        let attempt = SupportLoginAttempt(branch: branch, hashEmpty: userHash.isEmpty, deviceTokenSetBeforeSignIn: deviceTokenSet)
        messenger.setUserHash(userHash)
        messenger.loginUser(id: userID) { result in
            if case .failure(let error) = result {
                report(SupportLoginFailure(error, attempt: attempt))
            }
        }
    }
}
