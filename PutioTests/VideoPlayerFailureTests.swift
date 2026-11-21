import AVFoundation
import XCTest
@testable import Putio

final class VideoPlayerFailureTests: XCTestCase {
    func testOfflineFailurePostedOffTheMainThreadRecoversOnTheMainThread() {
        let (controller, playerItem) = makeOfflinePlayer()

        let recovered = expectation(description: "recovered")
        var recoveredOnMainThread = false
        controller.onLocalFileFailure = {
            recoveredOnMainThread = Thread.isMainThread
            recovered.fulfill()
        }

        DispatchQueue.global().async {
            NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: playerItem)
        }

        wait(for: [recovered], timeout: 5)
        XCTAssertTrue(recoveredOnMainThread)
    }

    func testOfflineFailureAfterThePlayerClosedLeavesTheDownloadAlone() {
        let (controller, playerItem) = makeOfflinePlayer()
        let recovered = expectation(description: "recovered")
        recovered.isInverted = true
        controller.onLocalFileFailure = { recovered.fulfill() }

        controller.viewWillDisappear(false)
        let disposed = expectation(description: "disposed")
        DispatchQueue.main.async { disposed.fulfill() }
        wait(for: [disposed], timeout: 1)

        NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: playerItem)
        wait(for: [recovered], timeout: 1)
    }

    func testOnlyAnUnreadableLocalFileCallsForARedownload() {
        let cannotOpen = NSError(domain: AVFoundationErrorDomain, code: AVError.Code.fileFormatNotRecognized.rawValue)
        let decoderFailed = NSError(domain: AVFoundationErrorDomain, code: AVError.Code.decodeFailed.rawValue)
        let servicesReset = NSError(domain: AVFoundationErrorDomain, code: AVError.Code.mediaServicesWereReset.rawValue)

        XCTAssertFalse(VideoPlayerViewController.isUnreadableLocalFile(URLError(.notConnectedToInternet), wasReadyToPlay: true))
        XCTAssertFalse(VideoPlayerViewController.isUnreadableLocalFile(URLError(.networkConnectionLost), wasReadyToPlay: true))
        XCTAssertFalse(VideoPlayerViewController.isUnreadableLocalFile(URLError(.timedOut), wasReadyToPlay: true))
        XCTAssertFalse(VideoPlayerViewController.isUnreadableLocalFile(URLError(.dataNotAllowed), wasReadyToPlay: true))
        XCTAssertTrue(VideoPlayerViewController.isUnreadableLocalFile(URLError(.notConnectedToInternet), wasReadyToPlay: false))
        XCTAssertTrue(VideoPlayerViewController.isUnreadableLocalFile(URLError(.fileDoesNotExist), wasReadyToPlay: true))
        XCTAssertTrue(VideoPlayerViewController.isUnreadableLocalFile(cannotOpen, wasReadyToPlay: false))
        XCTAssertFalse(VideoPlayerViewController.isUnreadableLocalFile(servicesReset, wasReadyToPlay: false))
        XCTAssertFalse(VideoPlayerViewController.isUnreadableLocalFile(decoderFailed, wasReadyToPlay: true))
        XCTAssertFalse(VideoPlayerViewController.isUnreadableLocalFile(nil, wasReadyToPlay: true))
    }

    private func makeOfflinePlayer() -> (VideoPlayerViewController, AVPlayerItem) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Missing.Sample.mp4")
        let playerItem = AVPlayerItem(url: url)
        let controller = VideoPlayerViewController()
        controller.item = MediaPlayerItem(id: 1, name: "Missing.Sample.mp4", url: url, fileType: .video, consumptionType: .offline)
        controller.player = AVPlayer(playerItem: playerItem)
        controller.loadViewIfNeeded()
        return (controller, playerItem)
    }
}
