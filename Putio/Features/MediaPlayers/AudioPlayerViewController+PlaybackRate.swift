import AVFoundation
import MediaPlayer
import UIKit

extension AudioPlayerViewController {
    func configurePlaybackRateControl() {
        if playbackRateButton.superview == nil, let playbackInfoStackView {
            playbackInfoStackView.insertArrangedSubview(playbackRateButton, at: 1)
            NSLayoutConstraint.activate([
                playbackRateButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 48),
                playbackRateButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 48)
            ])
        }
        updatePlaybackRateControl()
    }

    func updatePlaybackRateControl() {
        let selectedTitle = playbackRateTitle(queuePlaybackRate)
        playbackRateButton.setTitle(selectedTitle, for: .normal)
        playbackRateButton.accessibilityValue = selectedTitle
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
        refreshNowPlayingInfo()
    }

    func playAtQueueRate() {
        player?.defaultRate = queuePlaybackRate
        player?.play()
        refreshNowPlayingInfo()
    }

    func onTogglePlayPause() {
        if player?.rate == 0 {
            playAtQueueRate()
        } else {
            player?.pause()
            refreshNowPlayingInfo()
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

    func onSeek(to time: Float) {
        guard let player else { return }
        player.seek(
            to: CMTime(seconds: Double(max(0, time)), preferredTimescale: 600),
            completionHandler: { [weak self, weak player] finished in
                guard finished else { return }
                DispatchQueue.main.async {
                    guard let self, let player, self.player === player else { return }
                    self.refreshAfterSeek()
                }
            }
        )
    }

    func refreshAfterSeek() {
        guard let player,
              let item = findMediaItem(by: player.currentItem),
              let currentTime = player.currentItem?.currentTime().getFiniteSeconds(),
              let duration = player.currentItem?.duration.getFiniteSeconds() else {
            refreshNowPlayingInfo()
            return
        }

        updateTimeDisplay(currentTime: currentTime, duration: duration)
        updateMPNowPlayingInfo(for: item, currentTime: currentTime, duration: duration)
        if !timeSlider.isTracking {
            saveAudioTime(for: item, currentTime: currentTime, duration: duration)
        }
    }

    func registerRemoteMediaControls() {
        UIApplication.shared.beginReceivingRemoteControlEvents()
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.pauseCommand.isEnabled = true
        commandCenter.playCommand.isEnabled = true
        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.isEnabled = true

        commandCenterTargets["pause"] = commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.player?.pause()
            self?.refreshNowPlayingInfo()
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
        commandCenterTargets["previousTrack"] = commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            self?.onRewind()
            return .success
        }
        commandCenterTargets["nextTrack"] = commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            self?.onFastForward()
            return .success
        }

        commandCenterTargets["changePlaybackPosition"] = commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.onSeek(to: Float(event.positionTime))
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
        if let target = commandCenterTargets["previousTrack"] {
            commandCenter.previousTrackCommand.removeTarget(target)
        }
        if let target = commandCenterTargets["nextTrack"] {
            commandCenter.nextTrackCommand.removeTarget(target)
        }
        if let target = commandCenterTargets["changePlaybackPosition"] {
            commandCenter.changePlaybackPositionCommand.removeTarget(target)
        }

        commandCenter.pauseCommand.isEnabled = false
        commandCenter.playCommand.isEnabled = false
        commandCenter.skipBackwardCommand.isEnabled = false
        commandCenter.skipForwardCommand.isEnabled = false
        commandCenter.previousTrackCommand.isEnabled = false
        commandCenter.nextTrackCommand.isEnabled = false
        commandCenter.changePlaybackPositionCommand.isEnabled = false
        commandCenter.skipBackwardCommand.preferredIntervals = []
        commandCenter.skipForwardCommand.preferredIntervals = []
        commandCenterTargets.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func refreshNowPlayingInfo(for item: MediaPlayerItem? = nil) {
        guard let item = item ?? findMediaItem(by: player?.currentItem) else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        updateMPNowPlayingInfo(
            for: item,
            currentTime: player?.currentItem?.currentTime().getFiniteSeconds(),
            duration: player?.currentItem?.duration.getFiniteSeconds()
        )
    }

    func updateMPNowPlayingInfo(for item: MediaPlayerItem, currentTime: Double? = nil, duration: Double? = nil) {
        var nowPlayingInfo: [String: Any] = [
            MPMediaItemPropertyTitle: item.name,
            MPNowPlayingInfoPropertyPlaybackRate: player?.rate ?? 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: queuePlaybackRate
        ]
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }
}
