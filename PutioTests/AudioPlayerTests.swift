import AVFoundation
import MediaPlayer
import UIKit
import XCTest
@testable import Putio

final class AudioPlayerTests: XCTestCase {
    override func tearDown() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        super.tearDown()
    }

    func testPlayerControlsHaveAccessibleTouchTargets() throws {
        let viewController = try makeStoryboardViewController()

        viewController.loadViewIfNeeded()
        viewController.view.layoutIfNeeded()

        XCTAssertGreaterThanOrEqual(viewController.controlRewind.bounds.height, 44)
        XCTAssertGreaterThanOrEqual(viewController.controlFastForward.bounds.height, 44)
        XCTAssertGreaterThanOrEqual(viewController.nextItemActionButton.bounds.height, 44)
        XCTAssertGreaterThanOrEqual(viewController.playbackRateButton.bounds.width, 48)
        XCTAssertGreaterThanOrEqual(viewController.playbackRateButton.bounds.height, 48)
        XCTAssertGreaterThanOrEqual(viewController.routePickerView.frame.width, 44)
        XCTAssertGreaterThanOrEqual(viewController.routePickerView.frame.height, 44)
        XCTAssertEqual(viewController.playbackRateButton.titleLabel?.font.fontName, viewController.currentTimeLabel.font.fontName)
        XCTAssertEqual(viewController.playbackRateButton.titleLabel?.font.pointSize, viewController.currentTimeLabel.font.pointSize)
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

        viewController.player?.defaultRate = 1
        viewController.playAtQueueRate()

        XCTAssertEqual(viewController.player?.defaultRate, 1.5)
    }

    func testRateChangeRefreshesNowPlayingMetadataWithoutExposingTheAssetURL() {
        let viewController = AudioPlayerViewController()
        let media = MediaPlayerItem(
            id: 1,
            name: "Audio",
            url: URL(string: "https://example.com/audio?oauth_token=secret")!,
            fileType: .audio,
            consumptionType: .online
        )
        viewController.mediaItems = [media]
        viewController.player = AVQueuePlayer(items: [AVPlayerItem(url: media.url)])

        viewController.setPlaybackRate(1.5)

        let nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo
        XCTAssertEqual(nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "Audio")
        XCTAssertEqual(nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Float, 0)
        XCTAssertEqual(nowPlayingInfo?[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? Float, 1.5)
        XCTAssertNil(nowPlayingInfo?[MPMediaItemPropertyAssetURL])
    }

    func testEmptyQueueClearsNowPlayingMetadata() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: "Stale audio"]
        let viewController = AudioPlayerViewController()
        viewController.player = AVQueuePlayer()

        viewController.refreshNowPlayingInfo()

        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo)
    }

    func testCompactHeightLayoutCollapsesOnlyTheArtwork() throws {
        let viewController = try makeStoryboardViewController()
        viewController.loadViewIfNeeded()

        viewController.updateCompactHeightLayout(isCompact: true)

        XCTAssertTrue(viewController.posterContainerView.isHidden)
        XCTAssertEqual(viewController.compactArtworkHeightConstraint?.isActive, true)
        XCTAssertTrue(viewController.posterContentConstraints.allSatisfy { !$0.isActive })
        XCTAssertTrue(viewController.nextItemContainerView.isHidden)
        XCTAssertEqual(viewController.compactNextItemHeightConstraint?.isActive, true)
        XCTAssertTrue(viewController.nextItemContentConstraints.allSatisfy { !$0.isActive })
        XCTAssertEqual(viewController.trackTitleLabel.numberOfLines, 1)
        XCTAssertFalse(viewController.playbackInfoStackView.isHidden)

        viewController.updateCompactHeightLayout(isCompact: false)

        XCTAssertFalse(viewController.posterContainerView.isHidden)
        XCTAssertEqual(viewController.compactArtworkHeightConstraint?.isActive, false)
        XCTAssertTrue(viewController.posterContentConstraints.allSatisfy { $0.isActive })
        XCTAssertFalse(viewController.nextItemContainerView.isHidden)
        XCTAssertEqual(viewController.compactNextItemHeightConstraint?.isActive, false)
        XCTAssertTrue(viewController.nextItemContentConstraints.allSatisfy { $0.isActive })
        XCTAssertEqual(viewController.trackTitleLabel.numberOfLines, 2)
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
