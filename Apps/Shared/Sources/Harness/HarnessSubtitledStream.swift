#if DEBUG
  import Foundation
  import PutioCore

  /// Stands in for the put.io HLS endpoint's subtitle renditions. The server
  /// shapes `subtitle_key=all` from the account: no subtitle renditions when
  /// subtitles are hidden, and the first one `DEFAULT` and `AUTOSELECT` unless
  /// auto-selection is disabled. With `--putio-harness-subtitled-stream`, the
  /// seeded scenario streams the multi-audio fixture in the matching shape.
  enum HarnessSubtitledStream {
    enum Tracks: String {
      case none
      case one
      case three
      case failing
    }

    static let tracksArgument = "--putio-harness-subtitle-tracks"

    static func tracks(arguments: [String] = ProcessInfo.processInfo.arguments) -> Tracks? {
      guard let flag = arguments.firstIndex(of: tracksArgument),
        arguments.indices.contains(flag + 1)
      else { return nil }
      guard let tracks = Tracks(rawValue: arguments[flag + 1]) else {
        preconditionFailure("unknown \(tracksArgument) value \(arguments[flag + 1])")
      }
      return tracks
    }

    static func path(
      for account: PutioAccountSnapshot,
      arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> String? {
      let tracks = tracks(arguments: arguments)
      guard tracks != nil || arguments.contains("--putio-harness-subtitled-stream") else {
        return nil
      }
      if account.hideSubtitles { return "multi-audio/multi-subtitles-hidden.m3u8" }
      switch tracks {
      case .none?: return "multi-audio/multi-subtitles-hidden.m3u8"
      case .one?: return "multi-audio/multi-subtitles-one.m3u8"
      case .three?: return "multi-audio/multi-subtitles-three.m3u8"
      case .failing?: return "multi-audio/multi-subtitles-failing.m3u8"
      case nil: break
      }
      if account.dontAutoSelectSubtitles { return "multi-audio/multi-subtitles-unselected.m3u8" }
      return "multi-audio/multi-subtitles.m3u8"
    }

    static func listing(fileID: Int, arguments: [String] = ProcessInfo.processInfo.arguments)
      -> String?
    {
      guard let tracks = tracks(arguments: arguments) else { return nil }
      let subtitles: [(key: String, code: String, language: String, source: String)] =
        switch tracks {
        case .none: []
        case .one: [("en-mkv", "eng", "English", "mkv")]
        case .three:
          [
            ("en-mkv", "eng", "English", "mkv"), ("es", "spa", "Spanish", "folder"),
            ("tr", "tur", "Turkish", "opensubtitles"),
          ]
        case .failing:
          [("en-mkv", "eng", "English", "mkv"), ("tr", "tur", "Turkish", "opensubtitles")]
        }
      let rows = subtitles.map { subtitle in
        #"{"key":"\#(subtitle.key)","language":"\#(subtitle.language)","language_code":"\#(subtitle.code)","name":"\#(subtitle.language).srt","source":"\#(subtitle.source)","url":"https://api.put.io/v2/files/\#(fileID)/subtitles/\#(subtitle.key)"}"#
      }
      let defaultKey = subtitles.first.map { #""\#($0.key)""# } ?? "null"
      return #"{"default":\#(defaultKey),"subtitles":[\#(rows.joined(separator: ","))]}"#
    }
  }
#endif
