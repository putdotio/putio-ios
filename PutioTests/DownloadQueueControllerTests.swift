import Foundation
import PutioSDK
import RealmSwift
import UIKit
import XCTest
@testable import Putio

final class DownloadQueuePolicyTests: XCTestCase {
    func testSharesOneFIFOLimitAcrossMedia() {
        let items = [
            DownloadQueueItem(id: 1, state: .queued, createdAt: Date(timeIntervalSince1970: 1)),
            DownloadQueueItem(id: 2, state: .queued, createdAt: Date(timeIntervalSince1970: 2)),
            DownloadQueueItem(id: 3, state: .queued, createdAt: Date(timeIntervalSince1970: 3))
        ]

        XCTAssertEqual(DownloadQueuePolicy.nextDownloadIDs(from: items, occupiedIDs: [], limit: 1), [1])
        XCTAssertEqual(DownloadQueuePolicy.nextDownloadIDs(from: items, occupiedIDs: [1], limit: 2), [2])
        XCTAssertEqual(
            DownloadQueuePolicy.overflowDownloadIDs(from: items, activeIDs: [1, 2, 3], limit: 1),
            [2, 3]
        )
        XCTAssertEqual(
            DownloadQueuePolicy.overflowDownloadIDs(
                from: [items[0], DownloadQueueItem(id: 4, state: .starting, createdAt: .distantFuture)],
                activeIDs: [1],
                limit: 1
            ),
            [4]
        )
    }

    func testRestorationAdmitsOldestActiveWorkAndRequeuesOverflow() {
        let items = [
            DownloadQueueItem(id: 1, state: .active, createdAt: Date(timeIntervalSince1970: 2)),
            DownloadQueueItem(id: 2, state: .starting, createdAt: Date(timeIntervalSince1970: 1)),
            DownloadQueueItem(id: 3, state: .queued, createdAt: Date(timeIntervalSince1970: 0)),
            DownloadQueueItem(id: 4, state: .active, createdAt: Date(timeIntervalSince1970: 3))
        ]

        let plan = DownloadQueuePolicy.restorationPlan(
            from: items,
            restoredIDs: [1, 2, 3],
            limit: 1
        )

        XCTAssertEqual(plan.admittedIDs, [2])
        XCTAssertEqual(plan.overflowIDs, [1, 4])
    }

    func testConcurrencyPreferencePersistsAllowedLimit() throws {
        let suiteName = "DownloadConcurrencyPreferenceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(DownloadConcurrencyPreference.limit(defaults: defaults), 3)
        DownloadConcurrencyPreference.setLimit(1, defaults: defaults)
        XCTAssertEqual(DownloadConcurrencyPreference.limit(defaults: defaults), 1)
        DownloadConcurrencyPreference.setLimit(99, defaults: defaults)
        XCTAssertEqual(DownloadConcurrencyPreference.limit(defaults: defaults), 1)
    }
}

final class DownloadQueueLifecyclePolicyTests: XCTestCase {
    func testBackgroundSessionRestorationRequiresSupportedIdentifierAndRealAPI() {
        XCTAssertTrue(
            DownloadQueueLifecyclePolicy.shouldRestoreBackgroundSession(
                identifier: DOWNLOAD_VIDEO_BACKGROUND_SESSION_IDENTIFIER,
                isMockAPIEnabled: false
            )
        )
        XCTAssertFalse(
            DownloadQueueLifecyclePolicy.shouldRestoreBackgroundSession(
                identifier: DOWNLOAD_VIDEO_BACKGROUND_SESSION_IDENTIFIER,
                isMockAPIEnabled: true
            )
        )
        XCTAssertFalse(
            DownloadQueueLifecyclePolicy.shouldRestoreBackgroundSession(
                identifier: "unsupported",
                isMockAPIEnabled: false
            )
        )
    }

    func testQueueStartsOnlyWhenRequestedOutsideMockMode() {
        XCTAssertTrue(DownloadQueueLifecyclePolicy.shouldStartQueue(requested: true, isMockAPIEnabled: false))
        XCTAssertFalse(DownloadQueueLifecyclePolicy.shouldStartQueue(requested: false, isMockAPIEnabled: false))
        XCTAssertFalse(DownloadQueueLifecyclePolicy.shouldStartQueue(requested: true, isMockAPIEnabled: true))
    }

    func testAccountChangeRequiresTwoDifferentKnownAccounts() {
        XCTAssertFalse(DownloadQueueLifecyclePolicy.accountDidChange(previousID: nil, currentID: 2))
        XCTAssertFalse(DownloadQueueLifecyclePolicy.accountDidChange(previousID: 2, currentID: 2))
        XCTAssertTrue(DownloadQueueLifecyclePolicy.accountDidChange(previousID: 1, currentID: 2))
    }

    func testCachedLaunchKnowsAccountOnlyWhenTheTokenOwnerIsTheCachedUser() {
        XCTAssertTrue(DownloadQueueLifecyclePolicy.cachedLaunchKnowsAccount(tokenOwnerID: 2, cachedUserID: 2))
        XCTAssertFalse(DownloadQueueLifecyclePolicy.cachedLaunchKnowsAccount(tokenOwnerID: 1, cachedUserID: 2))
        XCTAssertFalse(DownloadQueueLifecyclePolicy.cachedLaunchKnowsAccount(tokenOwnerID: nil, cachedUserID: 2))
        XCTAssertFalse(DownloadQueueLifecyclePolicy.cachedLaunchKnowsAccount(tokenOwnerID: nil, cachedUserID: nil))
    }

    func testUnsupportedBackgroundSessionCompletesImmediately() {
        let completed = expectation(description: "completion handler called")

        AppDelegate().application(
            UIApplication.shared,
            handleEventsForBackgroundURLSession: "unsupported"
        ) {
            completed.fulfill()
        }

        wait(for: [completed], timeout: 1)
    }
}

final class DownloadPersistencePolicyTests: XCTestCase {
    func testPersistenceRetriesOnceAndReturnsFinalResult() {
        var attempts = 0
        XCTAssertTrue(DownloadSupport.performWithOneRetry {
            attempts += 1
            return attempts == 2
        })
        XCTAssertEqual(attempts, 2)

        attempts = 0
        XCTAssertFalse(DownloadSupport.performWithOneRetry {
            attempts += 1
            return false
        })
        XCTAssertEqual(attempts, 2)
    }

    func testCompletionReleasesSlotOnlyAfterPersistence() {
        var releases = 0

        XCTAssertFalse(DownloadSupport.releaseAfterPersistence(false) { releases += 1 })
        XCTAssertEqual(releases, 0)
        XCTAssertTrue(DownloadSupport.releaseAfterPersistence(true) { releases += 1 })
        XCTAssertEqual(releases, 1)
    }
}

final class DownloadArtifactTests: XCTestCase {
    func testReplacementPreservesExistingFileOnCopyFailure() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtifactCopyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source")
        let destination = directory.appendingPathComponent("destination")
        try Data("complete".utf8).write(to: source)

        XCTAssertNil(DownloadSupport.copyDownloadedArtifact(from: source, to: destination))
        XCTAssertNotNil(
            DownloadSupport.copyDownloadedArtifact(
                from: directory.appendingPathComponent("missing"),
                to: destination
            )
        )
        XCTAssertEqual(try Data(contentsOf: destination), Data("complete".utf8))
    }

    func testReplacementReplacesExistingFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtifactReplacementTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source")
        let destination = directory.appendingPathComponent("destination")
        try Data("new".utf8).write(to: source)
        try Data("old".utf8).write(to: destination)

        XCTAssertNil(DownloadSupport.copyDownloadedArtifact(from: source, to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), Data("new".utf8))
    }

    func testHTTPErrorBodyIsNotSavedAsArtifact() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtifactStatusTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source")
        let destination = directory.appendingPathComponent("destination")
        let url = try XCTUnwrap(URL(string: "https://api.put.io/v2/files/1/stream"))
        let response = { (statusCode: Int) in
            HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil)
        }
        try Data("{\"error_type\":\"NotFound\"}".utf8).write(to: source)

        let error = DownloadSupport.saveDownloadedArtifact(response: response(404), from: source, to: destination)

        XCTAssertEqual(error as? DownloadSupport.ArtifactSaveError, .httpStatus(404))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))

        try Data("audio".utf8).write(to: source, options: .atomic)
        XCTAssertNil(DownloadSupport.saveDownloadedArtifact(response: response(200), from: source, to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), Data("audio".utf8))
    }
}

final class BackgroundDownloadSessionEventsTests: XCTestCase {
    func testFinishBeforeRegistrationStillCompletes() {
        let identifier = "BackgroundSessionTests-\(UUID().uuidString)"
        let completed = expectation(description: "completion handler called")

        BackgroundDownloadSessionEvents.finish(identifier: identifier, applicationState: .background)
        BackgroundDownloadSessionEvents.register(identifier: identifier) { completed.fulfill() }

        wait(for: [completed], timeout: 1)
    }
}

final class LegacyInstallCleanupTests: XCTestCase {
    func testFirstLaunchDropsTheLegacyURLCache() throws {
        let suiteName = "LegacyInstallCleanupTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let directory = FileManager.default.temporaryDirectory.appending(path: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        // On disk only, as 2.58.0 left it, with the token in the URL as 2.58.0 sent it.
        let cache = URLCache(memoryCapacity: 0, diskCapacity: 10_000_000, directory: directory)
        let token = "synthetic-token-\(UUID().uuidString)"
        let url = try XCTUnwrap(URL(string: "https://api.put.io/v2/files/list?oauth_token=\(token)"))
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Cache-Control": "max-age=3600"]))
        let request = URLRequest(url: url)
        cache.storeCachedResponse(CachedURLResponse(response: response, data: Data("{}".utf8)), for: request)
        let tokenOnDisk = {
            let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
            return files.contains { (try? Data(contentsOf: $0))?.range(of: Data(token.utf8)) != nil }
        }
        wait(for: [eventually("the response reaches disk", tokenOnDisk)], timeout: 10)

        LegacyInstallCleanup.runOnce(defaults: defaults, urlCache: cache)

        wait(for: [
            eventually("the response is gone") { cache.cachedResponse(for: request) == nil },
            eventually("the token is gone from disk") { !tokenOnDisk() },
            eventually("the cleanup is marked done") { defaults.bool(forKey: LegacyInstallCleanup.didRunKey) }
        ], timeout: 10)
    }

    private func eventually(_ description: String, _ condition: @escaping () -> Bool) -> XCTestExpectation {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        expectation.expectationDescription = description
        return expectation
    }
}

final class DownloadRestartTests: XCTestCase {
    func testRestartAnswerIgnoresDownloadDeletedWhileFileLookupRuns() throws {
        let realm = try Realm(configuration: Realm.Configuration(inMemoryIdentifier: #function))
        let download = Download()
        download.id = 112
        download.state = .stopped
        try realm.write { realm.add(download) }

        var requestedID: Int?
        var answer: ((Result<PutioFile, PutioSDKError>) -> Void)?
        RestartingDownloadPresenter().restartDownload(download) { id, completion in
            requestedID = id
            answer = completion
        }
        try realm.write { realm.delete(download) }

        let file = try JSONDecoder().decode(PutioFile.self, from: JSONSerialization.data(withJSONObject: [
            "id": 112,
            "name": "Episode",
            "icon": "file",
            "parent_id": 1,
            "file_type": "VIDEO",
            "size": 1024,
            "created_at": "2026-04-20T00:00:00Z",
            "updated_at": "2026-04-20T00:00:00Z",
            "is_shared": false
        ]))
        answer?(.success(file))

        XCTAssertEqual(requestedID, 112)
        XCTAssertTrue(download.isInvalidated)
    }
}

private final class RestartingDownloadPresenter: UIViewController, DownloadedFilePresenter {}

final class DownloadDeletionFlowTests: XCTestCase {
    private var realm: Realm!
    private var viewController: DeletingDownloadsViewController!
    private var rows: SingleRowDataSource!
    private var window: UIWindow!

    override func setUpWithError() throws {
        realm = try Realm(configuration: Realm.Configuration(inMemoryIdentifier: name))
        viewController = DeletingDownloadsViewController()
        rows = SingleRowDataSource()
        let tableView = UITableView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        tableView.dataSource = rows
        viewController.view.addSubview(tableView)
        viewController.tableView = tableView
        viewController.downloads = realm.objects(Download.self).sorted(byKeyPath: "createdAt")
        window = UIWindow(frame: tableView.frame)
        window.rootViewController = viewController
        window.isHidden = false
    }

    override func tearDown() {
        window.isHidden = true
        window = nil
        super.tearDown()
    }

    func testSwipeDeletionSurvivesRowRemovalWhileConfirmationIsPending() throws {
        let download = try addCompletedDownload(id: 301, name: "Pending Episode")
        var confirmedResults = [Bool]()
        let confirmation = try presentConfirmation { confirmedResults.append($0) }
        try realm.write { realm.delete(download) }

        try tap(NSLocalizedString("Delete", comment: ""), in: confirmation)

        XCTAssertEqual(confirmation.title, String(
            format: NSLocalizedString("Are you sure you want to delete %@?", comment: ""),
            "Pending Episode"
        ))
        XCTAssertEqual(confirmedResults, [true])
        XCTAssertEqual(viewController.presentedAlerts.count, 1)

        let cancelled = try addCompletedDownload(id: 302, name: "Cancelled Episode")
        var cancelledResults = [Bool]()
        let cancellation = try presentConfirmation { cancelledResults.append($0) }
        try realm.write { realm.delete(cancelled) }

        try tap(NSLocalizedString("Cancel", comment: ""), in: cancellation)

        XCTAssertEqual(cancelledResults, [false])
    }

    func testSwipeDeletionReturnsBeforeDiskWorkAndFinishesOnce() throws {
        try addCompletedDownload(id: 303, name: "Slow Episode")
        var pendingDeletion: ((Bool) -> Void)?
        viewController.deleteDownload = { id, fileType, completion in
            XCTAssertEqual(id, 303)
            XCTAssertEqual(fileType, .video)
            pendingDeletion = completion
        }
        var results = [Bool]()
        let confirmation = try presentConfirmation { results.append($0) }

        try tap(NSLocalizedString("Delete", comment: ""), in: confirmation)

        XCTAssertTrue(results.isEmpty)
        pendingDeletion?(false)
        XCTAssertEqual(results, [false])
        XCTAssertEqual(
            viewController.presentedAlerts.last?.title,
            NSLocalizedString("Couldn't Delete 1 Download", comment: "")
        )
    }

    func testBulkDeletionCallsManagersOnMainAndFinishes() {
        let items = [
            DownloadDeletionItem(id: 304, name: "First", fileType: .video),
            DownloadDeletionItem(id: 305, name: "Second", fileType: .audio)
        ]
        var calledOnMain = [Bool]()
        viewController.deleteDownload = { _, _, completion in
            calledOnMain.append(Thread.isMainThread)
            DispatchQueue.main.async { completion(true) }
        }

        viewController.deleteSelectedDownloads(items)

        let finished = expectation(for: NSPredicate { _, _ in
            self.viewController.isDeletingSelectedDownloads == false
        }, evaluatedWith: nil)
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(calledOnMain, [true, true])
        XCTAssertTrue(viewController.tableView.isUserInteractionEnabled)
    }

    @discardableResult
    private func addCompletedDownload(id: Int, name: String) throws -> Download {
        let download = Download()
        download.id = id
        download.name = name
        download.state = .completed
        download.fileType = .video
        download.createdAt = Date()
        try realm.write { realm.add(download) }
        viewController.tableView.reloadData()
        viewController.tableView.layoutIfNeeded()
        return download
    }

    private func presentConfirmation(_ handler: @escaping (Bool) -> Void) throws -> UIAlertController {
        let action = viewController.contextualDeleteAction(forRowAtIndexPath: IndexPath(row: 0, section: 0))
        let presentedCount = viewController.presentedAlerts.count
        action.handler(action, UIView()) { handler($0) }
        XCTAssertEqual(viewController.presentedAlerts.count, presentedCount + 1)
        return try XCTUnwrap(viewController.presentedAlerts.last)
    }

    private func tap(_ title: String, in alert: UIAlertController) throws {
        typealias AlertHandler = @convention(block) (UIAlertAction) -> Void
        let action = try XCTUnwrap(alert.actions.first { $0.title == title })
        let block = try XCTUnwrap(action.value(forKey: "handler") as AnyObject?)
        unsafeBitCast(block, to: AlertHandler.self)(action)
    }
}

private final class DeletingDownloadsViewController: DownloadsViewController {
    var presentedAlerts = [UIAlertController]()

    override func viewDidLoad() {}

    override func present(
        _ viewControllerToPresent: UIViewController,
        animated flag: Bool,
        completion: (() -> Void)? = nil
    ) {
        if let alert = viewControllerToPresent as? UIAlertController {
            presentedAlerts.append(alert)
        }
        completion?()
    }
}

private final class SingleRowDataSource: NSObject, UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 1 }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        UITableViewCell()
    }
}
