import AuthenticationServices
import XCTest
@testable import Putio
@testable import PutioSDK

final class LoginSessionTests: XCTestCase {
    func testCancellingWebAuthShowsNoAlert() {
        let viewController = LoginViewControllerSpy()
        viewController.currentOAuthState = "oauth-state"

        viewController.handleWebAuthResult(callbackURL: nil, error: ASWebAuthenticationSessionError(.canceledLogin))

        XCTAssertNil(viewController.presentedAlert)
        XCTAssertNil(viewController.currentOAuthState)
    }

    func testWebAuthStartsOnlyOnTheFirstAppearance() {
        let autoStart = WebAuthAutoStart()
        let first = LoginViewControllerSpy()
        first.webAuthAutoStart = autoStart
        let second = LoginViewControllerSpy()
        second.webAuthAutoStart = autoStart

        first.viewDidAppear(false)
        first.viewDidAppear(false)
        second.viewDidAppear(false)

        XCTAssertEqual(first.webAuthStarts, 1)
        XCTAssertEqual(second.webAuthStarts, 0)
    }

    func testAFailureOnTheFirstAppearanceSpendsTheAutoStart() {
        let autoStart = WebAuthAutoStart()
        let failed = LoginViewControllerSpy()
        failed.webAuthAutoStart = autoStart
        failed.failure = .sessionLoad
        let plain = LoginViewControllerSpy()
        plain.webAuthAutoStart = autoStart

        failed.viewDidAppear(false)
        plain.viewDidAppear(false)

        XCTAssertEqual(failed.webAuthStarts + plain.webAuthStarts, 0)
    }

    func testFailedSessionLoadOffersRetryInsteadOfWebAuth() throws {
        let viewController = LoginViewControllerSpy()
        viewController.webAuthAutoStart = WebAuthAutoStart()
        viewController.failure = .sessionLoad

        viewController.viewDidAppear(false)
        let alert = try XCTUnwrap(viewController.presentedAlert)
        viewController.presentedAlert = nil
        viewController.viewDidAppear(false)

        XCTAssertEqual(viewController.webAuthStarts, 0)
        XCTAssertNil(viewController.presentedAlert)
        XCTAssertEqual(alert.title, NSLocalizedString("Couldn't load your account", comment: ""))
        XCTAssertEqual(alert.actions.compactMap(\.title), [NSLocalizedString("Retry", comment: ""), NSLocalizedString("Cancel", comment: "")])
    }

    func testRejectedTokenExplainsTheExpiredSession() throws {
        let viewController = LoginViewControllerSpy()
        viewController.webAuthAutoStart = WebAuthAutoStart()
        viewController.failure = .sessionExpired

        viewController.viewDidAppear(false)

        let alert = try XCTUnwrap(viewController.presentedAlert)
        XCTAssertEqual(viewController.webAuthStarts, 0)
        XCTAssertEqual(alert.title, NSLocalizedString("Session expired", comment: ""))
        XCTAssertEqual(alert.actions.compactMap(\.title), [NSLocalizedString("Log in", comment: ""), NSLocalizedString("Cancel", comment: "")])
    }

    func testSessionLoadFallsBackToLoginWithAReason() {
        let unauthorized = PutioSDKErrorType.httpError(statusCode: 401, errorType: "Unauthorized")
        let serverError = PutioSDKErrorType.httpError(statusCode: 500, errorType: "E2E_FORCED_FAILURE")

        XCTAssertEqual(SessionLoadFallback.after(unauthorized, keepsSession: true), .login(.sessionExpired))
        XCTAssertEqual(SessionLoadFallback.after(.httpError(statusCode: 403, errorType: "Unauthorized"), keepsSession: false), .login(.sessionExpired))
        XCTAssertEqual(SessionLoadFallback.after(serverError, keepsSession: false), .login(.sessionLoad))
        XCTAssertEqual(SessionLoadFallback.after(.networkError, keepsSession: false), .login(.sessionLoad))
        XCTAssertEqual(SessionLoadFallback.after(.networkError, keepsSession: true), .cachedSession)
        XCTAssertEqual(SessionLoadFallback.after(serverError, keepsSession: true), .cachedSession)
    }

    func testFailedSessionLoadKeepsTheCachedSessionOnlyForTheTokensOwner() {
        XCTAssertTrue(keepsSession(cachedUserID: 1, tokenOwnerID: 1))
        XCTAssertFalse(keepsSession(cachedUserID: 1, tokenOwnerID: 2))
        XCTAssertFalse(keepsSession(cachedUserID: nil, tokenOwnerID: 2))
    }

    func testSigningInAfterTheCachedAccountSignedOutDropsItsSession() {
        let keychain = makeKeychain()
        keychain.setToken("token-a")
        keychain.setTokenOwner(accountID: 1, for: "token-a")

        keychain.signOut(cachedUserID: 1)
        keychain.setToken("token-b")

        XCTAssertEqual(keychain.signedOutAccountID, 1)
        XCTAssertFalse(keepsSession(cachedUserID: 1, keychain: keychain))
    }

    func testSigningInAfterARejectedTokenDropsTheCachedSession() {
        let keychain = makeKeychain()
        keychain.setToken("token-without-owner")
        let rejected = SessionLoadFallback.after(.httpError(statusCode: 401, errorType: "Unauthorized"), keepsSession: true)
        XCTAssertEqual(rejected, .login(.sessionExpired))

        keychain.signOut(cachedUserID: 1)
        keychain.setToken("token-b")

        XCTAssertFalse(keepsSession(cachedUserID: 1, keychain: keychain))
    }

    func testATokenFrom300WithoutAnOwnerKeepsTheCachedSession() {
        let keychain = makeKeychain()
        keychain.setToken("token-from-3.0.0")

        XCTAssertNil(keychain.tokenOwnerID)
        XCTAssertTrue(keepsSession(cachedUserID: 1, keychain: keychain))
    }

    func testTheRestoredSessionFrom258KeepsItsSessionWithoutACachedUser() {
        XCTAssertTrue(SessionLoadFallback.keepsSession(cachedUserID: nil, tokenOwnerID: nil, signedOutAccountID: 1, restoresShipped258Session: true))
        XCTAssertFalse(SessionLoadFallback.keepsSession(cachedUserID: nil, tokenOwnerID: nil, signedOutAccountID: nil, restoresShipped258Session: false))
    }

    func testSupportSignInSetsTheHashBeforeLogin() {
        let messenger = SupportMessengerSpy()

        SupportIdentity.signIn(accountID: 7, userHash: "hash-7", messenger: messenger) { _ in XCTFail("no failure expected") }

        XCTAssertEqual(messenger.events, [.setUserHash("hash-7"), .login("7")])
    }

    func testSupportSignInKeepsTheSameAccountsSession() {
        let messenger = SupportMessengerSpy(loggedInUserID: "7")

        SupportIdentity.signIn(accountID: 7, userHash: "hash-7", messenger: messenger) { _ in XCTFail("no failure expected") }

        XCTAssertEqual(messenger.events, [.setUserHash("hash-7")])
    }

    func testSupportSignInLogsAnotherAccountOutFirst() {
        let messenger = SupportMessengerSpy(loggedInUserID: "8")

        SupportIdentity.signIn(accountID: 7, userHash: "hash-7", messenger: messenger) { _ in XCTFail("no failure expected") }

        XCTAssertEqual(messenger.events, [.logout, .setUserHash("hash-7"), .login("7")])
    }

    func testSupportLoginFailuresReportOnlyACategoryAndCode() {
        let offline = URLError(.notConnectedToInternet)
        let wrappedOffline = NSError(domain: "com.intercom.sdk", code: 3, userInfo: [NSUnderlyingErrorKey: offline])
        let rejected = NSError(domain: "com.intercom.sdk", code: 401, userInfo: [NSLocalizedDescriptionKey: "user 7 hash-7"])
        let failures: [(Error, String, Int)] = [
            (offline, "io.put.support-login.network", URLError.notConnectedToInternet.rawValue),
            (wrappedOffline, "io.put.support-login.network", 3),
            (rejected, "io.put.support-login.rejected", 401)
        ]

        for (error, domain, code) in failures {
            let messenger = SupportMessengerSpy(loginResult: .failure(error))
            var reported: [NSError] = []

            SupportIdentity.signIn(accountID: 7, userHash: "hash-7", messenger: messenger) { reported.append($0.error) }

            XCTAssertEqual(reported.map(\.domain), [domain])
            XCTAssertEqual(reported.map(\.code), [code])
            XCTAssertEqual(reported.map(\.userInfo.count), [0])
        }
    }

    func testEndingTheSessionClearsSupportButAFailedLoadKeepsIt() {
        let messenger = SupportMessengerSpy(loggedInUserID: "7")

        SupportIdentity.signOut(after: .sessionLoad, messenger: messenger)
        XCTAssertEqual(messenger.events, [])

        SupportIdentity.signOut(after: .sessionExpired, messenger: messenger)
        SupportIdentity.signOut(after: nil, messenger: messenger)
        XCTAssertEqual(messenger.events, [.logout, .logout])
    }

    private func makeKeychain() -> PutioKeychain {
        let keychain = PutioKeychain(serviceKey: "com.putio.tests.keychain.\(UUID().uuidString)", legacyServiceKey: nil)
        addTeardownBlock {
            keychain.clearToken()
            keychain.clearSignedOutAccount()
        }
        return keychain
    }

    private func keepsSession(cachedUserID: Int?, tokenOwnerID: Int?) -> Bool {
        SessionLoadFallback.keepsSession(cachedUserID: cachedUserID, tokenOwnerID: tokenOwnerID, signedOutAccountID: nil, restoresShipped258Session: false)
    }

    private func keepsSession(cachedUserID: Int, keychain: PutioKeychain) -> Bool {
        SessionLoadFallback.keepsSession(
            cachedUserID: cachedUserID,
            tokenOwnerID: keychain.tokenOwnerID,
            signedOutAccountID: keychain.signedOutAccountID,
            restoresShipped258Session: false
        )
    }

    private final class LoginViewControllerSpy: LoginViewController {
        var presentedAlert: UIAlertController?
        var webAuthStarts = 0

        override func startWebAuthFlow() {
            webAuthStarts += 1
        }

        override func present(_ viewControllerToPresent: UIViewController, animated flag: Bool, completion: (() -> Void)? = nil) {
            presentedAlert = viewControllerToPresent as? UIAlertController
            completion?()
        }
    }

    private final class SupportMessengerSpy: SupportMessenger {
        enum Event: Equatable {
            case setUserHash(String)
            case login(String)
            case logout
        }

        private(set) var events: [Event] = []
        private(set) var loggedInUserID: String?
        private let loginResult: Result<Void, Error>

        init(loggedInUserID: String? = nil, loginResult: Result<Void, Error> = .success(())) {
            self.loggedInUserID = loggedInUserID
            self.loginResult = loginResult
        }

        var isUserLoggedIn: Bool { loggedInUserID != nil }

        func setUserHash(_ hash: String) {
            events.append(.setUserHash(hash))
        }

        func loginUser(id: String, completion: @escaping (Result<Void, Error>) -> Void) {
            events.append(.login(id))
            loggedInUserID = id
            completion(loginResult)
        }

        func logout() {
            events.append(.logout)
            loggedInUserID = nil
        }
    }
}
