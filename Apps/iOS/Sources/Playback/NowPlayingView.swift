import PutioCore
import SwiftUI

struct PutioAudioPlayerView: View {
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  let model: PutioAudioPlayerModel
  var castButton: AnyView?
  let onDismiss: @MainActor () -> Void
  var showsHarnessReadiness = false

  var body: some View {
    NavigationStack {
      content
        .putioContentBackground()
        .toolbar { toolbar }
    }
    .presentationDragIndicator(horizontalSizeClass == .regular ? .visible : .hidden)
    .presentationSizing(.form)
    .overlay { harnessProbes }
  }

  @ViewBuilder
  private var content: some View {
    switch model.state {
    case .loading:
      PutioLoadingStateView(title: String(localized: "Preparing audio"))
        .accessibilityIdentifier("audio.loading")
    case .failed(_, let failure):
      PutioErrorStateView(
        title: String(localized: "Couldn’t play this audio"),
        message: failure.audioMessage,
        retryTitle: String(localized: "Try again"),
        retryIdentifier: "audio.retry"
      ) {
        Task { await model.retry() }
      }
      .accessibilityIdentifier("audio.error")
    case .playing, .paused, .interrupted, .ended:
      PutioNowPlayingDetails(model: model)
    }
  }

  @ToolbarContentBuilder
  private var toolbar: some ToolbarContent {
    ToolbarItem(placement: .topBarLeading) {
      Button(action: onDismiss) {
        Image(putioIcon: .caretDown)
          .resizable()
          .scaledToFit()
          .frame(width: 18, height: 18)
      }
      .accessibilityLabel(Text("Back"))
      .accessibilityIdentifier("audio.collapse")
    }
    if showsRoutes {
      ToolbarItemGroup(placement: .topBarTrailing) {
        PutioAudioRoutePicker()
          .frame(width: 24, height: 24)
          .accessibilityLabel(Text("Audio output"))
          .accessibilityIdentifier("audio.airplay")
        if let castButton { castButton }
      }
    }
  }

  private var showsRoutes: Bool {
    switch model.state {
    case .playing, .paused, .interrupted, .ended: true
    case .loading, .failed: false
    }
  }

  @ViewBuilder
  private var harnessProbes: some View {
    if showsHarnessReadiness {
      Color.clear
        .frame(width: 1, height: 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Audio player state")
        .accessibilityValue(Text(verbatim: "id=\(model.track.id.rawValue);state=\(stateName)"))
        .accessibilityIdentifier("audio.state")
        .allowsHitTesting(false)
    }
  }

  private var stateName: String {
    switch model.state {
    case .loading: "loading"
    case .playing: "playing"
    case .paused: "paused"
    case .interrupted: "interrupted"
    case .failed: "failed"
    case .ended: "ended"
    }
  }
}

private struct PutioNowPlayingDetails: View {
  let model: PutioAudioPlayerModel
  @ScaledMetric(relativeTo: .body) private var detailsHeight: CGFloat = 330
  @State private var scrubSeconds: Double?

  var body: some View {
    GeometryReader { geometry in
      let width = min(geometry.size.width, PutioNowPlayingMetrics.maxWidth)
      let artwork = max(
        PutioNowPlayingMetrics.minArtwork,
        min(
          width - PutioNowPlayingMetrics.inset * 2,
          geometry.size.height - detailsHeight,
          PutioNowPlayingMetrics.maxArtwork))
      ScrollView {
        VStack(spacing: PutioNowPlayingMetrics.sectionGap) {
          artworkTile(side: artwork)
          heading
          scrubber
          transport
          chips
        }
        .padding(.horizontal, PutioNowPlayingMetrics.inset)
        .padding(.top, PutioTheme.Spacing.space3)
        .padding(.bottom, PutioTheme.Spacing.space4)
        .frame(width: width)
        .frame(maxWidth: .infinity)
      }
      .scrollBounceBehavior(.basedOnSize)
    }
  }

  private func artworkTile(side: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: PutioNowPlayingMetrics.artworkRadius, style: .continuous)
      .fill(PutioTheme.Colors.surface)
      .frame(width: side, height: side)
      .overlay {
        Image(putioIcon: .fileAudio)
          .resizable()
          .scaledToFit()
          .frame(width: side * 0.3, height: side * 0.3)
          .foregroundStyle(PutioTheme.Components.FileRow.icon)
      }
      .accessibilityHidden(true)
  }

  private var heading: some View {
    VStack(alignment: .leading, spacing: PutioTheme.Spacing.space1) {
      Text(model.track.title)
        .putioFont(PutioNowPlayingMetrics.titleFont)
        .foregroundStyle(PutioTheme.Colors.textPrimary)
        .lineLimit(1)
        .truncationMode(.middle)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("audio.title")
      Text(model.neighbours?.folderName ?? " ")
        .putioFont(PutioTheme.Typography.body)
        .foregroundStyle(PutioTheme.Colors.textSecondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .accessibilityHidden(model.neighbours?.folderName == nil)
        .accessibilityIdentifier("audio.folder")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var scrubber: some View {
    let elapsed = scrubSeconds.map { Int($0.rounded(.down)) } ?? model.elapsedSeconds
    return VStack(spacing: PutioTheme.Spacing.space2) {
      Slider(
        value: Binding(
          get: { scrubSeconds ?? Double(model.elapsedSeconds) },
          set: { seconds in
            if scrubSeconds == nil {
              model.seek(to: Int(seconds.rounded(.down)))
            } else {
              scrubSeconds = seconds
            }
          }
        ),
        in: 0...Double(max(model.durationSeconds ?? 0, 1)),
        onEditingChanged: { editing in
          if editing {
            scrubSeconds = Double(model.elapsedSeconds)
          } else if let scrubSeconds {
            model.seek(to: Int(scrubSeconds.rounded(.down)))
            self.scrubSeconds = nil
          }
        }
      )
      .sliderThumbVisibility(.hidden)
      .tint(PutioTheme.Colors.accent)
      .disabled(model.durationSeconds == nil)
      .accessibilityLabel(Text("Playback position"))
      .accessibilityValue(Text(PutioAudioClock.text(elapsed)))
      .accessibilityIdentifier("audio.scrubber")
      HStack {
        Text(PutioAudioClock.text(elapsed))
          .accessibilityIdentifier("audio.elapsed")
        Spacer(minLength: PutioTheme.Spacing.space2)
        Text(
          model.durationSeconds.map { "-" + PutioAudioClock.text(max($0 - elapsed, 0)) }
            ?? "--:--"
        )
        .accessibilityIdentifier("audio.remaining")
      }
      .putioFont(PutioTheme.Typography.numeric)
      .foregroundStyle(PutioTheme.Colors.textSecondary)
    }
  }

  private var transport: some View {
    HStack(spacing: 0) {
      skipButton(by: -PutioAudioPlayerModel.skipInterval)
      Spacer(minLength: PutioTheme.Spacing.space2)
      trackButton(
        .skipBackFill, label: String(localized: "Previous file"), identifier: "audio.previous",
        enabled: model.canSkipToPrevious
      ) { model.skipToPrevious() }
      Spacer(minLength: PutioTheme.Spacing.space2)
      Button {
        model.togglePlayPause()
      } label: {
        Image(putioIcon: model.isPlaying ? .pauseFill : .playFill)
          .resizable()
          .scaledToFit()
          .frame(width: 30, height: 30)
          .frame(width: PutioNowPlayingMetrics.playPause, height: PutioNowPlayingMetrics.playPause)
          .foregroundStyle(PutioTheme.Colors.background)
      }
      .buttonStyle(.borderedProminent)
      .buttonBorderShape(.circle)
      .tint(PutioTheme.Colors.textPrimary)
      .accessibilityLabel(
        Text(model.isPlaying ? String(localized: "Pause") : String(localized: "Play"))
      )
      .accessibilityIdentifier("audio.play-pause")
      Spacer(minLength: PutioTheme.Spacing.space2)
      trackButton(
        .skipForwardFill, label: String(localized: "Next file"), identifier: "audio.next",
        enabled: model.canSkipToNext
      ) { model.skipToNext() }
      Spacer(minLength: PutioTheme.Spacing.space2)
      skipButton(by: PutioAudioPlayerModel.skipInterval)
    }
  }

  private func trackButton(
    _ icon: PutioIcon, label: String, identifier: String, enabled: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(putioIcon: icon)
        .resizable()
        .scaledToFit()
        .frame(width: 24, height: 24)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .tint(PutioTheme.Colors.textPrimary)
    .disabled(!enabled)
    .accessibilityLabel(Text(label))
    .accessibilityIdentifier(identifier)
  }

  private func skipButton(by seconds: Int) -> some View {
    let step = abs(seconds)
    let forward = seconds > 0
    return Button {
      model.skip(by: seconds)
    } label: {
      Image(systemName: forward ? "goforward.\(step)" : "gobackward.\(step)")
        .font(.system(size: 24))
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .tint(PutioTheme.Colors.textPrimary)
    .disabled(model.durationSeconds == nil)
    .accessibilityLabel(
      Text(
        forward
          ? String(localized: "Forward \(step) seconds") : String(localized: "Back \(step) seconds")
      )
    )
    .accessibilityIdentifier(forward ? "audio.skip-forward" : "audio.skip-back")
  }

  private var chips: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: PutioTheme.Spacing.space2) { chipRow }
      VStack(spacing: PutioTheme.Spacing.space2) { chipRow }
    }
  }

  @ViewBuilder
  private var chipRow: some View {
    Menu {
      ForEach(PutioAudioSpeed.allCases, id: \.self) { speed in
        Button {
          model.setSpeed(speed)
        } label: {
          if speed == model.speed {
            Label(speed.title, systemImage: "checkmark")
          } else {
            Text(speed.title)
          }
        }
        .accessibilityIdentifier("audio.speed.\(speed.identifier)")
      }
    } label: {
      PutioNowPlayingChipLabel(icon: .gauge, title: model.speed.title)
    }
    .putioNowPlayingChip()
    .accessibilityLabel(Text("Playback speed"))
    .accessibilityValue(Text(model.speed.title))
    .accessibilityIdentifier("audio.speed")
    Button {
    } label: {
      PutioNowPlayingChipLabel(icon: .moon, title: String(localized: "Sleep timer"))
    }
    .putioNowPlayingChip()
    .disabled(true)
    .accessibilityIdentifier("audio.sleep-timer")
    Button {
    } label: {
      PutioNowPlayingChipLabel(icon: .list, title: String(localized: "Up next"))
    }
    .putioNowPlayingChip()
    .disabled(true)
    .accessibilityIdentifier("audio.up-next")
  }
}

private struct PutioNowPlayingChipLabel: View {
  let icon: PutioIcon
  let title: String

  var body: some View {
    HStack(spacing: PutioTheme.Spacing.space2) {
      PutioIconView(icon, size: PutioNowPlayingMetrics.chipIcon)
        .accessibilityHidden(true)
      Text(title)
        .lineLimit(1)
    }
    .putioFont(PutioTheme.Components.Button.label)
  }
}

extension View {
  fileprivate func putioNowPlayingChip() -> some View {
    buttonStyle(.bordered)
      .buttonBorderShape(.capsule)
      .tint(PutioTheme.Colors.textPrimary)
  }
}

private enum PutioNowPlayingMetrics {
  static let inset: CGFloat = 28
  static let sectionGap: CGFloat = 24
  static let maxWidth: CGFloat = 540
  static let minArtwork: CGFloat = 120
  static let maxArtwork: CGFloat = 346
  static let artworkRadius: CGFloat = 28
  static let playPause: CGFloat = 60
  static let chipIcon = PutioMetricRole(value: PutioTheme.Typography.sizeBase, relativeTo: .body)
  static let titleFont = PutioFontRole(
    fontName: PutioTheme.Typography.heading.fontName,
    size: PutioTheme.Typography.sizeMd,
    lineHeight: 1.25,
    textStyle: .title3
  )
}

enum PutioAudioClock {
  static func text(_ seconds: Int) -> String {
    let hours = seconds / 3600
    let minutes = seconds % 3600 / 60
    let remainder = seconds % 60
    return hours > 0
      ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
      : String(format: "%d:%02d", minutes, remainder)
  }
}
