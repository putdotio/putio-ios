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

    /// Share of the quota in use for a progress bar, clamped to 0...1.
    public var usedFraction: Double {
      guard totalBytes > 0 else { return 0 }
      return min(max(Double(usedBytes) / Double(totalBytes), 0), 1)
    }

    /// Worded as put.io's web and legacy apps show usage: "20 GB of 1 TB used".
    public func usageSummary(locale: Locale = .current) -> String {
      let used = PutioFileRowModel.sizeText(bytes: usedBytes, locale: locale)
      let total = PutioFileRowModel.sizeText(bytes: totalBytes, locale: locale)
      return "\(used) of \(total) used"
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
  public let avatarURL: URL?
  /// Bytes in Trash as the account reports them; the Trash listing owns the
  /// live total while it is open.
  public let trashSizeBytes: Int64

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
    twoFactorEnabled: Bool = false,
    avatarURL: URL? = nil,
    trashSizeBytes: Int64 = 0
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
    self.avatarURL = avatarURL
    self.trashSizeBytes = trashSizeBytes
  }
}

// The avatar URL identifies the account, so diagnostics never print it.
extension PutioAccountSnapshot: CustomReflectable {
  public var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "id": id,
        "username": username,
        "email": email,
        "suggestNextVideo": suggestNextVideo,
        "rememberVideoTime": rememberVideoTime,
        "defaultSort": defaultSort as Any,
        "historyEnabled": historyEnabled,
        "trashEnabled": trashEnabled,
        "storage": storage,
        "routeName": routeName,
        "hideSubtitles": hideSubtitles,
        "dontAutoSelectSubtitles": dontAutoSelectSubtitles,
        "twoFactorEnabled": twoFactorEnabled,
        "avatarURL": avatarURL == nil ? "nil" : "<redacted>",
        "trashSizeBytes": trashSizeBytes,
      ],
      displayStyle: .struct
    )
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
  /// put.io's `is_shared`: the file reaches this account through another
  /// account's share.
  public let isShared: Bool

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
    resumePositionSeconds: Int,
    isShared: Bool = false
  ) {
    self.id = id
    self.parentID = parentID
    self.name = name
    self.kind = kind
    self.sizeBytes = sizeBytes
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.resumePositionSeconds = resumePositionSeconds
    self.isShared = isShared
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
