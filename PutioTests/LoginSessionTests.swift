import AuthenticationServices
import os
import RealmSwift
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

    func testSignOutWithoutATokenOwnerRecordsTheCachedUser() {
        let keychain = makeKeychain()
        keychain.setToken("token-without-owner")

        keychain.signOut(cachedUserID: 1)
        keychain.setToken("token-b")

        XCTAssertEqual(keychain.signedOutAccountID, 1)
        XCTAssertFalse(keepsSession(cachedUserID: 1, keychain: keychain))
    }

    func testSigningInAfterASignOutOn300DropsTheCachedSession() {
        let keychain = makeKeychain()

        keychain.signIn(token: "token-b", cachedUserID: 1)

        XCTAssertFalse(keepsSession(cachedUserID: 1, keychain: keychain))
    }

    func testATokenFrom300WithoutAnOwnerKeepsTheCachedSession() {
        let keychain = makeKeychain()
        keychain.setToken("token-from-3.0.0")

        XCTAssertNil(keychain.tokenOwnerID)
        XCTAssertTrue(keepsSession(cachedUserID: 1, keychain: keychain))
    }

    func testAnOwnerlessTokenOfAnotherAccountDropsTheCachedAccountOnItsFirstOnlineLaunch() throws {
        let (appDelegate, realm) = try makeOwnerlessLaunch(cachedUserID: 1, token: "token-b", answeringAccountID: 2, answersConfig: false)
        let download = Download()
        download.id = 501
        try realm.write { realm.add(download) }

        appDelegate.fetchUser(token: "token-b")

        waitForRoot(LoginViewController.self, in: appDelegate)
        realm.refresh()
        XCTAssertTrue(realm.objects(User.self).isEmpty)
        XCTAssertTrue(realm.objects(UserConfig.self).isEmpty)
        XCTAssertTrue(realm.objects(Download.self).isEmpty)
        XCTAssertEqual(appDelegate.keychain.tokenOwnerID, 2)
    }

    func testAnOwnerlessTokenOfTheCachedAccountStartsTheQueueOnItsFirstOnlineLaunch() throws {
        let (appDelegate, realm) = try makeOwnerlessLaunch(cachedUserID: 1, token: "token-a", answeringAccountID: 1, answersConfig: false)
        DownloadQueueController.sharedInstance.pause()
        addTeardownBlock { DownloadQueueController.sharedInstance.pause() }

        appDelegate.fetchUser(token: "token-a")

        waitForRoot(RootContainerViewController.self, in: appDelegate)
        let started = expectation(for: NSPredicate { _, _ in DownloadQueueController.sharedInstance.isEnabled }, evaluatedWith: nil)
        wait(for: [started], timeout: 10)
        realm.refresh()
        XCTAssertEqual(realm.objects(User.self).first?.id, 1)
        XCTAssertEqual(appDelegate.keychain.tokenOwnerID, 1)
    }

    func testTheSignInAfterThe258SessionDeletesTheDownloadsNoAccountOwns() throws {
        let (appDelegate, realm) = try makeOwnerlessLaunch(cachedUserID: nil, token: "token-b", answeringAccountID: 2, answersConfig: true)
        let download = Download()
        download.id = 501
        try realm.write { realm.add(download) }
        PutioRealm.setUpgradingFromShipped258(true)
        addTeardownBlock {
            PutioRealm.setUpgradingFromShipped258(false)
            PutioRealm.setDownloadsHaveNoAccount(false)
            DownloadQueueController.sharedInstance.pause()
        }

        appDelegate.authenticate(token: "token-b")

        waitForRoot(RootContainerViewController.self, in: appDelegate)
        realm.refresh()
        XCTAssertTrue(realm.objects(Download.self).isEmpty)
        XCTAssertEqual(realm.objects(User.self).first?.id, 2)
        XCTAssertFalse(PutioRealm.downloadsHaveNoAccount())
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

    func testARejectedTokenLogsOutOfSupport() throws {
        let (appDelegate, _) = try makeOwnerlessLaunch(cachedUserID: nil, token: "token-1", answeringAccountID: 1, answersConfig: true, rejectsToken: true)
        let messenger = SupportMessengerSpy(loggedInUserID: "1")
        appDelegate.supportMessenger = messenger

        appDelegate.authenticate(token: "token-1")

        waitForRoot(LoginViewController.self, in: appDelegate)
        XCTAssertEqual(messenger.events, [.logout])
    }

    func testAFailedSessionLoadKeepsSupportForRetry() throws {
        let (appDelegate, _) = try makeOwnerlessLaunch(cachedUserID: nil, token: "token-1", answeringAccountID: 1, answersConfig: false)
        let messenger = SupportMessengerSpy(loggedInUserID: "1")
        appDelegate.supportMessenger = messenger

        appDelegate.authenticate(token: "token-1")

        waitForRoot(LoginViewController.self, in: appDelegate)
        XCTAssertEqual(messenger.events, [])
    }

    func testContactUsAndAccountDestructionOpenSupportForTheSignedInAccount() throws {
        let (appDelegate, _) = try makeOwnerlessLaunch(cachedUserID: nil, token: "token-2", answeringAccountID: 2, answersConfig: true)
        let messenger = SupportMessengerSpy(loggedInUserID: "1")
        appDelegate.supportMessenger = messenger
        addTeardownBlock { DownloadQueueController.sharedInstance.pause() }
        let sharedDelegate = try XCTUnwrap(UIApplication.shared.delegate as? AppDelegate)
        let previousMessenger = sharedDelegate.supportMessenger
        sharedDelegate.supportMessenger = messenger
        addTeardownBlock { sharedDelegate.supportMessenger = previousMessenger }

        appDelegate.authenticate(token: "token-2")
        waitForRoot(RootContainerViewController.self, in: appDelegate)
        let contactUs = try XCTUnwrap(SettingsViewModel().buildSections().flatMap(\.items).first { $0.title == NSLocalizedString("Contact us", comment: "") })
        contactUs.action?()
        DestroyAccounViewController().supportButtonTapped(self)

        XCTAssertEqual(messenger.events, [.logout, .setUserHash("hash-2"), .login("2"), .present(signedInAs: "2"), .present(signedInAs: "2")])
    }

    private func makeKeychain() -> PutioKeychain {
        let keychain = PutioKeychain(serviceKey: "com.putio.tests.keychain.\(UUID().uuidString)", legacyServiceKey: nil)
        addTeardownBlock {
            keychain.clearToken()
            keychain.clearSignedOutAccount()
        }
        return keychain
    }

    private func makeOwnerlessLaunch(cachedUserID: Int?, token: String, answeringAccountID: Int, answersConfig: Bool, rejectsToken: Bool = false) throws -> (AppDelegate, Realm) {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        var configuration = PutioRealm.configuration()
        configuration.inMemoryIdentifier = "LoginSessionTests.\(UUID().uuidString)"
        Realm.Configuration.defaultConfiguration = configuration
        let realm = try Realm(configuration: configuration)
        if let cachedUserID {
            let user = User()
            user.id = cachedUserID
            try realm.write {
                realm.add(user)
                realm.add(UserConfig())
            }
        }

        let appDelegate = AppDelegate()
        appDelegate.keychain = makeKeychain()
        appDelegate.keychain.setToken(token)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        appDelegate.window = window

        let previousToken = api.mediaToken
        api.setToken(token: token)
        AccountStub.answer(accountID: answeringAccountID, answersConfig: answersConfig, rejectsToken: rejectsToken, in: self)
        addTeardownBlock {
            window.isHidden = true
            api.setToken(token: previousToken)
            realm.invalidate()
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }
        return (appDelegate, realm)
    }

    private func waitForRoot<Root: UIViewController>(_ root: Root.Type, in appDelegate: AppDelegate) {
        let presented = expectation(for: NSPredicate { _, _ in
            appDelegate.window?.rootViewController is Root
        }, evaluatedWith: nil)
        wait(for: [presented], timeout: 10)
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
            case present(signedInAs: String?)
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

        func present() {
            events.append(.present(signedInAs: loggedInUserID))
        }
    }
}

private final class AccountStub: URLProtocol {
    private struct Answers {
        var accountID = 0
        var answersConfig = false
        var rejectsToken = false
    }

    private static let answers = OSAllocatedUnfairLock(initialState: Answers())

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "api.put.io"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let statusCode = Self.answers.withLock { $0.rejectsToken } ? 401 : 200
        guard let url = request.url, let body = Self.body(for: url.path),
              let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: ["Content-Type": "application/json"])
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func body(for path: String) -> Data? {
        answers.withLock { answers in
            if answers.rejectsToken {
                return Data(#"{"error_type":"invalid_grant","status_code":401}"#.utf8)
            }
            switch path {
            case "/v2/account/info":
                return accountInfo(id: answers.accountID)
            case "/v2/config":
                return answers.answersConfig ? Data(#"{"config":{"chromecast_playback_type":"hls","dismissed.product_analytics_prompt":true}}"#.utf8) : nil
            default:
                return nil
            }
        }
    }

    override func stopLoading() {}

    static func answer(accountID: Int, answersConfig: Bool, rejectsToken: Bool = false, in testCase: XCTestCase) {
        answers.withLock { $0 = Answers(accountID: accountID, answersConfig: answersConfig, rejectsToken: rejectsToken) }
        URLProtocol.registerClass(AccountStub.self)
        testCase.addTeardownBlock { URLProtocol.unregisterClass(AccountStub.self) }
    }

    private static func accountInfo(id: Int) -> Data {
        Data("""
        {"info": {"user_id": \(id), "username": "account-\(id)", "mail": "account-\(id)@example.com", "avatar_url": "https://static.put.io/avatar.png",
          "user_hash": "hash-\(id)", "features": {}, "download_token": "download-token-\(id)", "trash_size": 0, "account_active": true, "account_status": "active",
          "is_sub_account": false, "files_will_be_deleted_at": "", "password_last_changed_at": "", "disk": {"avail": 1, "size": 2, "used": 1},
          "settings": {"tunnel_route_name": "default", "next_episode": true, "start_from": true, "history_enabled": true, "trash_enabled": true,
            "sort_by": "NAME_ASC", "show_optimistic_usage": false, "two_factor_enabled": false, "hide_subtitles": false,
            "dont_autoselect_subtitles": false, "diagnostics_enabled": false, "product_analytics_enabled": false}}}
        """.utf8)
    }
}
