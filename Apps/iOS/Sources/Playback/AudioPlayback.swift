import AVKit
import MediaPlayer
import PutioCore
import SwiftUI

@MainActor
final class PutioSystemNowPlayingSurface: PutioNowPlayingSurface {
  private var handler: (@MainActor (PutioRemoteAudioCommand) -> Void)?
  private var targets: [(MPRemoteCommand, Any)] = []

  func publish(_ info: PutioNowPlayingInfo) {
    var nowPlaying: [String: Any] = [
      MPMediaItemPropertyTitle: info.title,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(info.elapsedSeconds),
      MPNowPlayingInfoPropertyPlaybackRate: Double(info.rate),
    ]
    if let duration = info.durationSeconds {
      nowPlaying[MPMediaItemPropertyPlaybackDuration] = Double(duration)
    }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlaying
  }

  func clear() {
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
  }

  func detachCommands() {
    handler = nil
    for (command, target) in targets {
      command.removeTarget(target)
      command.isEnabled = false
    }
    targets = []
  }

  func setCommandHandler(_ handler: @escaping @MainActor (PutioRemoteAudioCommand) -> Void) {
    self.handler = handler
    let center = MPRemoteCommandCenter.shared()
    register(center.playCommand) { _ in .play }
    register(center.pauseCommand) { _ in .pause }
    register(center.togglePlayPauseCommand) { _ in .toggle }
    register(center.nextTrackCommand) { _ in .next }
    register(center.previousTrackCommand) { _ in .previous }
    let interval = PutioAudioPlayerModel.skipInterval
    center.skipBackwardCommand.preferredIntervals = [NSNumber(value: interval)]
    center.skipForwardCommand.preferredIntervals = [NSNumber(value: interval)]
    register(center.skipBackwardCommand) { _ in .skip(seconds: -interval) }
    register(center.skipForwardCommand) { _ in .skip(seconds: interval) }
    register(center.changePlaybackPositionCommand) { event in
      guard let event = event as? MPChangePlaybackPositionCommandEvent else { return nil }
      return .seek(seconds: Int(event.positionTime.rounded(.down)))
    }
    setTrackCommands(previous: false, next: false)
  }

  func setTrackCommands(previous: Bool, next: Bool) {
    guard handler != nil else { return }
    let center = MPRemoteCommandCenter.shared()
    center.previousTrackCommand.isEnabled = previous
    center.nextTrackCommand.isEnabled = next
  }

  private func register(
    _ command: MPRemoteCommand,
    map: @escaping @Sendable (MPRemoteCommandEvent) -> PutioRemoteAudioCommand?
  ) {
    // Command events arrive on the media framework's queue; the model is
    // main-actor bound, so the hop is explicit.
    let target = command.addTarget { [weak self] event in
      guard let mapped = map(event) else { return .commandFailed }
      Task { @MainActor [weak self] in self?.handler?(mapped) }
      return .success
    }
    command.isEnabled = true
    targets.append((command, target))
  }
}

@MainActor
final class PutioSystemAudioSession: PutioAudioSessioning {
  func activate() throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playback, mode: .default)
    try session.setActive(true)
  }

  func deactivate() {
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }
}

struct PutioAudioRoutePicker: UIViewRepresentable {
  func makeUIView(context: Context) -> AVRoutePickerView {
    let picker = AVRoutePickerView()
    picker.tintColor = UIColor(PutioTheme.Colors.textPrimary)
    picker.activeTintColor = UIColor(PutioTheme.Colors.accent)
    return picker
  }

  func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
