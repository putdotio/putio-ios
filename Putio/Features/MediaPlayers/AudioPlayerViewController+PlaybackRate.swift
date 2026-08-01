import AVFoundation
import MediaPlayer
import UIKit

extension AudioPlayerViewController {
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

        let wasPlaying = player?.rate != 0
        queuePlaybackRate = rate
        player?.defaultRate = rate
        if wasPlaying {
            player?.rate = rate
        }

        updatePlaybackRateControl()
        updateMPNowPlayingInfoForCurrentItem()
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
        guard let player else { return }

        let seekTime = CMTimeMakeWithSeconds(Float64(max(0, to)), preferredTimescale: 600)
        player.seek(to: seekTime, completionHandler: { [weak self, weak player] finished in
            guard finished, let self, let player else { return }

            DispatchQueue.main.async {
                guard player === self.player,
                      let playerItem = player.currentItem,
                      let media = self.findMediaItem(by: playerItem),
                      let currentTime = playerItem.currentTime().getFiniteSeconds(),
                      let duration = playerItem.duration.getFiniteSeconds() else {
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

        commandCenter.changePlaybackRateCommand.isEnabled = true
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

    func unRegisterRemoteMediaControls() {
        UIApplication.shared.endReceivingRemoteControlEvents()
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.pauseCommand.removeTarget(commandCenterTargets["pause"])
        commandCenter.playCommand.removeTarget(commandCenterTargets["play"])
        commandCenter.skipBackwardCommand.removeTarget(commandCenterTargets["skipBackward"])
        commandCenter.skipForwardCommand.removeTarget(commandCenterTargets["skipForward"])
        commandCenter.changePlaybackPositionCommand.removeTarget(commandCenterTargets["changePlaybackPosition"])
        commandCenter.changePlaybackRateCommand.removeTarget(commandCenterTargets["changePlaybackRate"])
        commandCenter.skipBackwardCommand.preferredIntervals = []
        commandCenter.skipForwardCommand.preferredIntervals = []
        commandCenter.changePlaybackRateCommand.isEnabled = false
        commandCenterTargets.removeAll()
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
            MPMediaItemPropertyAssetURL: item.url,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: playbackRate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: queuePlaybackRate
        ]
    }
}
