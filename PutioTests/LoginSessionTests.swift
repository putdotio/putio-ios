import AuthenticationServices
import XCTest
@testable import Putio
@testable import PutioSDK

final class LoginSessionTests: XCTestCase {
    func testCancellingWebAuthShowsNoAlert() {
        let viewController = LoginViewControllerSpy()
        viewController.currentOAuthState = "oauth-state"

        viewController.handleWebAuthResult(callbackURL: nil, error: ASWebAuthenticationSessionError(.canceledLoginRequest))

        XCTAssertNil(viewController.presentedAlert)
        XCTAssertNil(viewController.currentOAuthState)
    }

    func testWebAuthStartsOnlyOnTheFirstPlainAppearance() {
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

    func testSupportLoginFailuresReportOnlyABoundedCategory() {
        let failures: [(Error, SupportLoginFailure)] = [
            (URLError(.notConnectedToInternet), .network),
            (NSError(domain: "com.intercom.sdk", code: 401, userInfo: [NSLocalizedDescriptionKey: "user 7 hash-7"]), .rejected)
        ]

        for (error, expected) in failures {
            let messenger = SupportMessengerSpy(loginResult: .failure(error))
            var reported: [SupportLoginFailure] = []

            SupportIdentity.signIn(accountID: 7, userHash: "hash-7", messenger: messenger) { reported.append($0) }

            XCTAssertEqual(reported, [expected])
            XCTAssertEqual(expected.error.domain, SupportLoginFailure.errorDomain)
            XCTAssertEqual(expected.error.userInfo.count, 0)
        }
    }

    func testEveryTransitionToLoginClearsTheSupportSession() {
        let messenger = SupportMessengerSpy(loggedInUserID: "7")
        let appDelegate = AppDelegate()
        appDelegate.supportMessenger = messenger

        appDelegate.presentLoginScreen()
        appDelegate.presentLoginScreen(failure: .sessionExpired)

        XCTAssertEqual(messenger.events, [.logout, .logout])
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
