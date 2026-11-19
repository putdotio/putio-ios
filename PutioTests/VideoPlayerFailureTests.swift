import AVFoundation
import XCTest
@testable import Putio

final class VideoPlayerFailureTests: XCTestCase {
    func testOfflineFailurePostedOffTheMainThreadRecoversOnTheMainThread() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Missing.Sample.mp4")
        let playerItem = AVPlayerItem(url: url)
        let controller = VideoPlayerViewController()
        controller.item = MediaPlayerItem(id: 1, name: "Missing.Sample.mp4", url: url, fileType: .video, consumptionType: .offline)
        controller.player = AVPlayer(playerItem: playerItem)
        controller.loadViewIfNeeded()

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
}
