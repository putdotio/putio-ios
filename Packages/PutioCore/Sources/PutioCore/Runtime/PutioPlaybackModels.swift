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

  public init(url: URL, startFromSeconds: Int, resumesAfterFailure: Bool = false) {
    self.url = url
    self.startFromSeconds = startFromSeconds
    self.resumesAfterFailure = resumesAfterFailure
  }

  public var description: String {
    "PutioPlaybackSource(url: <redacted>, startFromSeconds: \(startFromSeconds), resumesAfterFailure: \(resumesAfterFailure))"
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
      ],
      displayStyle: .struct
    )
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
}

/// The put.io `chromecast_playback_type` account config. HLS streams the
/// original file with server-muxed subtitles; MP4 casts the converted file
/// and attaches subtitles as side-loaded WebVTT tracks.
public enum PutioCastPlaybackType: String, CaseIterable, Hashable, Codable, Sendable {
  case hls
  case mp4
}

public enum PutioPlaybackMethod: String, CaseIterable, Hashable, Codable, Sendable {
  case standard = "hls"
  case directPlay = "file"
}

/// The keys this app stores in the account's `/config` document. put.io keeps
/// whatever a client writes, per OAuth app, so the shape is the app's to
/// declare; the web app keeps its own keys, and the Chromecast key below is
/// the one iOS has always written.
public enum PutioAppConfigKey: String, CaseIterable, Sendable {
  case chromecastPlaybackType = "chromecast_playback_type"
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
  public var chromecastPlaybackType: PutioCastPlaybackType
  public var autoplayNextVideo: Bool
  /// On unless turned off: video playback holds the phone in landscape.
  public var autoRotateVideo: Bool
  public var playbackMethod: PutioPlaybackMethod
  public var productAnalyticsPromptAnswered: Bool

  public init(
    chromecastPlaybackType: PutioCastPlaybackType = .hls, autoplayNextVideo: Bool = false,
    autoRotateVideo: Bool = true, playbackMethod: PutioPlaybackMethod = .standard,
    productAnalyticsPromptAnswered: Bool = false
  ) {
    self.chromecastPlaybackType = chromecastPlaybackType
    self.autoplayNextVideo = autoplayNextVideo
    self.autoRotateVideo = autoRotateVideo
    self.playbackMethod = playbackMethod
    self.productAnalyticsPromptAnswered = productAnalyticsPromptAnswered
  }

  private enum CodingKeys: String, CodingKey {
    case chromecastPlaybackType = "chromecast_playback_type"
    case autoplayNextVideo = "autoplay_next_video"
    case autoRotateVideo = "auto_rotate_video"
    case playbackMethod = "streaming_method"
    case productAnalyticsPromptAnswered = "dismissed.product_analytics_prompt"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let rawPlaybackType = try? container.decodeIfPresent(
      String.self, forKey: .chromecastPlaybackType)
    chromecastPlaybackType = rawPlaybackType.flatMap(PutioCastPlaybackType.init(rawValue:)) ?? .hls
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
  public let url: URL

  public init(key: String, language: String, languageCode: String, name: String, url: URL) {
    self.key = key
    self.language = language
    self.languageCode = languageCode
    self.name = name
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
        "url": "<redacted>",
      ],
      displayStyle: .struct)
  }
}

/// Everything a receiver needs to play one video. The stream URL is tokened
/// and redacted from every textual rendering. `subtitles` is empty for HLS,
/// where the server muxes them into the stream.
public struct PutioCastMedia: Equatable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  public let id: PutioFileID
  public let parentID: PutioFileID
  public let title: String
  public let playbackType: PutioCastPlaybackType
  public let url: URL
  public let artworkURL: URL?
  public let durationSeconds: Double
  public let startFromSeconds: Int
  public let subtitles: [PutioCastSubtitle]
  public let defaultSubtitleKey: String?

  public init(
    id: PutioFileID, parentID: PutioFileID, title: String, playbackType: PutioCastPlaybackType,
    url: URL, artworkURL: URL?, durationSeconds: Double, startFromSeconds: Int,
    subtitles: [PutioCastSubtitle], defaultSubtitleKey: String?
  ) {
    self.id = id
    self.parentID = parentID
    self.title = title
    self.playbackType = playbackType
    self.url = url
    self.artworkURL = artworkURL
    self.durationSeconds = durationSeconds
    self.startFromSeconds = startFromSeconds
    self.subtitles = subtitles
    self.defaultSubtitleKey = defaultSubtitleKey
  }

  public var description: String {
    "PutioCastMedia(id: \(id.rawValue), playbackType: \(playbackType), url: <redacted>)"
  }

  public var debugDescription: String { description }

  public var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "id": id, "parentID": parentID, "title": title, "playbackType": playbackType,
        "url": "<redacted>", "durationSeconds": durationSeconds,
        "startFromSeconds": startFromSeconds, "subtitles": subtitles,
      ],
      displayStyle: .struct)
  }
}

public enum PutioCastResolution: Equatable, Sendable {
  case ready(PutioCastMedia)
  case conversionRequired
}
