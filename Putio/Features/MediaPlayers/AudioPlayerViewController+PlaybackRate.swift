import AVFoundation
import MediaPlayer
import UIKit

extension AudioPlayerViewController {
    func configureScrollableLayout() {
        guard playerScrollView == nil,
              let rootView = playerContentView.superview,
              rootView === nextItemContainerView.superview else {
            return
        }

        let arrangedViews = [playerContentView, nextItemContainerView]
        let originalConstraints = rootView.constraints.filter { constraint in
            arrangedViews.contains { candidate in
                (constraint.firstItem as? UIView) === candidate ||
                    (constraint.secondItem as? UIView) === candidate
            }
        }
        NSLayoutConstraint.deactivate(originalConstraints)
        playerContentView.removeFromSuperview()
        nextItemContainerView.removeFromSuperview()

        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.accessibilityIdentifier = "audio-player-scroll-view"
        rootView.addSubview(scrollView)

        let contentView = UIView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentView)
        contentView.addSubview(playerContentView)
        contentView.addSubview(nextItemContainerView)

        let nextItemLeading = nextItemContainerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16)
        nextItemLeading.priority = .defaultHigh
        let nextItemTrailing = nextItemContainerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16)
        nextItemTrailing.priority = .defaultHigh

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: rootView.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: rootView.safeAreaLayoutGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: rootView.safeAreaLayoutGuide.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: rootView.safeAreaLayoutGuide.bottomAnchor),
            contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            contentView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.heightAnchor),
            playerContentView.topAnchor.constraint(equalTo: contentView.topAnchor),
            playerContentView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            playerContentView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            nextItemContainerView.topAnchor.constraint(greaterThanOrEqualTo: playerContentView.bottomAnchor, constant: 16),
            nextItemLeading,
            nextItemTrailing,
            nextItemContainerView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            nextItemContainerView.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
            nextItemContainerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16)
        ])

        playerScrollView = scrollView
    }

    func configurePlaybackRateControl() {
        if playbackRateButton.superview == nil, let playbackInfoStackView {
            playbackInfoStackView.insertArrangedSubview(playbackRateButton, at: 1)
            playbackRateButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
            playbackRateButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        }
        updatePlaybackRateControl()
    }

    func updatePlaybackRateControl() {
        let selectedRateTitle = playbackRateTitle(queuePlaybackRate)
        playbackRateButton.setTitle(selectedRateTitle, for: .normal)
        playbackRateButton.accessibilityValue = selectedRateTitle
        playbackRateButton.menu = UIMenu(
            title: NSLocalizedString("Playback Speed", comment: ""),
            children: Self.supportedPlaybackRates.map { rate in
                UIAction(
                    title: playbackRateTitle(rate),
                    state: rate == queuePlaybackRate ? .on : .off,
                    handler: { [weak self] _ in self?.setPlaybackRate(rate) }
                )
            }
        )
    }

    func playbackRateTitle(_ rate: Float) -> String {
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return "\(formatter.string(from: NSNumber(value: rate)) ?? "\(rate)")×"
    }

    func setPlaybackRate(_ rate: Float) {
        guard Self.supportedPlaybackRates.contains(rate) else { return }
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.setPlaybackRate(rate)
            }
            return
        }

        let wasPlaying = player?.rate != 0
        queuePlaybackRate = rate
        player?.defaultRate = rate
        updatePlaybackRateControl()

        if wasPlaying {
            player?.rate = rate
        } else {
            updateMPNowPlayingInfoForCurrentItem()
        }
    }

    func shouldTrackPlayback(at rate: Float) -> Bool {
        return rate != 0
    }

    func playAtQueueRate() {
        player?.defaultRate = queuePlaybackRate
        player?.play()
    }

    func onTogglePlayPause() {
        guard let rate = player?.rate else { return }

        if rate == 0 {
            playAtQueueRate()
        } else {
            player?.pause()
        }
    }

    func onRewind() {
        guard let currentTime = player?.currentItem?.currentTime().seconds else { return }
        onSeek(to: Float(max(0, currentTime - 15)))
    }

    func onFastForward() {
        guard let currentTime = player?.currentItem?.currentTime().seconds else { return }
        onSeek(to: Float(currentTime + 15))
    }

    func onSeek(to: Float) {
        guard let player, let soughtItem = player.currentItem else { return }

        let seekTime = CMTimeMakeWithSeconds(Float64(max(0, to)), preferredTimescale: 600)
        performSeek(on: player, to: seekTime, completion: { [weak self, weak player, weak soughtItem] finished in
            guard finished, let self, let player else { return }

            DispatchQueue.main.async {
                guard player === self.player,
                      let soughtItem,
                      player.currentItem === soughtItem,
                      let media = self.findMediaItem(by: soughtItem),
                      let currentTime = soughtItem.currentTime().getFiniteSeconds(),
                      let duration = soughtItem.duration.getFiniteSeconds() else {
                    return
                }

                self.updateTimeDisplay(currentTime: currentTime, duration: duration)
                self.saveAudioTime(for: media, currentTime: currentTime, duration: duration)
                self.updateMPNowPlayingInfo(for: media, currentTime: currentTime, duration: duration)
            }
        })
    }

    func registerRemoteMediaControls() {
        UIApplication.shared.beginReceivingRemoteControlEvents()
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.pauseCommand.isEnabled = true
        commandCenter.playCommand.isEnabled = true
        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackRateCommand.isEnabled = true

        commandCenterTargets["pause"] = commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.player?.pause()
            return .success
        }

        commandCenterTargets["play"] = commandCenter.playCommand.addTarget { [weak self] _ in
            self?.playAtQueueRate()
            return .success
        }

        commandCenter.skipBackwardCommand.preferredIntervals = [15]
        commandCenterTargets["skipBackward"] = commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
            self?.onRewind()
            return .success
        }

        commandCenter.skipForwardCommand.preferredIntervals = [15]
        commandCenterTargets["skipForward"] = commandCenter.skipForwardCommand.addTarget { [weak self] _ in
            self?.onFastForward()
            return .success
        }

        commandCenterTargets["changePlaybackPosition"] = commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.onSeek(to: Float(event.positionTime))
            return .success
        }

        commandCenter.changePlaybackRateCommand.supportedPlaybackRates = Self.supportedPlaybackRates.map {
            NSNumber(value: $0)
        }
        commandCenterTargets["changePlaybackRate"] = commandCenter.changePlaybackRateCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackRateCommandEvent,
                  Self.supportedPlaybackRates.contains(event.playbackRate) else {
                return .commandFailed
            }
            self?.setPlaybackRate(event.playbackRate)
            return .success
        }
    }

    func unregisterRemoteMediaControls() {
        UIApplication.shared.endReceivingRemoteControlEvents()
        let commandCenter = MPRemoteCommandCenter.shared()
        if let target = commandCenterTargets["pause"] {
            commandCenter.pauseCommand.removeTarget(target)
        }
        if let target = commandCenterTargets["play"] {
            commandCenter.playCommand.removeTarget(target)
        }
        if let target = commandCenterTargets["skipBackward"] {
            commandCenter.skipBackwardCommand.removeTarget(target)
        }
        if let target = commandCenterTargets["skipForward"] {
            commandCenter.skipForwardCommand.removeTarget(target)
        }
        if let target = commandCenterTargets["changePlaybackPosition"] {
            commandCenter.changePlaybackPositionCommand.removeTarget(target)
        }
        if let target = commandCenterTargets["changePlaybackRate"] {
            commandCenter.changePlaybackRateCommand.removeTarget(target)
        }
        commandCenter.skipBackwardCommand.preferredIntervals = []
        commandCenter.skipForwardCommand.preferredIntervals = []
        commandCenter.pauseCommand.isEnabled = false
        commandCenter.playCommand.isEnabled = false
        commandCenter.skipBackwardCommand.isEnabled = false
        commandCenter.skipForwardCommand.isEnabled = false
        commandCenter.changePlaybackPositionCommand.isEnabled = false
        commandCenter.changePlaybackRateCommand.isEnabled = false
        commandCenterTargets.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func observeNowPlayingReadiness(for playerItem: AVPlayerItem) {
        playerItemStatusObserver?.invalidate()
        playerItemStatusObserver = playerItem.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .readyToPlay else { return }

            DispatchQueue.main.async { [weak self, weak item] in
                guard let item else { return }
                self?.publishNowPlayingInfoIfCurrent(item)
            }
        }
    }

    func publishNowPlayingInfoIfCurrent(_ playerItem: AVPlayerItem) {
        guard player?.currentItem === playerItem else { return }
        updateMPNowPlayingInfoForCurrentItem()
    }

    func updateMPNowPlayingInfo(for item: MediaPlayerItem, currentTime: Double, duration: Double) {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = makeMPNowPlayingInfo(
            for: item,
            currentTime: currentTime,
            duration: duration,
            playbackRate: player?.rate ?? 0
        )
    }

    func updateMPNowPlayingInfoForCurrentItem() {
        guard let player,
              let item = findMediaItem(by: player.currentItem),
              let currentTime = player.currentItem?.currentTime().getFiniteSeconds(),
              let duration = player.currentItem?.duration.getFiniteSeconds() else {
            return
        }

        updateMPNowPlayingInfo(for: item, currentTime: currentTime, duration: duration)
    }

    func makeMPNowPlayingInfo(
        for item: MediaPlayerItem,
        currentTime: Double,
        duration: Double,
        playbackRate: Float
    ) -> [String: Any] {
        return [
            MPMediaItemPropertyTitle: item.name,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: playbackRate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: queuePlaybackRate
        ]
    }
}
