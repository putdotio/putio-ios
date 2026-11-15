import Foundation

public struct PutioNextVideo: Equatable, Sendable {
  public let id: PutioFileID
  public let parentID: PutioFileID
  public let name: String

  public init(id: PutioFileID, parentID: PutioFileID, name: String) {
    self.id = id
    self.parentID = parentID
    self.name = name
  }
}

public struct PutioPlaybackSource: Equatable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  public let url: URL
  public let startFromSeconds: Int
  public let resumesAfterFailure: Bool
  /// Set when Direct play opens the original file; `nil` for HLS, a
  /// converted copy and downloads.
  public let original: PutioOriginalPlayback?

  public init(
    url: URL, startFromSeconds: Int, resumesAfterFailure: Bool = false,
    original: PutioOriginalPlayback? = nil
  ) {
    self.url = url
    self.startFromSeconds = startFromSeconds
    self.resumesAfterFailure = resumesAfterFailure
    self.original = original
  }

  public func starting(at seconds: Int) -> PutioPlaybackSource {
    PutioPlaybackSource(
      url: url, startFromSeconds: seconds, resumesAfterFailure: resumesAfterFailure,
      original: original)
  }

  public var description: String {
    "PutioPlaybackSource(url: <redacted>, startFromSeconds: \(startFromSeconds), "
      + "resumesAfterFailure: \(resumesAfterFailure), "
      + "original: \(original.map { "\($0.player)" } ?? "nil"))"
  }

  public var debugDescription: String {
    description
  }

  public var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "url": "<redacted>",
        "startFromSeconds": startFromSeconds,
        "resumesAfterFailure": resumesAfterFailure,
        "original": original as Any,
      ],
      displayStyle: .struct
    )
  }
}

/// An original file under Direct play: the player that opens it, its audio
/// streams in file order, and put.io's subtitle files for it.
public struct PutioOriginalPlayback: Equatable, Sendable {
  public enum Player: Equatable, Sendable {
    /// MP4 and MOV originals AVPlayer decodes itself.
    case avPlayer
    /// Everything else, through the Direct play engine.
    case engine
  }

  public let player: Player
  public let audioStreams: [PutioOriginalAudioStream]
  public let subtitles: [PutioCastSubtitle]
  public let defaultSubtitleKey: String?

  public init(
    player: Player, audioStreams: [PutioOriginalAudioStream] = [],
    subtitles: [PutioCastSubtitle] = [], defaultSubtitleKey: String? = nil
  ) {
    self.player = player
    self.audioStreams = audioStreams
    self.subtitles = subtitles
    self.defaultSubtitleKey = defaultSubtitleKey
  }

  public func subtitles(_ subtitles: [PutioCastSubtitle], defaultKey: String?)
    -> PutioOriginalPlayback
  {
    PutioOriginalPlayback(
      player: player, audioStreams: audioStreams, subtitles: subtitles,
      defaultSubtitleKey: defaultKey)
  }
}

public struct PutioOriginalAudioStream: Equatable, Sendable {
  public let codec: String?
  public let profile: String?
  public let channels: Int?

  public init(codec: String?, profile: String? = nil, channels: Int?) {
    self.codec = codec
    self.profile = profile
    self.channels = channels
  }
}

public struct PutioPlaybackUnplayable: Error, Equatable, Sendable {
  public let reason: String

  public init(reason: String) {
    self.reason = reason
  }
}

public enum PutioPlaybackResolution: Equatable, Sendable {
  case ready(PutioPlaybackSource)
  case conversionRequired
}

/// An audio file in the playing one's folder.
public struct PutioQueuedAudio: Equatable, Identifiable, Sendable {
  public let id: PutioFileID
  public let parentID: PutioFileID
  public let name: String
  public let durationSeconds: Int?

  public init(id: PutioFileID, parentID: PutioFileID, name: String, durationSeconds: Int? = nil) {
    self.id = id
    self.parentID = parentID
    self.name = name
    self.durationSeconds = durationSeconds
  }
}

/// The audio files on either side of a track in its folder, `nil` where there
/// is none; every audio file of the folder in its order; and the folder's name.
public struct PutioAudioNeighbours: Equatable, Sendable {
  public let previous: PutioQueuedAudio?
  public let next: PutioQueuedAudio?
  public let folderName: String?
  public let queue: [PutioQueuedAudio]

  public init(
    previous: PutioQueuedAudio? = nil, next: PutioQueuedAudio? = nil, folderName: String? = nil,
    queue: [PutioQueuedAudio] = []
  ) {
    self.previous = previous
    self.next = next
    self.folderName = folderName
    self.queue = queue
  }

  /// `fileID`'s neighbours in `queue`; none when the queue does not hold it.
  public init(of fileID: PutioFileID, in queue: [PutioQueuedAudio], folderName: String?) {
    let index = queue.firstIndex { $0.id == fileID }
    self.init(
      previous: index.flatMap { $0 > 0 ? queue[$0 - 1] : nil },
      next: index.flatMap { $0 + 1 < queue.count ? queue[$0 + 1] : nil },
      folderName: folderName,
      queue: queue)
  }

  /// The same queue around another of its files; `nil` when it holds no such file.
  public func moved(to fileID: PutioFileID) -> PutioAudioNeighbours? {
    guard queue.contains(where: { $0.id == fileID }) else { return nil }
    return PutioAudioNeighbours(of: fileID, in: queue, folderName: folderName)
  }
}

public enum PutioVideoConversionStatus: Equatable, Sendable {
  case queued
  case converting(progress: Double)
  case completed
  case failed
  case unavailable
}

public enum PutioPlaybackMethod: String, CaseIterable, Hashable, Codable, Sendable {
  case standard = "hls"
  case directPlay = "file"

  public var other: PutioPlaybackMethod {
    switch self {
    case .standard: .directPlay
    case .directPlay: .standard
    }
  }
}

/// The keys this app stores in the account's `/config` document. put.io keeps
/// whatever a client writes, per OAuth app, so the shape is the app's to
/// declare; the web app keeps its own keys.
public enum PutioAppConfigKey: String, CaseIterable, Sendable {
  case autoplayNextVideo = "autoplay_next_video"
  case autoRotateVideo = "auto_rotate_video"
  case streamingMethod = "streaming_method"
  /// One flat key, dot included, as the App Store app writes it.
  case productAnalyticsPromptAnswered = "dismissed.product_analytics_prompt"
  /// File ids, newest pin first, as the Android apps write them.
  case pinnedFiles = "pinned_files"
  case searchHistory
  case searchHistoryEnabled
}

/// This app's view of the config document. Missing or unknown values decode
/// to the defaults below instead of failing, because another client may never
/// have written them.
public struct PutioAppConfig: Codable, Equatable, Sendable {
  public var autoplayNextVideo: Bool
  /// On unless turned off: video playback holds the phone in landscape.
  public var autoRotateVideo: Bool
  public var playbackMethod: PutioPlaybackMethod
  public var productAnalyticsPromptAnswered: Bool

  public init(
    autoplayNextVideo: Bool = false, autoRotateVideo: Bool = true,
    playbackMethod: PutioPlaybackMethod = .standard, productAnalyticsPromptAnswered: Bool = false
  ) {
    self.autoplayNextVideo = autoplayNextVideo
    self.autoRotateVideo = autoRotateVideo
    self.playbackMethod = playbackMethod
    self.productAnalyticsPromptAnswered = productAnalyticsPromptAnswered
  }

  private enum CodingKeys: String, CodingKey {
    case autoplayNextVideo = "autoplay_next_video"
    case autoRotateVideo = "auto_rotate_video"
    case playbackMethod = "streaming_method"
    case productAnalyticsPromptAnswered = "dismissed.product_analytics_prompt"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    autoplayNextVideo =
      (try? container.decodeIfPresent(Bool.self, forKey: .autoplayNextVideo)) ?? false
    autoRotateVideo =
      (try? container.decodeIfPresent(Bool.self, forKey: .autoRotateVideo)) ?? true
    let rawPlaybackMethod = try? container.decodeIfPresent(String.self, forKey: .playbackMethod)
    playbackMethod = rawPlaybackMethod.flatMap(PutioPlaybackMethod.init(rawValue:)) ?? .standard
    // Only a readable "not answered" asks; a value this app can't read counts
    // as an answer rather than asking again on every launch.
    do {
      productAnalyticsPromptAnswered =
        try container.decodeIfPresent(Bool.self, forKey: .productAnalyticsPromptAnswered) ?? false
    } catch {
      productAnalyticsPromptAnswered = true
    }
  }
}

/// One subtitle the receiver can toggle. `url` is a bearer credential and is
/// redacted from every textual rendering.
public struct PutioCastSubtitle: Equatable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  public let key: String
  public let language: String
  public let languageCode: String
  public let name: String
  public let source: PutioSubtitleSource
  public let url: URL

  public init(
    key: String, language: String, languageCode: String, name: String,
    source: PutioSubtitleSource, url: URL
  ) {
    self.key = key
    self.language = language
    self.languageCode = languageCode
    self.name = name
    self.source = source
    self.url = url
  }

  public var description: String {
    "PutioCastSubtitle(key: \(key), languageCode: \(languageCode), url: <redacted>)"
  }

  public var debugDescription: String { description }

  public var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "key": key, "language": language, "languageCode": languageCode, "name": name,
        "source": source, "url": "<redacted>",
      ],
      displayStyle: .struct)
  }
}

/// Everything a receiver needs to play one file: a video's HLS stream with
/// put.io's subtitle files side-loaded, or an audio file's original stream.
/// Every URL is tokened and redacted from every textual rendering.
public struct PutioCastMedia: Equatable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  public enum Kind: Equatable, Sendable {
    case video
    case audio(contentType: String)
  }

  public static let hlsContentType = "application/x-mpegURL"

  public let id: PutioFileID
  public let parentID: PutioFileID
  public let title: String
  public let url: URL
  public let artworkURL: URL?
  public let durationSeconds: Double
  public let startFromSeconds: Int
  public let kind: Kind
  public let subtitles: [PutioCastSubtitle]
  public let defaultSubtitleKey: String?

  public init(
    id: PutioFileID, parentID: PutioFileID, title: String, url: URL, artworkURL: URL?,
    durationSeconds: Double, startFromSeconds: Int, kind: Kind = .video,
    subtitles: [PutioCastSubtitle] = [], defaultSubtitleKey: String? = nil
  ) {
    self.id = id
    self.parentID = parentID
    self.title = title
    self.url = url
    self.artworkURL = artworkURL
    self.durationSeconds = durationSeconds
    self.startFromSeconds = startFromSeconds
    self.kind = kind
    self.subtitles = subtitles
    self.defaultSubtitleKey = defaultSubtitleKey
  }

  public var contentType: String {
    switch kind {
    case .video: Self.hlsContentType
    case .audio(let contentType): contentType
    }
  }

  public var description: String {
    "PutioCastMedia(id: \(id.rawValue), url: <redacted>)"
  }

  public var debugDescription: String { description }

  public var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "id": id, "parentID": parentID, "title": title, "url": "<redacted>",
        "durationSeconds": durationSeconds, "startFromSeconds": startFromSeconds,
        "kind": kind, "subtitles": subtitles, "defaultSubtitleKey": defaultSubtitleKey as Any,
      ],
      displayStyle: .struct)
  }
}

public enum PutioCastResolution: Equatable, Sendable {
  case ready(PutioCastMedia)
  case conversionRequired
}
