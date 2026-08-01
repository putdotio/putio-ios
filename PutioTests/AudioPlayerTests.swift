import AVFoundation
import AVKit
import MediaPlayer
import UIKit
import XCTest
@testable import Putio

final class AudioPlayerTests: XCTestCase {
    func testNavigationUsesAFunctionalAudioRoutePicker() {
        let viewController = AudioPlayerViewController()

        viewController.configureNavigationControls()

        XCTAssertIdentical(viewController.navigationItem.rightBarButtonItem?.customView, viewController.routePickerView)
        XCTAssertEqual(viewController.routePickerView.frame.size, CGSize(width: 44, height: 44))
        XCTAssertFalse(viewController.routePickerView.prioritizesVideoDevices)
        XCTAssertEqual(viewController.routePickerView.tintColor, UIColor.Putio.Neutral.text)
        XCTAssertEqual(viewController.routePickerView.activeTintColor, UIColor.Putio.Yellow.textSecondary)
        XCTAssertEqual(viewController.routePickerView.accessibilityIdentifier, "audio-output-route-picker")
    }

    func testPlaybackRateControlExposesEverySupportedRateToVoiceOver() throws {
        let viewController = AudioPlayerViewController()

        viewController.configurePlaybackRateControl()

        XCTAssertNil(viewController.navigationItem.rightBarButtonItem)
        XCTAssertEqual(viewController.playbackRateButton.title(for: .normal), "1×")
        XCTAssertTrue(viewController.playbackRateButton.isEnabled)
        XCTAssertTrue(viewController.playbackRateButton.showsMenuAsPrimaryAction)
        XCTAssertEqual(viewController.playbackRateButton.accessibilityLabel, NSLocalizedString("Playback speed", comment: ""))
        XCTAssertEqual(viewController.playbackRateButton.accessibilityValue, "1×")
        XCTAssertEqual(viewController.playbackRateButton.accessibilityHint, NSLocalizedString("Applies to this queue", comment: ""))

        let menu = try XCTUnwrap(viewController.playbackRateButton.menu)
        let actions = menu.children.compactMap { $0 as? UIAction }
        XCTAssertEqual(menu.title, NSLocalizedString("Playback Speed", comment: ""))
        XCTAssertEqual(actions.map(\.title), ["0.25×", "0.5×", "0.75×", "1×", "1.25×", "1.5×", "2×"])
        XCTAssertEqual(actions.first(where: { $0.state == .on })?.title, "1×")
    }

    func testPlaybackRateIsScopedToTheCurrentQueueAndCanResetToNormal() {
        let viewController = AudioPlayerViewController()
        viewController.player = AVQueuePlayer()
        viewController.configurePlaybackRateControl()

        viewController.setPlaybackRate(1.5)

        XCTAssertEqual(viewController.queuePlaybackRate, 1.5)
        XCTAssertEqual(viewController.player?.defaultRate, 1.5)
        XCTAssertEqual(viewController.playbackRateButton.accessibilityValue, "1.5×")

        viewController.player?.removeAllItems()
        XCTAssertEqual(viewController.player?.defaultRate, 1.5)

        viewController.setPlaybackRate(1)
        XCTAssertEqual(viewController.queuePlaybackRate, 1)
        XCTAssertEqual(viewController.player?.defaultRate, 1)
        XCTAssertEqual(viewController.playbackRateButton.accessibilityValue, "1×")

        XCTAssertEqual(AudioPlayerViewController().queuePlaybackRate, 1)
    }

    func testPlayRestoresTheSelectedQueueRateAsThePlayerDefault() {
        let viewController = AudioPlayerViewController()
        viewController.player = AVQueuePlayer()
        viewController.queuePlaybackRate = 1.5
        viewController.player?.defaultRate = 0.5

        viewController.playAtQueueRate()

        XCTAssertEqual(viewController.player?.defaultRate, 1.5)
    }

    func testProgressIsTrackedAtEverySupportedPlaybackRate() {
        let viewController = AudioPlayerViewController()

        XCTAssertTrue(AudioPlayerViewController.supportedPlaybackRates.allSatisfy(viewController.shouldTrackPlayback(at:)))
        XCTAssertFalse(viewController.shouldTrackPlayback(at: 0))
    }

    func testNowPlayingInfoIncludesSelectedAndActualPlaybackRates() throws {
        let viewController = AudioPlayerViewController()
        viewController.queuePlaybackRate = 1.5
        let item = MediaPlayerItem(
            id: 103,
            name: "Audiobook.m4b",
            url: URL(fileURLWithPath: "/tmp/audiobook.m4b"),
            fileType: .audio,
            consumptionType: .offline
        )

        let info = viewController.makeMPNowPlayingInfo(
            for: item,
            currentTime: 90,
            duration: 3_600,
            playbackRate: 0
        )

        XCTAssertEqual(try XCTUnwrap(info[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber).floatValue, 0)
        XCTAssertEqual(try XCTUnwrap(info[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? NSNumber).floatValue, 1.5)
        XCTAssertEqual(try XCTUnwrap(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? NSNumber).doubleValue, 90)
        XCTAssertEqual(try XCTUnwrap(info[MPMediaItemPropertyPlaybackDuration] as? NSNumber).doubleValue, 3_600)
    }
}
