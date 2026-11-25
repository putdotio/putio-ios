import PutioCore
import SwiftUI

/// The playing audio beside the tab bar: Select opens Now Playing, Play/Pause
/// toggles it, and the context menu stops it.
struct TVAudioMiniPlayer: View {
  let model: PutioAudioPlayerModel
  let onOpen: () -> Void
  let onStop: () -> Void

  var body: some View {
    Button(action: onOpen) {
      HStack(spacing: PutioTheme.TV.Spacing.small) {
        Image(putioIcon: .fileAudioFill)
          .resizable()
          .scaledToFit()
          .frame(width: Self.glyph, height: Self.glyph)
          .foregroundStyle(PutioTheme.Colors.accent)
        VStack(alignment: .leading, spacing: PutioTheme.TV.Spacing.xs) {
          Text(model.track.title)
            .putioFont(PutioTheme.TV.Typography.small)
            .lineLimit(1)
            .accessibilityIdentifier("audio.mini.title")
          progress
        }
        Image(putioIcon: model.isPlaying ? .pauseFill : .playFill)
          .resizable()
          .scaledToFit()
          .frame(width: Self.toggleGlyph, height: Self.toggleGlyph)
          .accessibilityIdentifier("audio.mini.toggle")
      }
      .padding(.leading, Self.leading)
      .padding(.trailing, Self.trailing)
      .frame(width: Self.width, height: Self.height)
    }
    .buttonStyle(.bordered)
    .buttonBorderShape(.capsule)
    .onPlayPauseCommand { model.togglePlayPause() }
    .contextMenu {
      Button(
        String(localized: "Stop playback", bundle: .putioCore), role: .destructive, action: onStop
      )
      .accessibilityIdentifier("audio.mini.stop")
    }
    .accessibilityLabel(String(localized: "Open player", bundle: .putioCore))
    .accessibilityValue(model.track.title)
    .accessibilityIdentifier("audio.mini.open")
  }

  private var progress: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Capsule().fill(Color.white.opacity(0.25))
        Capsule()
          .fill(Color.white.opacity(0.9))
          .frame(width: geometry.size.width * fraction)
      }
    }
    .frame(height: Self.progressHeight)
    .accessibilityHidden(true)
  }

  private var fraction: CGFloat {
    guard let duration = model.durationSeconds, duration > 0 else { return 0 }
    return min(max(CGFloat(model.elapsedSeconds) / CGFloat(duration), 0), 1)
  }

  static let width: CGFloat = 420
  static let height: CGFloat = 72
  private static let leading: CGFloat = 22
  private static let trailing: CGFloat = 26
  private static let glyph: CGFloat = 30
  private static let toggleGlyph: CGFloat = 34
  private static let progressHeight: CGFloat = 4
}
