import PutioCore
import SwiftUI

struct PutioVideoCastingView: View {
  let model: PutioCastModel
  let title: String
  let onClose: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      PutioVideoTopBar(title: title, onClose: onClose) {
        PutioCastButton(model: model)
      }
      GeometryReader { proxy in
        ScrollView {
          VStack(spacing: 0) {
            if let phase = model.phase {
              PutioVideoCastingStatus(
                phase: phase, deviceName: deviceName, onRetry: model.retry,
                onStop: model.stopCasting
              )
              .padding(.top, PutioTheme.Spacing.space3)
            }
            Spacer(minLength: PutioTheme.Spacing.space2)
              .putioToast(toast)
            if model.phase == .playing {
              TimelineView(.periodic(from: .now, by: 1)) { _ in
                transport
              }
            }
          }
          .frame(minHeight: proxy.size.height)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.hidden)
      }
    }
    .padding(PutioTheme.Spacing.space3)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.black)
  }

  private var toast: Binding<PutioToast?> {
    Binding(get: { model.toast }, set: { model.toast = $0 })
  }

  private var deviceName: String {
    model.connection.deviceName ?? String(localized: "Chromecast")
  }

  private var transport: some View {
    let timeline = PutioVideoTimeline(
      elapsedSeconds: model.positionSeconds, durationSeconds: model.durationSeconds)
    return VStack(spacing: 0) {
      HStack(spacing: PutioTheme.Spacing.space4 + PutioTheme.Spacing.space2) {
        PutioVideoSkipButton(seconds: -PutioVideoTimeline.skipInterval, circled: false) {
          model.skip(by: -PutioVideoTimeline.skipInterval)
        }
        Button {
          model.togglePlayback()
        } label: {
          PutioVideoCircleLabel(diameter: PutioVideoMetrics.playPause(false), circled: false) {
            Image(putioIcon: model.isPlaying ? .pauseFill : .playFill)
              .resizable()
              .scaledToFit()
              .frame(width: 30, height: 30)
          }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
          model.isPlaying ? String(localized: "Pause") : String(localized: "Play")
        )
        .accessibilityIdentifier("cast.toggle")
        PutioVideoSkipButton(seconds: PutioVideoTimeline.skipInterval, circled: false) {
          model.skip(by: PutioVideoTimeline.skipInterval)
        }
      }
      .padding(.bottom, PutioTheme.Spacing.space3)
      ViewThatFits(in: .horizontal) {
        chips(iconOnly: false)
        chips(iconOnly: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.bottom, PutioVideoMetrics.chipGap)
      PutioVideoScrubber(timeline: timeline, isEnabled: true) { model.seek(toSeconds: $0) }
    }
  }

  private func chips(iconOnly: Bool) -> some View {
    HStack(spacing: PutioTheme.Spacing.space2) {
      PutioVideoTrackChips(
        tracks: model.chipTracks, iconOnly: iconOnly, onChange: {}, onPresentation: { _, _ in })
    }
  }
}

private struct PutioVideoCastingStatus: View {
  let phase: PutioCastPhase
  let deviceName: String
  let onRetry: () -> Void
  let onStop: () -> Void

  var body: some View {
    VStack(spacing: PutioTheme.Spacing.space3) {
      glyph
        .frame(width: PutioVideoMetrics.airPlayIcon, height: PutioVideoMetrics.airPlayIcon)
        .accessibilityHidden(true)
      Text(line)
        .putioFont(PutioVideoMetrics.titleFont)
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier(identifier)
      ViewThatFits(in: .horizontal) {
        HStack(spacing: PutioTheme.Spacing.space2) { actions }
        VStack(spacing: PutioTheme.Spacing.space2) { actions }
      }
    }
    .frame(maxWidth: .infinity)
  }

  @ViewBuilder private var glyph: some View {
    switch phase {
    case .loading:
      ProgressView()
        .controlSize(.large)
        .tint(PutioTheme.Colors.textSecondary)
    case .playing:
      castIcon.foregroundStyle(PutioTheme.Colors.accent)
    case .failed:
      castIcon.foregroundStyle(PutioTheme.Colors.textSecondary)
    }
  }

  private var castIcon: some View {
    Image(putioIcon: .screencast)
      .resizable()
      .scaledToFit()
  }

  @ViewBuilder private var actions: some View {
    if case .failed(canRetry: true) = phase {
      Button(action: onRetry) {
        PutioVideoPillLabel(title: String(localized: "Try again"))
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("cast.retry")
    }
    Button(action: onStop) {
      PutioVideoPillLabel(title: String(localized: "Stop casting"))
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("cast.stop")
  }

  private var line: String {
    switch phase {
    case .loading: String(localized: "Loading on \(deviceName)")
    case .playing: String(localized: "Playing on \(deviceName)")
    case .failed: String(localized: "Can’t play this on \(deviceName).")
    }
  }

  private var identifier: String {
    switch phase {
    case .loading: "cast.loading"
    case .playing: "cast.playing"
    case .failed: "cast.failed"
    }
  }
}
