import AVFoundation
import MediaPlayer
import UIKit
import XCTest
@testable import Putio

final class AudioPlayerTests: XCTestCase {
    func testPlayerControlsHaveAccessibleTouchTargets() throws {
        let viewController = try makeStoryboardViewController()

        viewController.loadViewIfNeeded()
        viewController.view.layoutIfNeeded()

        XCTAssertGreaterThanOrEqual(viewController.controlRewind.bounds.height, 44)
        XCTAssertGreaterThanOrEqual(viewController.controlFastForward.bounds.height, 44)
        XCTAssertGreaterThanOrEqual(viewController.nextItemActionButton.bounds.height, 44)
        XCTAssertGreaterThanOrEqual(viewController.playbackRateButton.bounds.width, 48)
        XCTAssertGreaterThanOrEqual(viewController.playbackRateButton.bounds.height, 48)
        XCTAssertEqual(viewController.routePickerView.frame.size, CGSize(width: 44, height: 44))
    }

    func testPlaybackRateMenuExposesSupportedRates() throws {
        let viewController = AudioPlayerViewController()

        viewController.configurePlaybackRateControl()

        XCTAssertEqual(viewController.playbackRateButton.accessibilityValue, "1×")
        let actions = try XCTUnwrap(viewController.playbackRateButton.menu).children.compactMap { $0 as? UIAction }
        XCTAssertEqual(actions.map(\.title), ["0.25×", "0.5×", "0.75×", "1×", "1.25×", "1.5×", "2×"])
        XCTAssertEqual(actions.first(where: { $0.state == .on })?.title, "1×")
    }

    func testPlaybackRateIsScopedToOnePlayerQueue() {
        let viewController = AudioPlayerViewController()
        viewController.player = AVQueuePlayer()

        viewController.setPlaybackRate(1.5)

        XCTAssertEqual(viewController.queuePlaybackRate, 1.5)
        XCTAssertEqual(viewController.player?.defaultRate, 1.5)
        XCTAssertEqual(viewController.playbackRateButton.accessibilityValue, "1.5×")
        XCTAssertEqual(AudioPlayerViewController().queuePlaybackRate, 1)
    }

    func testNowPlayingMetadataDoesNotExposeTheAuthenticatedAssetURL() {
        let viewController = AudioPlayerViewController()
        let media = MediaPlayerItem(
            id: 1,
            name: "Audio",
            url: URL(string: "https://example.com/audio?oauth_token=secret")!,
            fileType: .audio,
            consumptionType: .online
        )

        viewController.updateMPNowPlayingInfo(for: media, currentTime: 10, duration: 60)

        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyAssetURL])
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func makeStoryboardViewController() throws -> AudioPlayerViewController {
        let viewController = try XCTUnwrap(
            UIStoryboard(name: "MediaPlayers", bundle: nil)
                .instantiateViewController(withIdentifier: "AudioPlayerVC") as? AudioPlayerViewController
        )
        viewController.mediaItems = []
        return viewController
    }
}
