import Foundation

public struct PutioFolderRoute: Identifiable, Sendable {
  public let id: PutioFileID
  public let title: String

  public static let root = PutioFolderRoute(id: .root, title: "Files")

  public init(id: PutioFileID, title: String) {
    self.id = id
    self.title = title
  }
}

extension PutioFolderRoute: Hashable {
  public static func == (lhs: PutioFolderRoute, rhs: PutioFolderRoute) -> Bool {
    lhs.id == rhs.id
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }
}

public struct PutioFileRoute: Identifiable, Hashable, Sendable {
  public let item: PutioFileItem

  public init(item: PutioFileItem) {
    self.item = item
  }

  public var id: PutioFileID {
    item.id
  }

  public var videoPlaybackRoute: PutioVideoRoute? {
    guard item.kind == .video else { return nil }
    return PutioVideoRoute(id: item.id, parentID: item.parentID, title: item.name)
  }

  var audioPlaybackRoute: PutioAudioRoute? {
    guard item.kind == .audio else { return nil }
    return PutioAudioRoute(id: item.id, parentID: item.parentID, title: item.name)
  }

  var previewRoute: PutioPreviewRoute? {
    switch item.kind {
    case .image:
      PutioPreviewRoute(id: item.id, parentID: item.parentID, title: item.name, kind: .image)
    case .pdf:
      PutioPreviewRoute(id: item.id, parentID: item.parentID, title: item.name, kind: .pdf)
    case .folder, .video, .audio, .other:
      nil
    }
  }

  /// The typed routing table: every non-folder item resolves to exactly one
  /// action, so a tap never lands on a dead row.
  public var openAction: PutioFileOpenAction {
    if let videoPlaybackRoute { return .video(videoPlaybackRoute) }
    if let audioPlaybackRoute { return .audio(audioPlaybackRoute) }
    if let previewRoute { return .preview(previewRoute) }
    return .unsupported(PutioUnsupportedFileRoute(item: item))
  }

  /// A route that opens a player of any kind.
  var isPlayable: Bool {
    videoPlaybackRoute != nil || audioPlaybackRoute != nil
  }

  /// Media the VLC handoff can stream; previews and unknown types stay in-app.
  public var supportsExternalPlayback: Bool {
    isPlayable
  }

  /// Receivers play video only; audio stays on the phone.
  public var supportsCasting: Bool {
    item.kind == .video
  }

  /// Media the offline queue can store: the same set the players handle.
  public var supportsOfflineDownload: Bool {
    isPlayable
  }
}

public enum PutioFileOpenAction: Equatable, Sendable {
  case video(PutioVideoRoute)
  case audio(PutioAudioRoute)
  case preview(PutioPreviewRoute)
  case unsupported(PutioUnsupportedFileRoute)
}

public struct PutioPreviewRoute: Identifiable, Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case image
    case pdf
  }

  public let id: PutioFileID
  public let parentID: PutioFileID
  public let title: String
  public let kind: Kind
}

public struct PutioUnsupportedFileRoute: Identifiable, Equatable, Sendable {
  public let item: PutioFileItem

  public var id: PutioFileID { item.id }
}

public struct PutioAudioRoute: Identifiable, Equatable, Sendable {
  public let id: PutioFileID
  public let parentID: PutioFileID
  public let title: String

  public init(id: PutioFileID, parentID: PutioFileID, title: String) {
    self.id = id
    self.parentID = parentID
    self.title = title
  }
}

public struct PutioVideoRoute: Identifiable, Equatable, Sendable {
  public let id: PutioFileID
  public let parentID: PutioFileID
  public let title: String
  public let initialResolution: PutioPlaybackResolution?

  public init(
    id: PutioFileID,
    parentID: PutioFileID,
    title: String,
    initialResolution: PutioPlaybackResolution? = nil
  ) {
    self.id = id
    self.parentID = parentID
    self.title = title
    self.initialResolution = initialResolution
  }

  public init(nextVideo: PutioPlayableNextVideo) {
    self.init(
      id: nextVideo.video.id,
      parentID: nextVideo.video.parentID,
      title: nextVideo.video.name,
      initialResolution: nextVideo.initialResolution
    )
  }
}
