import Observation
import PutioCore
import SwiftUI

/// Playback belongs to the signed-in tab shell, not its dismissible sheet.
@MainActor
@Observable
final class PutioAudioPlaybackSession {
  private(set) var model: PutioAudioPlayerModel?
  var isPresented = false
  let sleepTimer: PutioAudioSleepTimer
  @ObservationIgnored private var startTask: Task<Void, Never>?

  init(sleepTimer: PutioAudioSleepTimer) {
    self.sleepTimer = sleepTimer
    sleepTimer.onExpire = { [weak self] in self?.model?.sleepTimerExpired() }
  }

  func present(_ model: PutioAudioPlayerModel) {
    retire()
    self.model = model
    isPresented = true
    startTask = Task { await model.start() }
  }

  func stop() {
    sleepTimer.cancel()
    retire()
  }

  func retire() {
    startTask?.cancel()
    startTask = nil
    model?.stop()
    model = nil
    isPresented = false
  }
}

@MainActor
@Observable
final class PutioAudioMiniPlayerPlacement {
  var tabBarOnTop = false
}

struct PutioAudioMiniPlayerSlot {
  let playback: PutioAudioPlaybackSession
  let placement: PutioAudioMiniPlayerPlacement
  let onStop: () -> Void
}

struct PutioAudioMiniPlayer: View {
  let model: PutioAudioPlayerModel
  let onOpen: () -> Void
  let onStop: () -> Void
  @Environment(\.tabViewBottomAccessoryPlacement) private var placement

  var body: some View {
    HStack(spacing: PutioTheme.Spacing.space1) {
      Button(action: onOpen) {
        HStack(spacing: PutioTheme.Spacing.space3) {
          if placement != .inline {
            PutioIconView(.fileAudio, size: Self.iconSize)
              .foregroundStyle(PutioTheme.Components.FileRow.icon)
              .accessibilityHidden(true)
          }
          VStack(alignment: .leading, spacing: 0) {
            Text(model.track.title)
              .putioFont(PutioTheme.Typography.body)
              .foregroundStyle(PutioTheme.Colors.textPrimary)
              .lineLimit(1)
              .truncationMode(.middle)
              .accessibilityIdentifier("audio.mini.title")
            if placement != .inline {
              Text(status)
                .putioFont(PutioTheme.Typography.numeric)
                .foregroundStyle(PutioTheme.Colors.textSecondary)
                .lineLimit(1)
                .accessibilityIdentifier("audio.mini.position")
            }
          }
          Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
      }
      .accessibilityLabel(Text(String(localized: "Open player")))
      .accessibilityValue(Text(verbatim: "\(model.track.title), \(status)"))
      .accessibilityIdentifier("audio.mini.open")
      transport
      Button(action: onStop) {
        icon(.x, size: Self.stopGlyph)
      }
      .accessibilityLabel(Text(String(localized: "Stop playback")))
      .accessibilityIdentifier("audio.mini.stop")
    }
    .buttonStyle(.plain)
    .padding(.leading, PutioTheme.Spacing.space3)
    .padding(.trailing, PutioTheme.Spacing.space1)
    .overlay(alignment: .bottom) { progress }
  }

  @ViewBuilder
  private var transport: some View {
    switch model.state {
    case .loading:
      ProgressView()
        .frame(width: 44, height: 44)
        .accessibilityLabel(Text(String(localized: "Preparing audio")))
    case .failed:
      EmptyView()
    case .playing, .paused, .interrupted, .ended:
      Button {
        model.togglePlayPause()
      } label: {
        icon(model.isPlaying ? .pauseFill : .playFill, size: Self.playGlyph)
      }
      .accessibilityLabel(
        Text(model.isPlaying ? String(localized: "Pause") : String(localized: "Play"))
      )
      .accessibilityIdentifier("audio.mini.toggle")
    }
  }

  private func icon(_ icon: PutioIcon, size: CGFloat) -> some View {
    Image(putioIcon: icon)
      .resizable()
      .scaledToFit()
      .frame(width: size, height: size)
      .frame(width: 44, height: 44)
      .foregroundStyle(PutioTheme.Colors.textPrimary)
      .contentShape(Rectangle())
  }

  private var progress: some View {
    let fraction = model.durationSeconds.map { duration in
      duration > 0 ? min(max(Double(model.elapsedSeconds) / Double(duration), 0), 1) : 0
    }
    return GeometryReader { geometry in
      Rectangle()
        .fill(PutioTheme.Colors.accent)
        .frame(width: geometry.size.width * (fraction ?? 0))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PutioTheme.Colors.separator)
    }
    .frame(height: Self.progressHeight)
    .padding(.horizontal, Self.progressInset)
    .accessibilityHidden(true)
  }

  private var status: String {
    switch model.state {
    case .loading: return String(localized: "Preparing audio")
    case .failed: return String(localized: "Couldn’t play this audio")
    case .playing, .paused, .interrupted, .ended:
      let elapsed = PutioAudioClock.text(model.elapsedSeconds)
      guard let duration = model.durationSeconds else { return elapsed }
      let total = PutioAudioClock.text(duration)
      return String(localized: "\(elapsed) of \(total)")
    }
  }

  private static let playGlyph: CGFloat = 22
  private static let stopGlyph: CGFloat = 18
  private static let progressHeight: CGFloat = 2
  private static let progressInset: CGFloat = 22
  private static let iconSize = PutioMetricRole(
    value: PutioTheme.Typography.sizeLg, relativeTo: .body)
}

struct PutioAudioMiniPlayerInset: ViewModifier {
  let slot: PutioAudioMiniPlayerSlot
  @Environment(\.tabBarPlacement) private var tabBarPlacement

  private var tabBarOnTop: Bool { tabBarPlacement == .topBar || tabBarPlacement == .sidebar }

  func body(content: Content) -> some View {
    content
      .safeAreaInset(edge: .bottom, alignment: .leading, spacing: 0) {
        if tabBarOnTop, let model = slot.playback.model {
          PutioAudioMiniPlayer(
            model: model, onOpen: { slot.playback.isPresented = true }, onStop: slot.onStop
          )
          .frame(maxWidth: Self.width, minHeight: Self.height)
          .clipShape(Capsule())
          .modifier(PutioCapsuleGlass())
          .padding(.horizontal, PutioTheme.Spacing.space3)
          .padding(.bottom, PutioTheme.Spacing.space2)
        }
      }
      .scrollEdgeEffectStyle(
        slot.playback.model != nil && !tabBarOnTop ? .hard : nil, for: .bottom
      )
      .onChange(of: tabBarOnTop, initial: true) { _, onTop in
        slot.placement.tabBarOnTop = onTop
      }
  }

  static let width: CGFloat = 386
  static let height: CGFloat = 54
}
