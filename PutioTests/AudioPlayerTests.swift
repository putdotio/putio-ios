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

    func testNextItemActionHasA44PointTouchTarget() throws {
        let viewController = try XCTUnwrap(
            UIStoryboard(name: "MediaPlayers", bundle: nil)
                .instantiateViewController(withIdentifier: "AudioPlayerVC") as? AudioPlayerViewController
        )
        viewController.mediaItems = []

        viewController.loadViewIfNeeded()
        viewController.view.layoutIfNeeded()

        XCTAssertGreaterThanOrEqual(viewController.nextItemActionButton.bounds.width, 44)
        XCTAssertGreaterThanOrEqual(viewController.nextItemActionButton.bounds.height, 44)
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

    func testPlaybackRateRequestFromBackgroundQueueUpdatesTheControlOnMain() {
        let viewController = AudioPlayerViewController()
        viewController.configurePlaybackRateControl()
        let updated = expectation(description: "Playback rate control updated")

        DispatchQueue.global().async {
            viewController.setPlaybackRate(1.5)
            DispatchQueue.main.async {
                XCTAssertEqual(viewController.queuePlaybackRate, 1.5)
                XCTAssertEqual(viewController.playbackRateButton.accessibilityValue, "1.5×")
                updated.fulfill()
            }
        }

        wait(for: [updated], timeout: 2)
    }

    func testPlayRestoresTheSelectedQueueRateAsThePlayerDefault() {
        let viewController = AudioPlayerViewController()
        viewController.player = AVQueuePlayer()
        viewController.queuePlaybackRate = 1.5
        viewController.player?.defaultRate = 0.5

        viewController.playAtQueueRate()

        XCTAssertEqual(viewController.player?.defaultRate, 1.5)
    }

    func testRemoteMediaControlsRegisterAndUnregisterTheirExactTargets() {
        let viewController = AudioPlayerViewController()
        let commandCenter = MPRemoteCommandCenter.shared()

        viewController.registerRemoteMediaControls()

        XCTAssertEqual(
            Set(viewController.commandCenterTargets.keys),
            ["pause", "play", "skipBackward", "skipForward", "changePlaybackPosition", "changePlaybackRate"]
        )
        XCTAssertEqual(commandCenter.skipBackwardCommand.preferredIntervals, [15])
        XCTAssertEqual(commandCenter.skipForwardCommand.preferredIntervals, [15])
        XCTAssertTrue(commandCenter.changePlaybackRateCommand.isEnabled)
        XCTAssertEqual(
            commandCenter.changePlaybackRateCommand.supportedPlaybackRates,
            AudioPlayerViewController.supportedPlaybackRates.map(NSNumber.init(value:))
        )

        viewController.unregisterRemoteMediaControls()

        XCTAssertTrue(viewController.commandCenterTargets.isEmpty)
        XCTAssertEqual(commandCenter.skipBackwardCommand.preferredIntervals, [])
        XCTAssertEqual(commandCenter.skipForwardCommand.preferredIntervals, [])
        XCTAssertFalse(commandCenter.changePlaybackRateCommand.isEnabled)

        viewController.unregisterRemoteMediaControls()
        XCTAssertTrue(viewController.commandCenterTargets.isEmpty)
    }

    func testCompletedSeekPersistsThePlayerReportedPosition() throws {
        let media = MediaPlayerItem(
            id: 104,
            name: "Seekable.m4b",
            url: URL(fileURLWithPath: "/tmp/seekable.m4b"),
            fileType: .audio,
            consumptionType: .offline
        )
        let viewController = SeekObservingAudioPlayerViewController(media: media)
        let composition = AVMutableComposition()
        composition.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 120, preferredTimescale: 600)))
        viewController.player = AVQueuePlayer(playerItem: AVPlayerItem(asset: composition))
        let persisted = expectation(description: "Completed seek persisted")
        viewController.onSaveAudioTime = { persisted.fulfill() }

        viewController.onSeek(to: 30)

        wait(for: [persisted], timeout: 2)
        let savedPosition = try XCTUnwrap(viewController.savedPosition)
        let reportedCurrentTime = try XCTUnwrap(viewController.player?.currentItem?.currentTime().getFiniteSeconds())
        let reportedDuration = try XCTUnwrap(viewController.player?.currentItem?.duration.getFiniteSeconds())
        XCTAssertEqual(reportedCurrentTime, 30, accuracy: 0.1)
        XCTAssertEqual(savedPosition.currentTime, reportedCurrentTime, accuracy: 0.1)
        XCTAssertEqual(savedPosition.duration, reportedDuration, accuracy: 0.1)
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

private final class SeekObservingAudioPlayerViewController: AudioPlayerViewController {
    let media: MediaPlayerItem
    var savedPosition: (currentTime: Double, duration: Double)?
    var onSaveAudioTime: (() -> Void)?

    init(media: MediaPlayerItem) {
        self.media = media
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func findMediaItem(by playerItem: AVPlayerItem?) -> MediaPlayerItem? {
        return media
    }

    override func updateTimeDisplay(currentTime: Double, duration: Double) {}

    override func saveAudioTime(for item: MediaPlayerItem, currentTime: Double, duration: Double) {
        savedPosition = (currentTime, duration)
        onSaveAudioTime?()
    }
}
