import Observation
import PutioCore
import SwiftUI

/// Playback belongs to the signed-in tab shell, not its dismissible sheet.
@MainActor
@Observable
final class PutioAudioPlaybackSession {
  private(set) var model: PutioAudioPlayerModel?
  var isPresented = false
  @ObservationIgnored private var startTask: Task<Void, Never>?

  func present(_ model: PutioAudioPlayerModel) {
    stop()
    self.model = model
    isPresented = true
    startTask = Task { await model.start() }
  }

  func stop() {
    startTask?.cancel()
    startTask = nil
    model?.stop()
    model = nil
    isPresented = false
  }
}

struct PutioAudioMiniPlayer: View {
  let model: PutioAudioPlayerModel
  let onOpen: () -> Void
  @Environment(\.tabViewBottomAccessoryPlacement) private var placement

  var body: some View {
    HStack(spacing: PutioTheme.Spacing.space2) {
      Button(action: onOpen) {
        HStack(spacing: PutioTheme.Spacing.space3) {
          if placement != .inline {
            Image(putioIcon: .fileAudio)
              .foregroundStyle(PutioTheme.Colors.accent)
              .accessibilityHidden(true)
          }
          VStack(alignment: .leading, spacing: 0) {
            Text(model.track.title)
              .putioFont(PutioTheme.Typography.body)
              .foregroundStyle(PutioTheme.Colors.textPrimary)
              .lineLimit(1)
            if placement != .inline {
              Text(status)
                .putioFont(PutioTheme.Typography.caption)
                .foregroundStyle(PutioTheme.Colors.textSecondary)
                .lineLimit(1)
            }
          }
          Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Now Playing, \(model.track.title), \(status)")
      .accessibilityIdentifier("audio.mini.open")
      if case .loading = model.state {
        ProgressView().frame(minWidth: 44, minHeight: 44)
          .accessibilityLabel("Preparing audio")
      } else if case .failed = model.state {
        Button(action: onOpen) {
          Image(systemName: "exclamationmark.circle")
            .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("Playback failed, open to retry")
      } else {
        Button {
          model.togglePlayPause()
        } label: {
          Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
            .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
        .accessibilityIdentifier("audio.mini.toggle")
        if placement != .inline {
          Button {
            model.skipToNext()
          } label: {
            Image(systemName: "forward.end.fill")
              .frame(minWidth: 44, minHeight: 44)
          }
          .accessibilityLabel("Next track")
          .accessibilityIdentifier("audio.mini.next")
        }
      }
    }
    .buttonStyle(.plain)
    .padding(.horizontal, PutioTheme.Spacing.space3)
  }

  private var status: String {
    switch model.state {
    case .loading: "Preparing audio"
    case .playing: "Playing"
    case .paused: "Paused"
    case .interrupted: "Playback interrupted"
    case .failed: "Could not play audio"
    case .ended: "End of folder"
    }
  }
}
