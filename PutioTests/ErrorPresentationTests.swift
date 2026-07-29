import XCTest
@testable import Putio
import GoogleCast
@testable import PutioSDK

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
        viewController.currentOAuthState = "oauth-state"

        viewController.handleWebAuthResult(
            callbackURL: URL(string: "putio://auth#access_token=test-token&state=oauth-state"),
            error: nil
        )

        XCTAssertEqual(viewController.authenticatedToken, "test-token")
        XCTAssertNil(viewController.presentedAlert)
        XCTAssertNil(viewController.currentOAuthState)
    }

    func testLoginViewControllerRejectsUnexpectedCallbackEndpoint() throws {
        let viewController = LoginViewControllerSpy()
        viewController.currentOAuthState = "oauth-state"

        viewController.handleWebAuthResult(
            callbackURL: URL(string: "putio://evil#access_token=test-token&state=oauth-state"),
            error: nil
        )

        XCTAssertNil(viewController.authenticatedToken)
        XCTAssertNotNil(viewController.presentedAlert)
        XCTAssertNil(viewController.currentOAuthState)
    }

    func testLoginViewControllerRejectsMismatchedState() throws {
        let viewController = LoginViewControllerSpy()
        viewController.currentOAuthState = "oauth-state"

        viewController.handleWebAuthResult(
            callbackURL: URL(string: "putio://auth#access_token=test-token&state=wrong-state"),
            error: nil
        )

        XCTAssertNil(viewController.authenticatedToken)
        XCTAssertNotNil(viewController.presentedAlert)
        XCTAssertNil(viewController.currentOAuthState)
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

    func testDownloadsPartialDeletionFailureNamesItemsAndOffersRetry() throws {
        let viewController = DownloadsViewControllerSpy()
        let tableView = UITableView()
        viewController.view.addSubview(tableView)
        viewController.tableView = tableView
        tableView.setEditing(true, animated: false)

        viewController.presentDeletionFailure(for: [
            DownloadDeletionItem(id: 11, name: "First Episode", fileType: .video),
            DownloadDeletionItem(id: 12, name: "Second Episode", fileType: .audio)
        ])

        let alert = try XCTUnwrap(viewController.presentedAlert)
        XCTAssertEqual(
            alert.title,
            String(format: NSLocalizedString("Couldn't Delete %d Downloads", comment: ""), 2)
        )
        XCTAssertTrue(alert.message?.contains("First Episode") == true)
        XCTAssertTrue(alert.message?.contains("Second Episode") == true)
        XCTAssertEqual(
            alert.message,
            String(
                format: NSLocalizedString(
                    "%@ couldn't be deleted. The failed downloads remain selected. Retry, or remove them from the list; files that couldn't be deleted may remain on this device.",
                    comment: ""
                ),
                ["First Episode", "Second Episode"].formatted(.list(type: .and))
            )
        )
        XCTAssertEqual(
            alert.actions.map(\.title),
            [
                NSLocalizedString("Retry", comment: ""),
                NSLocalizedString("Remove from List", comment: ""),
                NSLocalizedString("Close", comment: "")
            ]
        )
    }

    func testDownloadsDeletionCompletionRetainsFailuresAndRestoresControls() throws {
        let viewController = DownloadsViewControllerSpy()
        let tableView = UITableView()
        viewController.view.addSubview(tableView)
        viewController.tableView = tableView
        tableView.setEditing(true, animated: false)
        tableView.isUserInteractionEnabled = false

        let leftButton = UIBarButtonItem(title: "Select All", style: .plain, target: nil, action: nil)
        let doneButton = UIBarButtonItem(title: "Done", style: .plain, target: nil, action: nil)
        let deleteButton = UIBarButtonItem(title: "Deleting...", style: .plain, target: nil, action: nil)
        leftButton.isEnabled = false
        doneButton.isEnabled = false
        deleteButton.isEnabled = false
        viewController.navigationItem.leftBarButtonItem = leftButton
        viewController.navigationItem.rightBarButtonItem = doneButton
        viewController.bulkDeleteButton = deleteButton
        viewController.selectButton = UIBarButtonItem(title: "Select", style: .plain, target: nil, action: nil)
        viewController.selectionState.selectAll([11, 12, 13])
        viewController.isDeletingSelectedDownloads = true

        let failure = DownloadDeletionItem(id: 12, name: "Second Episode", fileType: .audio)
        viewController.finishDownloadOperation(failures: [failure])

        XCTAssertFalse(viewController.isDeletingSelectedDownloads)
        XCTAssertTrue(tableView.isUserInteractionEnabled)
        XCTAssertTrue(tableView.isEditing)
        XCTAssertEqual(viewController.selectionState.selectedIDs, Set([12]))
        XCTAssertTrue(leftButton.isEnabled)
        XCTAssertTrue(doneButton.isEnabled)
        XCTAssertEqual(deleteButton.title, NSLocalizedString("Delete", comment: ""))
        XCTAssertFalse(viewController.selectButton?.isEnabled == true)
        XCTAssertNotNil(viewController.presentedAlert)
    }

    func testDownloadsEmptyStateWaitsForBulkDeletionToFinish() {
        let viewController = DownloadsViewControllerSpy()
        let tableView = UITableView()
        viewController.view.addSubview(tableView)
        viewController.tableView = tableView
        viewController.downloads = nil
        viewController.isDeletingSelectedDownloads = true

        viewController.updateDownloadsContentState(downloadCount: 0)

        XCTAssertEqual(viewController.stateMachine.lastState, .none)

        viewController.finishDownloadOperation(failures: [])

        XCTAssertFalse(viewController.isDeletingSelectedDownloads)
        XCTAssertEqual(viewController.stateMachine.lastState, .view("empty"))
    }

    func testChromecastManagerSkipsInvalidScreenshotURL() throws {
        let file = try makePutioFile([
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
            ]
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

    private func makePutioFile(_ payload: [String: Any]) throws -> PutioFile {
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(PutioFile.self, from: data)
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

    private final class DownloadsViewControllerSpy: DownloadsViewController {
        var presentedAlert: UIAlertController?

        override func viewDidLoad() {}

        override func present(
            _ viewControllerToPresent: UIViewController,
            animated flag: Bool,
            completion: (() -> Void)? = nil
        ) {
            presentedAlert = viewControllerToPresent as? UIAlertController
            completion?()
        }
    }
}
