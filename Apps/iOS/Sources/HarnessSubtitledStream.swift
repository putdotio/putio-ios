#if DEBUG
  import Foundation
  import PutioCore

  /// Stands in for the put.io HLS endpoint's subtitle renditions. The server
  /// shapes `subtitle_key=all` from the account: no subtitle renditions when
  /// subtitles are hidden, and the first one `DEFAULT` and `AUTOSELECT` unless
  /// auto-selection is disabled. With `--putio-harness-subtitled-stream`, the
  /// seeded scenario streams the multi-audio fixture in the matching shape.
  enum HarnessSubtitledStream {
    static func path(
      for account: PutioAccountSnapshot,
      arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> String? {
      guard arguments.contains("--putio-harness-subtitled-stream") else { return nil }
      if account.hideSubtitles { return "multi-audio/multi-subtitles-hidden.m3u8" }
      if account.dontAutoSelectSubtitles { return "multi-audio/multi-subtitles-unselected.m3u8" }
      return "multi-audio/multi-subtitles.m3u8"
    }
  }
#endif
