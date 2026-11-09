import os
import UIKit
import XCTest
@testable import Putio
import PutioSDK

final class ClearDataViewModelTests: XCTestCase {
    private var sentOptions: [PutioAccountClearOptions] = []

    override func setUp() {
        super.setUp()
        sentOptions = []
    }

    func testCancelSendsNoRequest() throws {
        let viewModel = try makeViewModel(selecting: ["files"])
        var prompts = 0

        viewModel.cleanUp(
            confirm: { _, answer in
                prompts += 1
                answer(false)
            },
            completion: { _ in XCTFail("Cancel must not complete a clear") }
        )

        XCTAssertEqual(prompts, 1)
        XCTAssertTrue(sentOptions.isEmpty)
        XCTAssertTrue(viewModel.canClear, "Cancel should leave Clear available for another try")
    }

    func testConfirmSendsTheSelectedCategoriesOnce() throws {
        let viewModel = try makeViewModel(selecting: ["files", "history"])
        var results: [ClearDataViewModel.ActionResult] = []

        viewModel.cleanUp(confirm: { _, answer in answer(true) }, completion: { results.append($0) })

        XCTAssertEqual(sentOptions.count, 1)
        XCTAssertEqual(sentOptions.first.map(fields), [
            "files": true,
            "finishedTransfers": false,
            "activeTransfers": false,
            "rssFeeds": false,
            "rssLogs": false,
            "history": true,
            "trash": false,
            "friends": false
        ])
        XCTAssertEqual(results.count, 1)
        guard case .success = results.first else {
            return XCTFail("Expected success, got \(String(describing: results.first))")
        }
    }

    func testNothingSelectedNeitherPromptsNorSends() throws {
        let viewModel = try makeViewModel(selecting: [])

        viewModel.cleanUp(
            confirm: { _, _ in XCTFail("Nothing selected must not prompt") },
            completion: { _ in XCTFail("Nothing selected must not complete a clear") }
        )

        XCTAssertFalse(viewModel.canClear)
        XCTAssertTrue(sentOptions.isEmpty)
    }

    func testConfirmationNamesTheSelectedTitles() throws {
        let viewModel = try makeViewModel(selecting: ["trash", "files", "rss_feeds"])
        var message: String?

        viewModel.cleanUp(confirm: { prompt, _ in message = prompt }, completion: { _ in })

        // The list punctuation follows the device region, so join the titles the same way.
        let titles = ListFormatter.localizedString(byJoining: ["Files", "RSS feeds", "Trash"])
        XCTAssertEqual(message, "This permanently deletes \(titles) from your put.io account. It can't be undone.")
    }

    func testEverySDKOptionHasATitle() {
        let viewModel = ClearDataViewModel(clearRequest: { _, _ in })

        XCTAssertEqual(viewModel.keys.map(viewModel.title(for:)), [
            "Files",
            "Finished transfers",
            "Active transfers",
            "RSS feeds",
            "RSS logs",
            "History",
            "Trash",
            "Friends"
        ])
    }

    private func makeViewModel(selecting keys: [String]) throws -> ClearDataViewModel {
        let ok = try JSONDecoder().decode(PutioOKResponse.self, from: Data(#"{"status":"OK"}"#.utf8))
        let viewModel = ClearDataViewModel(clearRequest: { options, completion in
            self.sentOptions.append(options)
            completion(.success(ok))
        })
        keys.forEach(viewModel.toggleOption(key:))
        return viewModel
    }

    private func fields(_ options: PutioAccountClearOptions) -> [String: Bool] {
        [
            "files": options.files,
            "finishedTransfers": options.finishedTransfers,
            "activeTransfers": options.activeTransfers,
            "rssFeeds": options.rssFeeds,
            "rssLogs": options.rssLogs,
            "history": options.history,
            "trash": options.trash,
            "friends": options.friends
        ]
    }
}

final class ClearDataScreenTests: XCTestCase {
    func testClearWaitsForASelectionAndOnlyConfirmSendsTheRequest() throws {
        AccountClearStub.start(in: self)
        let storyboard = UIStoryboard(name: "Main", bundle: Bundle(for: ClearDataTableViewController.self))
        let screen = try XCTUnwrap(storyboard.instantiateViewController(withIdentifier: "ClearData") as? ClearDataTableViewController)
        let navigation = try pushOnWindow(screen)
        let clear = try XCTUnwrap(screen.navigationItem.rightBarButtonItem)

        XCTAssertEqual(clear.title, "Clear")
        XCTAssertFalse(clear.isEnabled, "Clear should wait for a selection")
        try select("Files", in: screen)
        try select("History", in: screen)
        XCTAssertTrue(clear.isEnabled)

        try tap(clear)
        let confirmation = try waitForAlert(on: screen, titled: "Clear the selected data?")
        XCTAssertEqual(confirmation.message, "This permanently deletes Files and History from your put.io account. It can't be undone.")
        try chooseAlertAction("Cancel", in: confirmation)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(AccountClearStub.requests, 0, "Cancel must not send the request")
        XCTAssertTrue(clear.isEnabled)

        try tap(clear)
        try chooseAlertAction("Clear", in: try waitForAlert(on: screen, titled: "Clear the selected data?"))

        let sent = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in AccountClearStub.requests == 1 }, object: nil)
        wait(for: [sent], timeout: 10)
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in navigation.topViewController !== screen }, object: nil)
        wait(for: [closed], timeout: 10)
        XCTAssertEqual(AccountClearStub.requests, 1)
    }

    func testFailedClearSaysSoAndKeepsTheScreenOpenForAnotherTry() throws {
        AccountClearStub.start(in: self, failing: true)
        let storyboard = UIStoryboard(name: "Main", bundle: Bundle(for: ClearDataTableViewController.self))
        let screen = try XCTUnwrap(storyboard.instantiateViewController(withIdentifier: "ClearData") as? ClearDataTableViewController)
        let navigation = try pushOnWindow(screen)
        let clear = try XCTUnwrap(screen.navigationItem.rightBarButtonItem)
        try select("Trash", in: screen)

        try tap(clear)
        try chooseAlertAction("Clear", in: try waitForAlert(on: screen, titled: "Clear the selected data?"))

        let failure = try waitForAlert(on: screen, titled: "Network error")
        XCTAssertEqual(failure.message, "Please check your internet connection and try again.")
        XCTAssertEqual(failure.actions.map(\.title), ["OK"])
        XCTAssertEqual(AccountClearStub.requests, 1)
        XCTAssertIdentical(navigation.topViewController, screen, "a failed clear should stay on the screen")

        let dismissed = expectation(description: "error alert dismissed")
        screen.dismiss(animated: false) { dismissed.fulfill() }
        wait(for: [dismissed], timeout: 5)
        try tap(try XCTUnwrap(screen.navigationItem.rightBarButtonItem))
        let retry = try waitForAlert(on: screen, titled: "Clear the selected data?")
        XCTAssertEqual(retry.message, "This permanently deletes Trash from your put.io account. It can't be undone.")
        try chooseAlertAction("Clear", in: retry)
        _ = try waitForAlert(on: screen, titled: "Network error")
        XCTAssertEqual(AccountClearStub.requests, 2, "the retry should send the request again")
    }

    private func select(_ title: String, in screen: ClearDataTableViewController) throws {
        let tableView = try XCTUnwrap(screen.tableView)
        let row = try XCTUnwrap((0..<tableView.numberOfRows(inSection: 0)).first { row in
            screen.tableView(tableView, cellForRowAt: IndexPath(row: row, section: 0)).textLabel?.text == title
        }, title)
        try tapRow(at: IndexPath(row: row, section: 0), in: tableView)
    }
}

private final class AccountClearStub: URLProtocol {
    private static let sent = OSAllocatedUnfairLock(initialState: 0)
    private static let failsClear = OSAllocatedUnfairLock(initialState: false)

    static var requests: Int { sent.withLock { $0 } }

    static func start(in testCase: XCTestCase, failing: Bool = false) {
        sent.withLock { $0 = 0 }
        failsClear.withLock { $0 = failing }
        URLProtocol.registerClass(AccountClearStub.self)
        testCase.addTeardownBlock { URLProtocol.unregisterClass(AccountClearStub.self) }
    }

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "api.put.io"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard request.httpMethod == "POST", let url = request.url, url.path == "/v2/account/clear",
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }

        Self.sent.withLock { $0 += 1 }
        if Self.failsClear.withLock({ $0 }) {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"status":"OK"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

extension XCTestCase {
    func pushOnWindow(_ viewController: UIViewController) throws -> UINavigationController {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let navigation = UINavigationController(rootViewController: UIViewController())
        window.rootViewController = navigation
        window.isHidden = false
        addTeardownBlock { window.isHidden = true }
        navigation.pushViewController(viewController, animated: false)
        navigation.view.layoutIfNeeded()
        return navigation
    }

    func tap(_ item: UIBarButtonItem) throws {
        let action = try XCTUnwrap(item.isEnabled ? item.action : nil, "\(item.title ?? "button") is disabled, so a user can't tap it")
        XCTAssertTrue(UIApplication.shared.sendAction(action, to: item.target, from: item, for: nil))
    }

    func tapRow(at indexPath: IndexPath, in tableView: UITableView) throws {
        XCTAssertNotNil(tableView.window, "the table must be on screen to take a tap")
        XCTAssertTrue(tableView.isEditing ? tableView.allowsSelectionDuringEditing : tableView.allowsSelection, "the table doesn't take row taps")
        tableView.scrollToRow(at: indexPath, at: .middle, animated: false)
        tableView.layoutIfNeeded()
        let cell = try XCTUnwrap(tableView.cellForRow(at: indexPath), "row \(indexPath) isn't displayed")
        XCTAssertTrue(cell.isUserInteractionEnabled && !cell.isHidden, "row \(indexPath) can't be touched")
        XCTAssertTrue(tableView.delegate?.tableView?(tableView, shouldHighlightRowAt: indexPath) ?? true, "row \(indexPath) refuses the touch")
        let willSelect: IndexPath?
        if let delegate = tableView.delegate, let ask = delegate.tableView(_:willSelectRowAt:) {
            willSelect = ask(tableView, indexPath)
        } else {
            willSelect = indexPath
        }
        let selected = try XCTUnwrap(willSelect, "row \(indexPath) refuses selection")
        tableView.selectRow(at: selected, animated: false, scrollPosition: .none)
        tableView.delegate?.tableView?(tableView, didSelectRowAt: selected)
    }

    func waitForAlert(on viewController: UIViewController, titled title: String, timeout: TimeInterval = 10) throws -> UIAlertController {
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (viewController.presentedViewController as? UIAlertController)?.title == title
                && viewController.presentedViewController?.isBeingPresented == false
        }, object: nil)
        wait(for: [shown], timeout: timeout)
        return try XCTUnwrap(viewController.presentedViewController as? UIAlertController, title)
    }

    func chooseAlertAction(_ title: String, in alert: UIAlertController) throws {
        typealias Handler = @convention(block) (UIAlertAction) -> Void
        let action = try XCTUnwrap(alert.actions.first { $0.title == title }, title)
        let presenter = try XCTUnwrap(alert.presentingViewController)
        let dismissed = expectation(description: "\(title) dismissed the alert")
        presenter.dismiss(animated: false) { dismissed.fulfill() }
        wait(for: [dismissed], timeout: 5)
        let handler = try XCTUnwrap(action.value(forKey: "handler") as AnyObject?, title)
        unsafeBitCast(handler, to: Handler.self)(action)
    }
}
