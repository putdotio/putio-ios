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
        let viewController = try makeStoryboardViewController()

        viewController.loadViewIfNeeded()
        viewController.view.layoutIfNeeded()

        XCTAssertGreaterThanOrEqual(viewController.nextItemActionButton.bounds.width, 44)
        XCTAssertGreaterThanOrEqual(viewController.nextItemActionButton.bounds.height, 44)
    }

    func testSkipActionsHave44PointTouchTargets() throws {
        let viewController = try makeStoryboardViewController()

        viewController.loadViewIfNeeded()
        viewController.view.layoutIfNeeded()

        XCTAssertGreaterThanOrEqual(viewController.controlRewind.bounds.height, 44)
        XCTAssertGreaterThanOrEqual(viewController.controlFastForward.bounds.height, 44)
    }

    func testAudioPlayerScrollsWhenTheAvailableHeightIsCompact() throws {
        let viewController = try makeStoryboardViewController()
        viewController.loadViewIfNeeded()
        viewController.view.frame = CGRect(x: 0, y: 0, width: 667, height: 320)

        viewController.view.layoutIfNeeded()

        let scrollView = try XCTUnwrap(viewController.playerScrollView)
        let controls = try XCTUnwrap(viewController.controlPlayPause.superview)
        XCTAssertGreaterThan(scrollView.contentSize.height, scrollView.bounds.height)
        XCTAssertFalse(viewController.playerContentView.hasAmbiguousLayout)
        XCTAssertEqual(viewController.playerContentView.bounds.maxY - controls.frame.maxY, 8, accuracy: 0.5)
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
        let registeredCommands = [
            commandCenter.pauseCommand,
            commandCenter.playCommand,
            commandCenter.skipBackwardCommand,
            commandCenter.skipForwardCommand,
            commandCenter.changePlaybackPositionCommand,
            commandCenter.changePlaybackRateCommand
        ]

        viewController.unregisterRemoteMediaControls()
        viewController.registerRemoteMediaControls()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: "Test audio"]

        XCTAssertEqual(
            Set(viewController.commandCenterTargets.keys),
            ["pause", "play", "skipBackward", "skipForward", "changePlaybackPosition", "changePlaybackRate"]
        )
        XCTAssertEqual(commandCenter.skipBackwardCommand.preferredIntervals, [15])
        XCTAssertEqual(commandCenter.skipForwardCommand.preferredIntervals, [15])
        XCTAssertTrue(registeredCommands.allSatisfy(\.isEnabled))
        XCTAssertEqual(
            commandCenter.changePlaybackRateCommand.supportedPlaybackRates,
            AudioPlayerViewController.supportedPlaybackRates.map(NSNumber.init(value:))
        )
        XCTAssertNotNil(MPNowPlayingInfoCenter.default().nowPlayingInfo)

        viewController.unregisterRemoteMediaControls()

        XCTAssertTrue(viewController.commandCenterTargets.isEmpty)
        XCTAssertEqual(commandCenter.skipBackwardCommand.preferredIntervals, [])
        XCTAssertEqual(commandCenter.skipForwardCommand.preferredIntervals, [])
        XCTAssertTrue(registeredCommands.allSatisfy { !$0.isEnabled })
        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo)

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

    func testCompletedSeekDoesNotPersistAfterTheQueueAdvances() throws {
        let media = MediaPlayerItem(
            id: 105,
            name: "Queue transition.m4b",
            url: URL(fileURLWithPath: "/tmp/queue-transition.m4b"),
            fileType: .audio,
            consumptionType: .offline
        )
        let viewController = DeferredSeekAudioPlayerViewController(media: media)
        let composition = AVMutableComposition()
        composition.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 120, preferredTimescale: 600)))
        let firstItem = AVPlayerItem(asset: composition)
        let secondItem = AVPlayerItem(asset: composition)
        viewController.player = AVQueuePlayer(items: [firstItem, secondItem])
        let incorrectlyPersisted = expectation(description: "Superseded seek was not persisted")
        incorrectlyPersisted.isInverted = true
        viewController.onSaveAudioTime = { incorrectlyPersisted.fulfill() }

        viewController.onSeek(to: 30)
        viewController.player?.advanceToNextItem()
        viewController.completeSeek(finished: true)

        wait(for: [incorrectlyPersisted], timeout: 0.2)
        XCTAssertNil(viewController.savedPosition)
    }

    func testCurrentItemReadinessPublishesNowPlayingMetadata() throws {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        let audioURL = try makeSilentAudioURL(duration: 10)
        let media = MediaPlayerItem(
            id: 106,
            name: "Ready item.m4b",
            url: audioURL,
            fileType: .audio,
            consumptionType: .offline
        )
        let viewController = AudioPlayerViewController()
        viewController.mediaItems = [media]
        let playerItem = AVPlayerItem(url: audioURL)
        viewController.player = AVQueuePlayer(playerItem: playerItem)

        viewController.observeNowPlayingReadiness(for: playerItem)
        viewController.player?.play()

        let ready = NSPredicate(format: "status == %d", AVPlayerItem.Status.readyToPlay.rawValue)
        expectation(for: ready, evaluatedWith: playerItem)
        waitForExpectations(timeout: 2)
        let metadataPublished = expectation(description: "Ready item metadata published")
        DispatchQueue.main.async {
            let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
            XCTAssertEqual(info?[MPMediaItemPropertyTitle] as? String, media.name)
            XCTAssertEqual(
                (info?[MPMediaItemPropertyPlaybackDuration] as? NSNumber)?.doubleValue ?? -1,
                10,
                accuracy: 0.1
            )
            metadataPublished.fulfill()
        }
        wait(for: [metadataPublished], timeout: 1)

        viewController.disposePlayer()
        XCTAssertNil(viewController.player)
        XCTAssertNil(viewController.playerItemStatusObserver)
        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo)
    }

    func testDisposePreventsQueuedReadinessAndSeekWorkFromPublishing() throws {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        let media = MediaPlayerItem(
            id: 107,
            name: "Disposed item.m4b",
            url: URL(fileURLWithPath: "/tmp/disposed-item.m4b"),
            fileType: .audio,
            consumptionType: .offline
        )
        let viewController = DeferredSeekAudioPlayerViewController(media: media)
        let composition = AVMutableComposition()
        composition.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 120, preferredTimescale: 600)))
        let playerItem = AVPlayerItem(asset: composition)
        viewController.player = AVQueuePlayer(playerItem: playerItem)
        let incorrectlyPersisted = expectation(description: "Disposed seek was not persisted")
        incorrectlyPersisted.isInverted = true
        viewController.onSaveAudioTime = { incorrectlyPersisted.fulfill() }

        viewController.onSeek(to: 30)
        viewController.disposePlayer()
        viewController.publishNowPlayingInfoIfCurrent(playerItem)
        viewController.completeSeek(finished: true)

        wait(for: [incorrectlyPersisted], timeout: 0.2)
        XCTAssertNil(viewController.player)
        XCTAssertNil(viewController.savedPosition)
        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo)
    }

    func testProgressIsTrackedAtEverySupportedPlaybackRate() {
        let viewController = AudioPlayerViewController()

        XCTAssertTrue(AudioPlayerViewController.supportedPlaybackRates.allSatisfy(viewController.shouldTrackPlayback(at:)))
        XCTAssertFalse(viewController.shouldTrackPlayback(at: 0))
    }

    func testNowPlayingInfoOmitsAssetURLAndIncludesSelectedAndActualPlaybackRates() throws {
        let viewController = AudioPlayerViewController()
        viewController.queuePlaybackRate = 1.5
        let item = MediaPlayerItem(
            id: 103,
            name: "Audiobook.m4b",
            url: try XCTUnwrap(URL(string: "https://example.com/audiobook.m4b?oauth_token=secret")),
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
        XCTAssertNil(info[MPMediaItemPropertyAssetURL])
    }

    private func makeStoryboardViewController() throws -> AudioPlayerViewController {
        let viewController = try XCTUnwrap(
            UIStoryboard(name: "MediaPlayers", bundle: nil)
                .instantiateViewController(withIdentifier: "AudioPlayerVC") as? AudioPlayerViewController
        )
        viewController.mediaItems = []
        return viewController
    }

    private func makeSilentAudioURL(duration: UInt32) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("putio-audio-test-\(UUID().uuidString).wav")
        let sampleRate: UInt32 = 8_000
        let dataSize = sampleRate * duration * 2
        var wav = Data()

        func append(_ ascii: String) {
            wav.append(contentsOf: ascii.utf8)
        }
        func append32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) }
        }
        func append16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) }
        }

        append("RIFF")
        append32(36 + dataSize)
        append("WAVEfmt ")
        append32(16)
        append16(1)
        append16(1)
        append32(sampleRate)
        append32(sampleRate * 2)
        append16(2)
        append16(16)
        append("data")
        append32(dataSize)
        wav.append(Data(count: Int(dataSize)))
        try wav.write(to: url, options: .atomic)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

private class SeekObservingAudioPlayerViewController: AudioPlayerViewController {
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

private final class DeferredSeekAudioPlayerViewController: SeekObservingAudioPlayerViewController {
    private var completion: ((Bool) -> Void)?

    override func performSeek(
        on player: AVPlayer,
        to time: CMTime,
        completion: @escaping (Bool) -> Void
    ) {
        self.completion = completion
    }

    func completeSeek(finished: Bool) {
        completion?(finished)
        completion = nil
    }
}
