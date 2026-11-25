import PutioCore
import SwiftUI

@MainActor
enum TVAudioPlayback {
  static func makeModel(
    route: PutioAudioRoute, runtime: PutioRuntime, pipeline: PutioPlaybackPositionPipeline
  ) -> PutioAudioPlayerModel {
    PutioAudioPlayerModel(
      track: PutioAudioTrack(id: route.id, parentID: route.parentID, title: route.title),
      engine: PutioSystemAudioEngine(),
      nowPlaying: PutioSystemNowPlayingSurface(),
      audioSession: PutioSystemAudioSession(),
      sessionEvents: PutioSystemAudioSessionEvents(),
      speedStore: PutioAudioSpeedStore(),
      positionPipeline: pipeline,
      remembersPlaybackPosition: {
        guard case .signedIn(let account) = runtime.session.state else { return false }
        return account.rememberVideoTime
      },
      reportPosition: { fileID, seconds in
        try await runtime.reportPlaybackPosition(fileID: fileID, seconds: seconds)
      },
      resolve: { fileID in try await resolve(fileID, runtime: runtime) },
      loadNeighbours: { track in
        try await runtime.audioNeighbours(of: track.id, in: track.parentID)
      }
    )
  }

  private static func resolve(_ fileID: PutioFileID, runtime: PutioRuntime) async throws
    -> PutioPlaybackSource
  {
    let source = try await runtime.resolveAudioPlaybackSource(fileID: fileID)
    #if DEBUG
      if let media = TVHarnessMedia.current {
        return PutioPlaybackSource(
          url: media.baseURL.appending(path: "runtime-proof-audio.m4a"),
          startFromSeconds: source.startFromSeconds)
      }
    #endif
    return source
  }
}

/// Plays audio full screen; Menu leaves it and the mini player keeps it going.
struct TVNowPlayingView: View {
  let playback: PutioAudioPlaybackSession
  let model: PutioAudioPlayerModel
  let onClose: () -> Void

  var body: some View {
    content
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(PutioTheme.Colors.background.ignoresSafeArea())
      .onPlayPauseCommand { model.togglePlayPause() }
      .onExitCommand(perform: onClose)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("audio.screen")
  }

  @ViewBuilder
  private var content: some View {
    switch model.state {
    case .loading where model.durationSeconds == nil && model.elapsedSeconds == 0:
      PutioLoadingStateView(title: String(localized: "Preparing audio", bundle: .putioCore))
        .accessibilityIdentifier("audio.loading")
    case .failed(_, let failure):
      PutioErrorStateView(
        title: String(localized: "Couldn’t play this audio", bundle: .putioCore),
        message: failure.audioMessage,
        retryTitle: String(localized: "Try again", bundle: .putioCore),
        retryIdentifier: "audio.retry"
      ) {
        Task { await model.retry() }
      }
      .secondaryAction(
        String(localized: "Back", bundle: .putioCore), identifier: "audio.back", perform: onClose)
    default:
      TVNowPlayingDetails(model: model, sleepTimer: playback.sleepTimer)
    }
  }
}

private struct TVNowPlayingDetails: View {
  let model: PutioAudioPlayerModel
  let sleepTimer: PutioAudioSleepTimer

  var body: some View {
    HStack(spacing: TVNowPlayingLayout.gap) {
      artwork
      VStack(alignment: .leading, spacing: 0) {
        status
        Text(model.track.title)
          .putioFont(PutioTheme.TV.Typography.label)
          .foregroundStyle(PutioTheme.TV.Colors.textPrimary)
          .lineLimit(1)
          .truncationMode(.tail)
          .padding(.top, PutioTheme.TV.Spacing.xs)
          .accessibilityIdentifier("audio.title")
        if let folder = model.neighbours?.folderName {
          Text(folder)
            .putioFont(PutioTheme.TV.Typography.caption)
            .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
            .lineLimit(1)
            .accessibilityIdentifier("audio.folder")
        }
        TVNowPlayingScrubber(
          elapsed: model.elapsedSeconds, duration: model.durationSeconds
        )
        .padding(.top, TVNowPlayingLayout.scrubberGap)
        HStack(spacing: PutioTheme.TV.Spacing.small) {
          speedMenu
          TVSleepTimerMenu(timer: sleepTimer)
          upNextMenu
        }
        .padding(.top, TVNowPlayingLayout.buttonsGap)
        .focusSection()
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, TVNowPlayingLayout.inset)
  }

  private var artwork: some View {
    RoundedRectangle(cornerRadius: TVNowPlayingLayout.artworkRadius)
      .fill(PutioTheme.Colors.surfaceActive)
      .frame(width: TVNowPlayingLayout.artwork, height: TVNowPlayingLayout.artwork)
      .overlay {
        Image(putioIcon: .fileAudioFill)
          .resizable()
          .scaledToFit()
          .frame(width: TVNowPlayingLayout.artworkGlyph, height: TVNowPlayingLayout.artworkGlyph)
          .foregroundStyle(PutioTheme.Colors.accent)
      }
      .shadow(color: .black.opacity(0.5), radius: 40, y: 30)
      .accessibilityHidden(true)
  }

  private var status: some View {
    let playing = model.isPlaying || model.state == .loading(model.track)
    return HStack(spacing: PutioTheme.TV.Spacing.xs) {
      Image(putioIcon: playing ? .speakerHigh : .pauseFill)
        .resizable()
        .scaledToFit()
        .frame(width: TVNowPlayingLayout.statusGlyph, height: TVNowPlayingLayout.statusGlyph)
      Text(
        playing
          ? String(localized: "Now playing", bundle: .putioCore)
          : String(localized: "Paused", bundle: .putioCore))
    }
    .putioFont(PutioTheme.TV.Typography.caption)
    .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("audio.state")
    .accessibilityValue(Text(verbatim: playing ? "playing" : "paused"))
  }

  private var speedMenu: some View {
    Menu {
      Section(String(localized: "Speed", bundle: .putioCore)) {
        ForEach(PutioAudioSpeed.tvMenu, id: \.self) { speed in
          TVCheckedMenuRow(title: speed.title, checked: speed == model.speed) {
            model.setSpeed(speed)
          }
          .accessibilityIdentifier("audio.speed.\(speed.identifier)")
        }
      }
    } label: {
      TVNowPlayingButtonLabel(icon: .gauge, title: model.speed.title, numeric: true)
    }
    .tvNowPlayingButton()
    .accessibilityLabel(String(localized: "Playback speed", bundle: .putioCore))
    .accessibilityValue(model.speed.title)
    .accessibilityIdentifier("audio.speed")
  }

  private var upNextMenu: some View {
    Menu {
      Section(String(localized: "Up next", bundle: .putioCore)) {
        ForEach(model.queue) { item in
          TVCheckedMenuRow(title: item.name, checked: item.id == model.track.id) {
            model.play(item)
          }
          .accessibilityIdentifier("audio.up-next.\(item.id.rawValue)")
        }
      }
    } label: {
      TVNowPlayingButtonLabel(icon: .list, title: String(localized: "Up next", bundle: .putioCore))
    }
    .tvNowPlayingButton()
    .disabled(model.queue.count < 2)
    .accessibilityIdentifier("audio.up-next")
  }
}

private struct TVNowPlayingScrubber: View {
  let elapsed: Int
  let duration: Int?

  var body: some View {
    VStack(spacing: PutioTheme.TV.Spacing.xs) {
      GeometryReader { geometry in
        ZStack(alignment: .leading) {
          Capsule().fill(Color.white.opacity(0.2))
          Capsule()
            .fill(Color.white.opacity(0.92))
            .frame(width: geometry.size.width * fraction)
        }
      }
      .frame(height: TVNowPlayingLayout.scrubberHeight)
      HStack {
        Text(verbatim: PutioAudioClock.text(elapsed))
          .accessibilityIdentifier("audio.elapsed")
        Spacer()
        if let duration {
          Text(verbatim: "-" + PutioAudioClock.text(max(duration - elapsed, 0)))
            .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
            .accessibilityIdentifier("audio.remaining")
        }
      }
      .putioFont(PutioTheme.TV.Typography.numeric)
      .foregroundStyle(PutioTheme.TV.Colors.textPrimary)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(String(localized: "Playback position", bundle: .putioCore))
    .accessibilityValue(PutioAudioClock.text(elapsed))
    .accessibilityIdentifier("audio.scrubber")
  }

  private var fraction: CGFloat {
    guard let duration, duration > 0 else { return 0 }
    return min(max(CGFloat(elapsed) / CGFloat(duration), 0), 1)
  }
}

struct TVSleepTimerMenu: View {
  let timer: PutioAudioSleepTimer

  var body: some View {
    let left = timer.remainingSeconds.map(PutioAudioClock.text)
    Menu {
      Section(String(localized: "Sleep timer", bundle: .putioCore)) {
        TVCheckedMenuRow(
          title: String(localized: "Off", bundle: .putioCore), checked: !timer.isRunning
        ) {
          timer.cancel()
        }
        .accessibilityIdentifier("audio.sleep.off")
        ForEach(PutioSleepTimerChoice.allCases) { choice in
          TVCheckedMenuRow(title: choice.tvTitle, checked: timer.choice == choice) {
            timer.start(choice)
          }
          .accessibilityIdentifier("audio.sleep.\(choice.rawValue)")
        }
      }
    } label: {
      TVNowPlayingButtonLabel(
        icon: left == nil ? .moon : .moonFill,
        title: left.map { String(localized: "Sleep in \($0)", bundle: .putioCore) }
          ?? String(localized: "Sleep timer", bundle: .putioCore))
    }
    .tvNowPlayingButton()
    .accessibilityLabel(
      left.map { String(localized: "Sleep timer, \($0) left", bundle: .putioCore) }
        ?? String(localized: "Sleep timer", bundle: .putioCore)
    )
    .accessibilityIdentifier("audio.sleep-timer")
  }
}

extension PutioSleepTimerChoice {
  fileprivate var tvTitle: String {
    rawValue.isMultiple(of: 60)
      ? String(localized: "In \(rawValue / 60) hours", bundle: .putioCore)
      : String(localized: "In \(rawValue) minutes", bundle: .putioCore)
  }
}

private struct TVCheckedMenuRow: View {
  let title: String
  let checked: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      if checked {
        Label(title, systemImage: "checkmark")
      } else {
        Text(title)
      }
    }
  }
}

private struct TVNowPlayingButtonLabel: View {
  let icon: PutioIcon
  let title: String
  var numeric = false

  var body: some View {
    HStack(spacing: PutioTheme.TV.Spacing.xs) {
      Image(putioIcon: icon)
        .resizable()
        .scaledToFit()
        .frame(width: TVNowPlayingLayout.buttonGlyph, height: TVNowPlayingLayout.buttonGlyph)
        .accessibilityHidden(true)
      if numeric {
        Text(verbatim: title).monospacedDigit()
      } else {
        Text(title)
      }
    }
    .putioFont(PutioButtonSize.regular.brandLabel)
    .lineLimit(1)
  }
}

extension View {
  fileprivate func tvNowPlayingButton() -> some View {
    menuStyle(.button)
      .buttonStyle(.bordered)
      .buttonBorderShape(.capsule)
      .fixedSize()
  }
}

enum TVNowPlayingLayout {
  static let inset: CGFloat = 120
  static let gap: CGFloat = 96
  static let artwork: CGFloat = 560
  static let artworkRadius: CGFloat = 40
  static let artworkGlyph: CGFloat = 200
  static let statusGlyph: CGFloat = 26
  static let scrubberGap: CGFloat = 56
  static let scrubberHeight: CGFloat = 10
  static let buttonsGap: CGFloat = 48
  static let buttonGlyph: CGFloat = 32
}
