import Foundation
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
