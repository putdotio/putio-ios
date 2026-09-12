import Foundation

public struct PutioAccountSnapshot: Equatable, Sendable {
  public struct Storage: Equatable, Sendable {
    public let availableBytes: Int64
    public let totalBytes: Int64
    public let usedBytes: Int64

    public init(availableBytes: Int64, totalBytes: Int64, usedBytes: Int64) {
      self.availableBytes = availableBytes
      self.totalBytes = totalBytes
      self.usedBytes = usedBytes
    }
  }

  public let id: Int
  public let username: String
  public let email: String
  public let suggestNextVideo: Bool
  public let rememberVideoTime: Bool
  public let defaultSort: PutioFolderSort?
  public let historyEnabled: Bool
  public let trashEnabled: Bool
  public let storage: Storage
  public let routeName: String
  public let hideSubtitles: Bool
  public let dontAutoSelectSubtitles: Bool
  public let twoFactorEnabled: Bool

  public init(
    id: Int,
    username: String,
    email: String,
    suggestNextVideo: Bool,
    rememberVideoTime: Bool,
    defaultSort: PutioFolderSort?,
    historyEnabled: Bool,
    trashEnabled: Bool,
    storage: Storage,
    routeName: String = "default",
    hideSubtitles: Bool = false,
    dontAutoSelectSubtitles: Bool = false,
    twoFactorEnabled: Bool = false
  ) {
    self.id = id
    self.username = username
    self.email = email
    self.suggestNextVideo = suggestNextVideo
    self.rememberVideoTime = rememberVideoTime
    self.defaultSort = defaultSort
    self.historyEnabled = historyEnabled
    self.trashEnabled = trashEnabled
    self.storage = storage
    self.routeName = routeName
    self.hideSubtitles = hideSubtitles
    self.dontAutoSelectSubtitles = dontAutoSelectSubtitles
    self.twoFactorEnabled = twoFactorEnabled
  }
}

public struct PutioFileID: RawRepresentable, Hashable, Codable, Sendable {
  public static let root = PutioFileID(rawValue: 0)

  public let rawValue: Int

  public init(rawValue: Int) {
    self.rawValue = rawValue
  }
}

public enum PutioFileKind: Hashable, Sendable {
  case folder
  case video
  case audio
  case image
  case pdf
  case other(String)
}

public struct PutioFileItem: Identifiable, Hashable, Sendable {
  public let id: PutioFileID
  public let parentID: PutioFileID
  public let name: String
  public let kind: PutioFileKind
  public let sizeBytes: Int64
  public let createdAt: Date
  public let updatedAt: Date
  public let resumePositionSeconds: Int

  public var isWatched: Bool {
    kind == .video && resumePositionSeconds > 0
  }

  public init(
    id: PutioFileID,
    parentID: PutioFileID,
    name: String,
    kind: PutioFileKind,
    sizeBytes: Int64,
    createdAt: Date,
    updatedAt: Date,
    resumePositionSeconds: Int
  ) {
    self.id = id
    self.parentID = parentID
    self.name = name
    self.kind = kind
    self.sizeBytes = sizeBytes
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.resumePositionSeconds = resumePositionSeconds
  }
}

/// Server-side folder ordering. Raw values are the put.io `sort_by` keys shared
/// with the web and Android apps; unknown server values decode as `nil`.
public enum PutioFolderSort: String, CaseIterable, Hashable, Sendable {
  case nameAscending = "NAME_ASC"
  case nameDescending = "NAME_DESC"
  case sizeAscending = "SIZE_ASC"
  case sizeDescending = "SIZE_DESC"
  case dateAddedAscending = "DATE_ASC"
  case dateAddedDescending = "DATE_DESC"
  case dateModifiedAscending = "MODIFIED_ASC"
  case dateModifiedDescending = "MODIFIED_DESC"
  case typeAscending = "TYPE_ASC"
  case typeDescending = "TYPE_DESC"
  case watchStatusAscending = "WATCH_ASC"
  case watchStatusDescending = "WATCH_DESC"
}

public struct PutioFolderContents: Equatable, Sendable {
  public let folder: PutioFileItem?
  public let items: [PutioFileItem]
  /// Continuation token for the next page, or `nil` when the listing is complete.
  public let nextCursor: String?
  /// The folder's own sort as reported by the server, or `nil` when it inherits
  /// the account default or reports an unknown key.
  public let sort: PutioFolderSort?

  public init(
    folder: PutioFileItem?,
    items: [PutioFileItem],
    nextCursor: String? = nil,
    sort: PutioFolderSort? = nil
  ) {
    self.folder = folder
    self.items = items
    self.nextCursor = nextCursor
    self.sort = sort
  }

  public var hasMore: Bool {
    nextCursor != nil
  }
}

public struct PutioFileSearchPage: Equatable, Sendable {
  public let items: [PutioFileItem]
  public let nextCursor: String?
  public let totalCount: Int

  public init(items: [PutioFileItem], nextCursor: String?, totalCount: Int) {
    self.items = items
    self.nextCursor = nextCursor
    self.totalCount = totalCount
  }
}

public struct PutioTrashItem: Identifiable, Hashable, Sendable {
  public let id: PutioFileID
  public let parentID: PutioFileID
  public let name: String
  public let kind: PutioFileKind
  public let sizeBytes: Int64
  public let deletedAt: Date
  public let expiresAt: Date

  public init(
    id: PutioFileID,
    parentID: PutioFileID,
    name: String,
    kind: PutioFileKind,
    sizeBytes: Int64,
    deletedAt: Date,
    expiresAt: Date
  ) {
    self.id = id
    self.parentID = parentID
    self.name = name
    self.kind = kind
    self.sizeBytes = sizeBytes
    self.deletedAt = deletedAt
    self.expiresAt = expiresAt
  }
}

public struct PutioTrashPage: Equatable, Sendable {
  public let items: [PutioTrashItem]
  public let nextCursor: String?
  public let totalCount: Int?
  public let sizeBytes: Int64

  public init(
    items: [PutioTrashItem],
    nextCursor: String?,
    totalCount: Int?,
    sizeBytes: Int64
  ) {
    self.items = items
    self.nextCursor = nextCursor
    self.totalCount = totalCount
    self.sizeBytes = sizeBytes
  }
}

/// Every case means the restore committed; only the destination lookup that
/// follows can fail or be cancelled.
public enum PutioTrashRestoreResult: Equatable, Sendable {
  case restored(destinationID: PutioFileID)
  case restoredDestinationUnknown
  /// The caller was cancelled after the restore committed; the destination
  /// was never requested to completion.
  case restoredLookupCancelled
}

/// Outcome of a committed destructive Trash mutation. `storageRefreshed` is
/// `false` when the account storage snapshot could not be reloaded afterwards.
public struct PutioTrashMutationResult: Equatable, Sendable {
  public let storageRefreshed: Bool

  public init(storageRefreshed: Bool) {
    self.storageRefreshed = storageRefreshed
  }
}

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

/// A tokened put.io download URL for a single file, resolved for previews and
/// external players. The URL is a bearer credential and is redacted from every
/// textual rendering.
public struct PutioFileDownloadSource: Equatable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  public let id: PutioFileID
  public let kind: PutioFileKind
  public let name: String
  public let url: URL

  public init(id: PutioFileID, kind: PutioFileKind, name: String, url: URL) {
    self.id = id
    self.kind = kind
    self.name = name
    self.url = url
  }

  public var description: String {
    "PutioFileDownloadSource(id: \(id.rawValue), kind: \(kind), url: <redacted>)"
  }

  public var debugDescription: String {
    description
  }

  public var customMirror: Mirror {
    Mirror(
      self,
      children: ["id": id, "kind": kind, "name": name, "url": "<redacted>"],
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

public enum PutioRuntimeError: Error, Equatable, Sendable {
  case authenticationRequired
  case sessionExpired
  case notFound
  case rateLimited
  case transient
  case invalidResponse
  case unknown
}

public enum PutioHistoryEventKind: Equatable, Sendable {
  case upload(name: String, sizeBytes: Int64, fileID: PutioFileID?)
  case fileShared(name: String, sharingUserName: String, fileID: PutioFileID?)
  case transferCompleted(name: String, sizeBytes: Int64, fileID: PutioFileID?)
  case transferError(name: String)
  case fileFromRSSDeleted(name: String, sizeBytes: Int64)
  case rssFilterPaused(title: String)
  case transferFromRSSError(name: String)
  case transferCallbackError(name: String)
}

public struct PutioHistoryEventItem: Identifiable, Equatable, Sendable {
  public let id: Int
  public let createdAt: Date
  public let kind: PutioHistoryEventKind

  public init(id: Int, createdAt: Date, kind: PutioHistoryEventKind) {
    self.id = id
    self.createdAt = createdAt
    self.kind = kind
  }

  public var fileID: PutioFileID? {
    switch kind {
    case .upload(_, _, let fileID), .fileShared(_, _, let fileID),
      .transferCompleted(_, _, let fileID):
      fileID
    default:
      nil
    }
  }
}

public struct PutioHistoryPage: Equatable, Sendable {
  public let items: [PutioHistoryEventItem]
  /// Last raw event ID, including events outside the supported presentation kinds.
  public let nextBefore: Int?

  public init(items: [PutioHistoryEventItem], nextBefore: Int?) {
    self.items = items
    self.nextBefore = nextBefore
  }
}

public struct PutioAccountPreferencesMutationResult: Equatable, Sendable {
  public let accountRefreshed: Bool

  public init(accountRefreshed: Bool) {
    self.accountRefreshed = accountRefreshed
  }
}

public struct PutioPlaybackRoute: Equatable, Sendable, Identifiable {
  public let name: String
  public let description: String
  public var id: String { name }

  public init(name: String, description: String) {
    self.name = name
    self.description = description
  }
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

/// An input put.io rejected outright. Unlike `PutioRuntimeError`, these keep
/// the user on the form with what they typed.
public enum PutioAccountSecurityError: Error, Equatable, Sendable {
  case invalidTwoFactorCode
  case invalidDeviceCode
  case invalidPassword
}

/// An OAuth grant the account has issued: another app, a TV, or this app.
public struct PutioAuthorizedApp: Equatable, Hashable, Identifiable, Sendable {
  public let id: Int
  public let name: String
  public let description: String
  /// Revoking the grant this app signed in with would end the session, so
  /// the shell lists it without a revoke action.
  public let isCurrentClient: Bool

  public init(id: Int, name: String, description: String, isCurrentClient: Bool) {
    self.id = id
    self.name = name
    self.description = description
    self.isCurrentClient = isCurrentClient
  }
}

public struct PutioTwoFactorRecoveryCode: Equatable, Hashable, Sendable {
  public let code: String
  public let isUsed: Bool

  public init(code: String, isUsed: Bool) {
    self.code = code
    self.isUsed = isUsed
  }
}

/// The account data categories put.io can clear in one request.
public enum PutioAccountDataCategory: String, CaseIterable, Sendable {
  case files
  case finishedTransfers
  case activeTransfers
  case rssFeeds
  case rssLogs
  case history
  case trash
  case friends

  public var title: String {
    switch self {
    case .files: "Files"
    case .finishedTransfers: "Finished transfers"
    case .activeTransfers: "Active transfers"
    case .rssFeeds: "RSS feeds"
    case .rssLogs: "RSS logs"
    case .history: "History"
    case .trash: "Trash"
    case .friends: "Friends"
    }
  }
}
