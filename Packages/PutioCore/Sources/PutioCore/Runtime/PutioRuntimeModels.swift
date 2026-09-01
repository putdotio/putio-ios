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
  public let rememberVideoTime: Bool
  public let storage: Storage

  public init(
    id: Int,
    username: String,
    email: String,
    rememberVideoTime: Bool,
    storage: Storage
  ) {
    self.id = id
    self.username = username
    self.email = email
    self.rememberVideoTime = rememberVideoTime
    self.storage = storage
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

public struct PutioFolderContents: Equatable, Sendable {
  public let folder: PutioFileItem?
  public let items: [PutioFileItem]
  public let hasMore: Bool

  public init(folder: PutioFileItem?, items: [PutioFileItem], hasMore: Bool) {
    self.folder = folder
    self.items = items
    self.hasMore = hasMore
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
