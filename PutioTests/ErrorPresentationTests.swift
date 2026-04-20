import XCTest
@testable import Putio
import GoogleCast
@testable import PutioSDK
import SwiftyJSON

private struct MockPutioError: PutioErrorLocalizableInput {
    let localizerType: PutioSDKErrorType
    let localizerMessage: String
}

final class ErrorPresentationTests: XCTestCase {
    func testLoginViewControllerPresentsAlertForWebAuthSessionError() throws {
        let viewController = LoginViewControllerSpy()
        let error = NSError(domain: "LoginViewControllerTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Sign in was cancelled."])

        viewController.handleWebAuthResult(callbackURL: nil, error: error)

        let alert = try XCTUnwrap(viewController.presentedAlert)
        XCTAssertEqual(alert.title, NSLocalizedString("Authentication failed", comment: ""))
        XCTAssertEqual(alert.message, "Sign in was cancelled.")
    }

    func testLoginViewControllerAuthenticatesWithAccessTokenOnSuccess() {
        let viewController = LoginViewControllerSpy()

        viewController.handleWebAuthResult(
            callbackURL: URL(string: "putio://auth#access_token=test-token"),
            error: nil
        )

        XCTAssertEqual(viewController.authenticatedToken, "test-token")
        XCTAssertNil(viewController.presentedAlert)
    }

    func testSettingsViewModelPresentsRefreshErrorUsingLocalizedCopy() throws {
        let viewModel = SettingsViewModel()
        let tableViewController = SettingsTableViewControllerSpy(style: .insetGrouped)
        viewModel.tableViewController = tableViewController

        viewModel.presentSettingsRefreshError(MockPutioError(localizerType: .networkError, localizerMessage: "offline"))

        let alert = try XCTUnwrap(tableViewController.presentedAlert)
        XCTAssertEqual(alert.title, NSLocalizedString("Network error", comment: ""))
        XCTAssertEqual(alert.message, NSLocalizedString("Please check your internet connection and try again.", comment: ""))
    }

    func testSettingsViewModelPresentsPersistenceFailureAlert() throws {
        let viewModel = SettingsViewModel()
        let tableViewController = SettingsTableViewControllerSpy(style: .insetGrouped)
        viewModel.tableViewController = tableViewController

        viewModel.presentPersistenceFailure()

        let alert = try XCTUnwrap(tableViewController.presentedAlert)
        XCTAssertEqual(alert.title, NSLocalizedString("Settings updated", comment: ""))
        XCTAssertEqual(
            alert.message,
            NSLocalizedString("The change was saved on put.io, but the app could not refresh local data. Please reopen Account settings.", comment: "")
        )
    }

    func testAuthAppsTableViewControllerPresentsLocalizedErrorCopy() throws {
        let viewController = AuthAppsTableViewControllerSpy(style: .insetGrouped)

        viewController.presentAuthAppsError(MockPutioError(localizerType: .unknownError, localizerMessage: "boom"))

        let alert = try XCTUnwrap(viewController.presentedAlert)
        XCTAssertEqual(alert.title, NSLocalizedString("Something went wrong", comment: ""))
        XCTAssertEqual(alert.message, NSLocalizedString("Please try again later", comment: ""))
    }

    func testChromecastManagerSkipsInvalidScreenshotURL() {
        let file = PutioFile(
            json: JSON([
                "id": 42,
                "name": "Episode",
                "icon": "video",
                "parent_id": 0,
                "file_type": "VIDEO",
                "size": 1024,
                "created_at": "2026-04-20T00:00:00Z",
                "updated_at": "2026-04-20T00:00:00Z",
                "is_shared": false,
                "screenshot": "http://[invalid",
                "start_from": 0
            ])
        )

        let metadata = ChromecastManager.sharedInstance.createGCKMediaMetadata(for: file)

        XCTAssertEqual(metadata.images().count, 0)
        XCTAssertEqual(metadata.string(forKey: kGCKMetadataKeyTitle), "Episode")
    }

    func testConfigureAVSessionReportsErrorsThroughFailureHandler() {
        let expectedError = NSError(domain: "UtilsTests", code: 7, userInfo: [NSLocalizedDescriptionKey: "Audio session denied"])
        var receivedError: Error?

        Utils.configureAVSession(
            setCategory: { throw expectedError },
            onFailure: { receivedError = $0 }
        )

        XCTAssertEqual((receivedError as NSError?)?.domain, expectedError.domain)
        XCTAssertEqual((receivedError as NSError?)?.code, expectedError.code)
    }

    private final class LoginViewControllerSpy: LoginViewController {
        var authenticatedToken: String?
        var presentedAlert: UIAlertController?

        override func authenticate(token: String) {
            authenticatedToken = token
        }

        override func present(_ viewControllerToPresent: UIViewController, animated flag: Bool, completion: (() -> Void)? = nil) {
            presentedAlert = viewControllerToPresent as? UIAlertController
            completion?()
        }
    }

    private final class SettingsTableViewControllerSpy: SettingsTableViewController {
        var presentedAlert: UIAlertController?

        override func present(_ viewControllerToPresent: UIViewController, animated flag: Bool, completion: (() -> Void)? = nil) {
            presentedAlert = viewControllerToPresent as? UIAlertController
            completion?()
        }
    }

    private final class AuthAppsTableViewControllerSpy: AuthAppsTableViewController {
        var presentedAlert: UIAlertController?

        override func present(_ viewControllerToPresent: UIViewController, animated flag: Bool, completion: (() -> Void)? = nil) {
            presentedAlert = viewControllerToPresent as? UIAlertController
            completion?()
        }
    }
}
