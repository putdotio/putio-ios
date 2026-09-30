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

  public init(url: URL, startFromSeconds: Int) {
    self.url = url
    self.startFromSeconds = startFromSeconds
  }

  public var description: String {
    "PutioPlaybackSource(url: <redacted>, startFromSeconds: \(startFromSeconds))"
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
      ],
      displayStyle: .struct
    )
  }
}

public enum PutioPlaybackResolution: Equatable, Sendable {
  case ready(PutioPlaybackSource)
  case conversionRequired
}

/// The next audio file the server suggests after a track, or `nil` at the end
/// of the folder.
public struct PutioNextAudio: Equatable, Sendable {
  public let id: PutioFileID
  public let parentID: PutioFileID
  public let name: String

  public init(id: PutioFileID, parentID: PutioFileID, name: String) {
    self.id = id
    self.parentID = parentID
    self.name = name
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

/// The keys this app stores in the account's `/config` document. put.io keeps
/// whatever a client writes, so the shape is the app's to declare; the web app
/// keeps its own keys, and the Chromecast key below is the one iOS has always
/// written.
public enum PutioAppConfigKey: String, CaseIterable, Sendable {
  case chromecastPlaybackType = "chromecast_playback_type"
  case autoplayNextVideo = "autoplay_next_video"
}

/// This app's view of the config document. Missing or unknown values decode
/// to the defaults below instead of failing, because another client may never
/// have written them.
public struct PutioAppConfig: Codable, Equatable, Sendable {
  public var chromecastPlaybackType: PutioCastPlaybackType
  public var autoplayNextVideo: Bool

  public init(chromecastPlaybackType: PutioCastPlaybackType = .hls, autoplayNextVideo: Bool = false)
  {
    self.chromecastPlaybackType = chromecastPlaybackType
    self.autoplayNextVideo = autoplayNextVideo
  }

  private enum CodingKeys: String, CodingKey {
    case chromecastPlaybackType = "chromecast_playback_type"
    case autoplayNextVideo = "autoplay_next_video"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let rawPlaybackType = try? container.decodeIfPresent(
      String.self, forKey: .chromecastPlaybackType)
    chromecastPlaybackType = rawPlaybackType.flatMap(PutioCastPlaybackType.init(rawValue:)) ?? .hls
    autoplayNextVideo =
      (try? container.decodeIfPresent(Bool.self, forKey: .autoplayNextVideo)) ?? false
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
