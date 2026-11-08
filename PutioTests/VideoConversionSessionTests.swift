import XCTest
import UIKit
@testable import Putio
@testable import PutioSDK

final class VideoConversionSessionTests: XCTestCase {
    private final class ScheduledPoll {
        let delay: TimeInterval
        let work: () -> Void
        var isCancelled = false
        var hasFired = false

        init(delay: TimeInterval, work: @escaping () -> Void) {
            self.delay = delay
            self.work = work
        }
    }

    private final class Harness {
        var startCompletions: [(Result<Void, PutioSDKError>) -> Void] = []
        var statusCompletions: [(Result<VideoConversionSession.Progress, PutioSDKError>) -> Void] = []
        var fileCompletions: [(Result<PutioFile, PutioSDKError>) -> Void] = []
        var polls: [ScheduledPoll] = []

        lazy var session = VideoConversionSession(
            fileID: 42,
            startRequest: { [unowned self] _, completion in self.startCompletions.append(completion) },
            statusRequest: { [unowned self] _, completion in self.statusCompletions.append(completion) },
            fileRequest: { [unowned self] _, completion in self.fileCompletions.append(completion) },
            schedule: { [unowned self] delay, work in
                let poll = ScheduledPoll(delay: delay, work: work)
                self.polls.append(poll)
                return { poll.isCancelled = true }
            }
        )

        var pendingPolls: [ScheduledPoll] {
            polls.filter { !$0.isCancelled && !$0.hasFired }
        }

        func respondToStatus(_ status: PutioMp4Conversion.Status, percentDone: Float = 0.5) {
            statusCompletions.last?(.success(VideoConversionSession.Progress(status: status, percentDone: percentDone)))
        }

        func firePoll() {
            guard let poll = polls.last else { return }
            poll.hasFired = true
            poll.work()
        }
    }

    private final class DelegateSpy: VideoConversionViewControllerDelegate {
        var finishedFiles: [PutioFile] = []
        var dismissalsBeforeFinish = 0

        func videoConversionFinished(for file: PutioFile, intention: VideoConversionIntention) {
            finishedFiles.append(file)
        }

        func videoConversionControllerDismissedBeforeFinish() {
            dismissalsBeforeFinish += 1
        }
    }

    private let error = PutioSDKError.offline("/files/42/mp4")
    private let serverError = PutioSDKError(
        request: PutioSDKErrorRequestInformation(
            config: PutioSDKRequestConfig(apiConfig: PutioSDKConfig(clientID: "3001"), url: "/files/42/mp4", method: .post)
        ),
        statusCode: 500,
        errorType: "E2E_FORCED_FAILURE",
        message: "Forced failure",
        underlyingError: URLError(.badServerResponse)
    )
    private let somethingWentWrong = "Something went wrong\nPlease try again later"

    func testStartFailureFailsWithoutPolling() {
        let harness = Harness()
        harness.session.start()

        harness.startCompletions[0](.failure(error))

        assertFailure(harness.session.state) { if case .start = $0 { return true }; return false }
        XCTAssertTrue(harness.statusCompletions.isEmpty)
        XCTAssertTrue(harness.polls.isEmpty)
    }

    func testStatusFailuresRetryBoundedThenFail() {
        let harness = Harness()
        harness.session.start()
        harness.startCompletions[0](.success(()))

        for attempt in 1...VideoConversionSession.maxStatusRetries {
            harness.statusCompletions.last?(.failure(error))
            XCTAssertEqual(harness.pendingPolls.count, 1, "attempt \(attempt)")
            XCTAssertTrue(harness.session.isActive)
            harness.firePoll()
        }
        harness.statusCompletions.last?(.failure(error))

        XCTAssertEqual(harness.statusCompletions.count, VideoConversionSession.maxStatusRetries + 1)
        assertFailure(harness.session.state) { if case .status = $0 { return true }; return false }
        XCTAssertEqual(harness.polls.count, VideoConversionSession.maxStatusRetries)
    }

    func testStatusSuccessRestoresRetryBudget() {
        let harness = Harness()
        harness.session.start()
        harness.startCompletions[0](.success(()))

        for _ in 1...VideoConversionSession.maxStatusRetries {
            harness.statusCompletions.last?(.failure(error))
            harness.firePoll()
        }
        harness.respondToStatus(.converting)
        harness.firePoll()
        harness.statusCompletions.last?(.failure(error))

        XCTAssertTrue(harness.session.isActive)
        XCTAssertEqual(harness.pendingPolls.count, 1)
    }

    func testErrorStatusStopsPolling() {
        let harness = Harness()
        harness.session.start()
        harness.startCompletions[0](.success(()))

        harness.respondToStatus(.error)

        assertFailure(harness.session.state) {
            if case .conversion(let failed) = $0 { return failed == .error }
            return false
        }
        XCTAssertTrue(harness.polls.isEmpty)
    }

    func testNotAvailablePollsBoundedThenFails() {
        let harness = Harness()
        harness.session.start()
        harness.startCompletions[0](.success(()))

        for attempt in 1...VideoConversionSession.maxStatusRetries {
            harness.respondToStatus(.notAvailable)
            XCTAssertEqual(harness.pendingPolls.count, 1, "attempt \(attempt)")
            XCTAssertTrue(harness.session.isActive)
            harness.firePoll()
        }
        harness.respondToStatus(.notAvailable)

        assertFailure(harness.session.state) {
            if case .conversion(let failed) = $0 { return failed == .notAvailable }
            return false
        }
        XCTAssertTrue(harness.pendingPolls.isEmpty)
        XCTAssertEqual(harness.polls.count, VideoConversionSession.maxStatusRetries)
    }

    func testNotAvailableBeforeQueuedKeepsConverting() {
        let harness = Harness()
        harness.session.start()
        harness.startCompletions[0](.success(()))

        harness.respondToStatus(.notAvailable)
        harness.firePoll()
        harness.respondToStatus(.queued)

        guard case .converting = harness.session.state else {
            return XCTFail("expected converting, got \(harness.session.state)")
        }
        XCTAssertEqual(harness.pendingPolls.count, 1)
    }

    func testRetryAfterStatusFailureResumesPollingWithoutRestarting() {
        let harness = Harness()
        harness.session.start()
        harness.startCompletions[0](.success(()))
        for _ in 1...VideoConversionSession.maxStatusRetries {
            harness.statusCompletions.last?(.failure(error))
            harness.firePoll()
        }
        harness.statusCompletions.last?(.failure(error))

        harness.session.retry()

        XCTAssertEqual(harness.startCompletions.count, 1)
        XCTAssertEqual(harness.statusCompletions.count, VideoConversionSession.maxStatusRetries + 2)
        XCTAssertTrue(harness.session.isActive)
    }

    func testRetryAfterConvertedFileFailureRefetchesFileOnly() throws {
        let harness = Harness()
        harness.session.start()
        harness.startCompletions[0](.success(()))
        harness.respondToStatus(.completed, percentDone: 1)
        harness.fileCompletions[0](.failure(error))

        harness.session.retry()
        harness.fileCompletions[1](.success(try makePutioFile()))

        XCTAssertEqual(harness.startCompletions.count, 1)
        XCTAssertEqual(harness.statusCompletions.count, 1)
        guard case .finished = harness.session.state else {
            return XCTFail("expected finished, got \(harness.session.state)")
        }
    }

    func testConvertingPollsUntilCompletedAndFetchesConvertedFile() throws {
        let harness = Harness()
        let file = try makePutioFile()
        harness.session.start()
        harness.startCompletions[0](.success(()))

        harness.respondToStatus(.queued)
        XCTAssertEqual(harness.pendingPolls.map(\.delay), [VideoConversionSession.pollInterval])
        harness.firePoll()
        harness.respondToStatus(.converting)
        harness.firePoll()
        harness.respondToStatus(.completed, percentDone: 1)
        harness.fileCompletions[0](.success(file))

        guard case .finished(let finished) = harness.session.state else {
            return XCTFail("expected finished, got \(harness.session.state)")
        }
        XCTAssertEqual(finished.id, 42)
        XCTAssertEqual(harness.statusCompletions.count, 3)
        XCTAssertEqual(harness.polls.count, 2)
    }

    func testConvertedFileFailureFails() {
        let harness = Harness()
        harness.session.start()
        harness.startCompletions[0](.success(()))
        harness.respondToStatus(.completed, percentDone: 1)

        harness.fileCompletions[0](.failure(error))

        assertFailure(harness.session.state) { if case .convertedFile = $0 { return true }; return false }
    }

    func testCancelBeforeStartResponseIgnoresLateResponse() {
        let harness = Harness()
        harness.session.start()

        harness.session.cancel()
        harness.startCompletions[0](.success(()))

        assertCancelled(harness.session.state)
        XCTAssertTrue(harness.statusCompletions.isEmpty)
        XCTAssertTrue(harness.polls.isEmpty)
    }

    func testCancelBeforeScheduledPollCancelsIt() {
        let harness = Harness()
        harness.session.start()
        harness.startCompletions[0](.success(()))
        harness.respondToStatus(.converting)

        harness.session.cancel()

        XCTAssertTrue(harness.pendingPolls.isEmpty)
        harness.firePoll()
        XCTAssertEqual(harness.statusCompletions.count, 1)
        assertCancelled(harness.session.state)
    }

    func testCancelBeforeConvertedFileResponseNeverFinishes() throws {
        let harness = Harness()
        harness.session.start()
        harness.startCompletions[0](.success(()))
        harness.respondToStatus(.completed, percentDone: 1)

        harness.session.cancel()
        harness.fileCompletions[0](.success(try makePutioFile()))

        assertCancelled(harness.session.state)
    }

    func testRetryIgnoresCallbacksFromTheFailedAttempt() {
        let harness = Harness()
        harness.session.start()
        harness.startCompletions[0](.success(()))
        harness.respondToStatus(.error)

        harness.session.start()
        harness.statusCompletions[0](.success(VideoConversionSession.Progress(status: .converting, percentDone: 0.5)))

        guard case .starting = harness.session.state else {
            return XCTFail("expected starting, got \(harness.session.state)")
        }
        XCTAssertEqual(harness.startCompletions.count, 2)
        XCTAssertTrue(harness.polls.isEmpty)
    }

    func testClosingTheScreenBeforeCompletionNeverFinishes() throws {
        let harness = Harness()
        let delegate = DelegateSpy()
        let storyboard = UIStoryboard(name: "VideoConversion", bundle: Bundle(for: VideoConversionViewController.self))
        let viewController = try XCTUnwrap(storyboard.instantiateViewController(withIdentifier: "VideoConversionVC") as? VideoConversionViewController)
        viewController.file = try makePutioFile()
        viewController.intention = .play
        viewController.delegate = delegate
        viewController.session = harness.session

        viewController.loadViewIfNeeded()
        harness.startCompletions[0](.success(()))
        harness.respondToStatus(.completed, percentDone: 1)
        viewController.closeButtonTapped(viewController)
        harness.fileCompletions[0](.success(try makePutioFile()))

        assertCancelled(harness.session.state)
        XCTAssertTrue(delegate.finishedFiles.isEmpty)
    }

    func testFailureShowsLocalizedRecovery() throws {
        let harness = Harness()
        let storyboard = UIStoryboard(name: "VideoConversion", bundle: Bundle(for: VideoConversionViewController.self))
        let viewController = try XCTUnwrap(storyboard.instantiateViewController(withIdentifier: "VideoConversionVC") as? VideoConversionViewController)
        viewController.file = try makePutioFile()
        viewController.intention = .play
        viewController.session = harness.session

        viewController.loadViewIfNeeded()
        harness.startCompletions[0](.failure(error))

        XCTAssertEqual(
            viewController.statusLabel.text,
            "\(NSLocalizedString("Network error", comment: ""))\n\(NSLocalizedString("Please check your internet connection and try again.", comment: ""))"
        )
        XCTAssertTrue(viewController.progressView.isHidden)
        XCTAssertEqual(viewController.navigationItem.rightBarButtonItem?.title, NSLocalizedString("Retry", comment: ""))

        viewController.navigationItem.rightBarButtonItem?.primaryAction?.performWithSender(nil, target: nil)
        XCTAssertEqual(harness.startCompletions.count, 2)
        XCTAssertNil(viewController.navigationItem.rightBarButtonItem)
        XCTAssertFalse(viewController.progressView.isHidden)

        harness.startCompletions[1](.success(()))
        harness.respondToStatus(.error)

        XCTAssertEqual(
            viewController.statusLabel.text,
            "\(NSLocalizedString("This video couldn't be converted", comment: ""))\n\(NSLocalizedString("Please try again later", comment: ""))"
        )
        XCTAssertEqual(viewController.navigationItem.rightBarButtonItem?.title, NSLocalizedString("Retry", comment: ""))
    }

    func testEveryFailedRequestSaysSomethingWentWrongAndOffersRetry() throws {
        let failures: [(String, (Harness) -> Void)] = [
            ("start", { harness in
                harness.startCompletions[0](.failure(self.serverError))
            }),
            ("status, after the bounded retries", { harness in
                harness.startCompletions[0](.success(()))
                for _ in 1...VideoConversionSession.maxStatusRetries {
                    harness.statusCompletions.last?(.failure(self.serverError))
                    XCTAssertEqual(harness.pendingPolls.count, 1)
                    harness.firePoll()
                }
                harness.statusCompletions.last?(.failure(self.serverError))
            }),
            ("converted file", { harness in
                harness.startCompletions[0](.success(()))
                harness.respondToStatus(.completed, percentDone: 1)
                harness.fileCompletions[0](.failure(self.serverError))
            })
        ]

        for (request, fail) in failures {
            let harness = Harness()
            let delegate = DelegateSpy()
            let viewController = try makeViewController(session: harness.session, delegate: delegate)
            viewController.loadViewIfNeeded()

            fail(harness)

            XCTAssertEqual(viewController.statusLabel.text, somethingWentWrong, request)
            XCTAssertTrue(viewController.progressView.isHidden, request)
            XCTAssertEqual(viewController.navigationItem.rightBarButtonItem?.title, "Retry", request)
            XCTAssertTrue(delegate.finishedFiles.isEmpty, request)
        }
    }

    func testCloseAfterAFailureDismissesWithoutFinishing() throws {
        let harness = Harness()
        let delegate = DelegateSpy()
        let (root, viewController) = try presentConversion(session: harness.session, delegate: delegate)
        harness.startCompletions[0](.failure(serverError))
        XCTAssertEqual(viewController.navigationItem.rightBarButtonItem?.title, "Retry")

        try tapClose(on: viewController)

        waitUntil { root.presentedViewController == nil }
        XCTAssertNil(root.presentedViewController)
        XCTAssertTrue(delegate.finishedFiles.isEmpty)
        XCTAssertEqual(delegate.dismissalsBeforeFinish, 1)
    }

    func testClosingBeforeTheStartResponseNeverContinuesToPlayback() throws {
        let harness = Harness()
        let delegate = DelegateSpy()
        let (root, viewController) = try presentConversion(session: harness.session, delegate: delegate)

        try tapClose(on: viewController)
        waitUntil { root.presentedViewController == nil }
        harness.startCompletions[0](.success(()))
        harness.respondToStatus(.completed, percentDone: 1)
        harness.fileCompletions.first?(.success(try makePutioFile()))

        XCTAssertNil(root.presentedViewController)
        XCTAssertTrue(harness.statusCompletions.isEmpty)
        XCTAssertTrue(harness.fileCompletions.isEmpty)
        XCTAssertTrue(delegate.finishedFiles.isEmpty)
    }

    private func makeViewController(session: VideoConversionSession, delegate: DelegateSpy) throws -> VideoConversionViewController {
        let storyboard = UIStoryboard(name: "VideoConversion", bundle: Bundle(for: VideoConversionViewController.self))
        let viewController = try XCTUnwrap(storyboard.instantiateViewController(withIdentifier: "VideoConversionVC") as? VideoConversionViewController)
        viewController.file = try makePutioFile()
        viewController.intention = .play
        viewController.delegate = delegate
        viewController.session = session
        return viewController
    }

    private func presentConversion(
        session: VideoConversionSession,
        delegate: DelegateSpy
    ) throws -> (UIViewController, VideoConversionViewController) {
        let storyboard = UIStoryboard(name: "VideoConversion", bundle: Bundle(for: VideoConversionViewController.self))
        let navigation = try XCTUnwrap(storyboard.instantiateViewController(withIdentifier: "VideoConversionNC") as? UINavigationController)
        let viewController = try XCTUnwrap(navigation.viewControllers.first as? VideoConversionViewController)
        viewController.file = try makePutioFile()
        viewController.intention = .play
        viewController.delegate = delegate
        viewController.session = session

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let root = UIViewController()
        window.rootViewController = root
        window.isHidden = false
        addTeardownBlock { window.isHidden = true }

        let presented = expectation(description: "presented")
        root.present(navigation, animated: false) { presented.fulfill() }
        wait(for: [presented], timeout: 5)
        return (root, viewController)
    }

    private func tapClose(on viewController: VideoConversionViewController) throws {
        let close = try XCTUnwrap(viewController.navigationItem.leftBarButtonItem)
        let action = try XCTUnwrap(close.action)
        XCTAssertTrue(UIApplication.shared.sendAction(action, to: close.target, from: close, for: nil))
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private func assertFailure(
        _ state: VideoConversionSession.State,
        file: StaticString = #filePath,
        line: UInt = #line,
        matches: (VideoConversionSession.Failure) -> Bool
    ) {
        guard case .failed(let failure) = state, matches(failure) else {
            return XCTFail("unexpected state \(state)", file: file, line: line)
        }
    }

    private func assertCancelled(_ state: VideoConversionSession.State, file: StaticString = #filePath, line: UInt = #line) {
        guard case .cancelled = state else {
            return XCTFail("expected cancelled, got \(state)", file: file, line: line)
        }
    }

    private func makePutioFile() throws -> PutioFile {
        let payload: [String: Any] = [
            "id": 42,
            "name": "Episode",
            "icon": "video",
            "parent_id": 0,
            "file_type": "VIDEO",
            "size": 1024,
            "created_at": "2026-04-20T00:00:00Z",
            "updated_at": "2026-04-20T00:00:00Z",
            "is_shared": false,
            "start_from": 0
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(PutioFile.self, from: data)
    }
}
