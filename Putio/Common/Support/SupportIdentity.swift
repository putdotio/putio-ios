import Foundation
import Intercom

protocol SupportMessenger {
    var isUserLoggedIn: Bool { get }
    var loggedInUserID: String? { get }
    func setUserHash(_ hash: String)
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

struct SupportLoginFailure: Equatable {
    enum Category: String {
        case network
        case rejected
    }

    let category: Category
    let code: Int

    init(_ error: Error) {
        let error = error as NSError
        let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
        category = [error.domain, underlying?.domain].contains(NSURLErrorDomain) ? .network : .rejected
        code = error.code
    }

    var error: NSError { NSError(domain: "io.put.support-login.\(category.rawValue)", code: code) }
}

enum SupportIdentity {
    static func signOut(after failure: LoginFailure?, messenger: SupportMessenger?) {
        guard failure != .sessionLoad else { return }
        messenger?.logout()
    }

    static func signIn(
        accountID: Int,
        userHash: String,
        messenger: SupportMessenger?,
        report: @escaping (SupportLoginFailure) -> Void = { SentryTelemetry.capture(.supportLogin, error: $0.error) }
    ) {
        guard let messenger else { return }
        let userID = String(accountID)

        if messenger.isUserLoggedIn {
            if messenger.loggedInUserID == userID {
                return messenger.setUserHash(userHash)
            }
            messenger.logout()
        }

        messenger.setUserHash(userHash)
        messenger.loginUser(id: userID) { result in
            if case .failure(let error) = result {
                report(SupportLoginFailure(error))
            }
        }
    }
}
