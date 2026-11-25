import Foundation

/// What a video's detail lists beyond its row: the saved position, the
/// length when put.io reports one, the subtitle languages, or `nil` when
/// they could not load, and the poster frame when put.io has one.
public struct PutioVideoDetails: Equatable, Sendable {
  public let resumePositionSeconds: Int
  public let durationSeconds: Int?
  public let subtitles: [String]?
  public let screenshotURL: URL?

  public init(
    resumePositionSeconds: Int, durationSeconds: Int?, subtitles: [String]?,
    screenshotURL: URL? = nil
  ) {
    self.resumePositionSeconds = resumePositionSeconds
    self.durationSeconds = durationSeconds
    self.subtitles = subtitles
    self.screenshotURL = screenshotURL
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

public struct PutioFileDetailFact: Equatable, Identifiable, Sendable {
  public enum Kind: String, Sendable {
    case size, added, length, subtitles, folder
  }

  public let kind: Kind
  public let label: String
  public let value: String

  public var id: String { kind.rawValue }
  public var isNumeric: Bool { kind == .size || kind == .length }
}

/// What a file's detail shows once loaded: its primary action title and its
/// facts. Videos add their length and subtitle languages when put.io reports
/// them.
public struct PutioFileDetailModel: Equatable, Sendable {
  public let item: PutioFileItem
  public let isVideo: Bool
  public let details: PutioVideoDetails?
  public let folder: String?

  public init(
    item: PutioFileItem, isVideo: Bool, details: PutioVideoDetails?, folder: String?
  ) {
    self.item = item
    self.isVideo = isVideo
    self.details = details
    self.folder = folder
  }

  public var resumePositionSeconds: Int {
    details?.resumePositionSeconds ?? item.resumePositionSeconds
  }

  public var primaryTitle: String {
    guard resumePositionSeconds > 0 else { return String(localized: "Play", bundle: .module) }
    let time = PutioFileDetailText.clock(seconds: resumePositionSeconds)
    return String(localized: "Resume from \(time)", bundle: .module)
  }

  public func facts(locale: Locale = .current) -> [PutioFileDetailFact] {
    var facts = [
      PutioFileDetailFact(
        kind: .size, label: String(localized: "Size", bundle: .module),
        value: PutioFileRowModel.sizeText(bytes: item.sizeBytes, locale: locale)),
      PutioFileDetailFact(
        kind: .added, label: String(localized: "Added", bundle: .module),
        value: item.createdAt.formatted(
          .dateTime.month(.abbreviated).day().year().locale(locale))),
    ]
    if isVideo, let seconds = details?.durationSeconds {
      facts.append(
        PutioFileDetailFact(
          kind: .length, label: String(localized: "Length", bundle: .module),
          value: PutioFileDetailText.clock(seconds: seconds)))
    }
    if isVideo, let subtitles = details?.subtitles, !subtitles.isEmpty {
      facts.append(
        PutioFileDetailFact(
          kind: .subtitles, label: String(localized: "Subtitles", bundle: .module),
          value: subtitles.formatted(.list(type: .and, width: .narrow).locale(locale))))
    }
    if let folder {
      facts.append(
        PutioFileDetailFact(
          kind: .folder, label: String(localized: "Folder", bundle: .module), value: folder))
    }
    return facts
  }
}
