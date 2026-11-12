import Foundation

public enum PutioFileMenuRow: String, Equatable, Sendable {
  case play
  case download
  case openInVLC
  case share
  case select
  case markWatched
  case markUnwatched
  case rename
  case move
  case trash
}

public struct PutioFileMenu: Equatable, Sendable {
  public struct Capabilities: Equatable, Sendable {
    public var canEdit: Bool
    public var canDownload: Bool
    public var vlcInstalled: Bool
    public var tracksWatched: Bool
    public var canShare: Bool

    public init(
      canEdit: Bool, canDownload: Bool, vlcInstalled: Bool, tracksWatched: Bool,
      canShare: Bool = false
    ) {
      self.canEdit = canEdit
      self.canDownload = canDownload
      self.vlcInstalled = vlcInstalled
      self.tracksWatched = tracksWatched
      self.canShare = canShare
    }
  }

  public let sections: [[PutioFileMenuRow]]

  public init(item: PutioFileItem, capabilities: Capabilities, isDownloaded: Bool = false) {
    let route = item.kind == .folder ? nil : PutioFileRoute(item: item)
    var playback: [PutioFileMenuRow] = []
    if let route, route.isPlayable {
      playback.append(.play)
      if capabilities.canDownload, route.supportsOfflineDownload { playback.append(.download) }
      if capabilities.vlcInstalled, route.supportsExternalPlayback {
        playback.append(.openInVLC)
      }
    }
    if capabilities.canShare, PutioFileShareSource(item: item, isDownloaded: isDownloaded) != nil {
      playback.append(.share)
    }
    var organize: [PutioFileMenuRow] = []
    var edit: [PutioFileMenuRow] = []
    var destructive: [PutioFileMenuRow] = []
    if capabilities.canEdit, !item.isShared {
      organize.append(.select)
      if capabilities.tracksWatched, item.kind == .video {
        organize.append(item.isWatched ? .markUnwatched : .markWatched)
      }
      edit = [.rename, .move]
      destructive = [.trash]
    }
    sections = [playback, organize, edit, destructive].filter { !$0.isEmpty }
  }

  public var trailingSwipe: [PutioFileMenuRow] {
    [PutioFileMenuRow.trash, .download].filter { contains($0) }
  }

  public var leadingSwipe: [PutioFileMenuRow] {
    [PutioFileMenuRow.move].filter { contains($0) }
  }

  public func contains(_ row: PutioFileMenuRow) -> Bool {
    sections.contains { $0.contains(row) }
  }
}

public enum PutioFileSelectionAction: String, Equatable, Sendable {
  case move
  case download
  case markWatched
  case markUnwatched
  case trash
}

public struct PutioFileSelectionMenu: Equatable, Sendable {
  public let actions: [PutioFileSelectionAction]

  public init(selected items: [PutioFileItem], canDownload: Bool, tracksWatched: Bool) {
    let routes = items.map { $0.kind == .folder ? nil : PutioFileRoute(item: $0) }
    let onlyPlayable = !routes.isEmpty && routes.allSatisfy { $0?.isPlayable == true }
    var actions: [PutioFileSelectionAction] = [.move]
    if onlyPlayable {
      if canDownload, routes.allSatisfy({ $0?.supportsOfflineDownload == true }) {
        actions.append(.download)
      }
      if tracksWatched, items.allSatisfy({ $0.kind == .video }) {
        actions.append(items.allSatisfy(\.isWatched) ? .markUnwatched : .markWatched)
      }
    }
    actions.append(.trash)
    self.actions = actions
  }
}
