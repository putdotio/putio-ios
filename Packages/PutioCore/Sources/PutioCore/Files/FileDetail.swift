import Foundation

/// What a video's detail lists beyond its row: the length, when put.io
/// reports one, and the subtitle languages, or `nil` when they could not load.
public struct PutioVideoDetails: Equatable, Sendable {
  public let durationSeconds: Int?
  public let subtitles: [String]?

  public init(durationSeconds: Int?, subtitles: [String]?) {
    self.durationSeconds = durationSeconds
    self.subtitles = subtitles
  }
}

public enum PutioFileDetailText {
  /// The raw name with a break opportunity after every dot, so a long
  /// release name wraps between its parts instead of mid-word.
  public static func wrappableName(_ name: String) -> String {
    name.replacingOccurrences(of: ".", with: ".\u{200B}")
  }

  /// A position or length as a player clock: `49:49`, or `1:02:03` past an hour.
  public static func clock(seconds: Int) -> String {
    let duration = Duration.seconds(max(seconds, 0))
    return duration.formatted(
      .time(pattern: seconds >= 3_600 ? .hourMinuteSecond : .minuteSecond))
  }

  public static func folderPath(_ titles: [String]) -> String {
    titles.joined(separator: " / ")
  }

  /// Subtitle languages in the server's order, each once. A track without a
  /// language falls back to its name.
  public static func subtitleLanguages(_ tracks: [(language: String, name: String)]) -> [String] {
    var seen = Set<String>()
    return tracks.compactMap { track in
      let label = track.language.isEmpty ? track.name : track.language
      guard !label.isEmpty, seen.insert(label).inserted else { return nil }
      return label
    }
  }
}
