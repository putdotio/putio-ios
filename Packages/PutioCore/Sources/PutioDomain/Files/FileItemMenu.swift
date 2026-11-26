import Foundation

public enum PutioFileMenuRow: String, Hashable, Sendable {
  case open
  case play
  case startOver
  case playWithOtherMethod
  case download
  case downloadWithOtherMethod
  case openInVLC
  case share
  case select
  case pin
  case unpin
  case markWatched
  case markUnwatched
  case rename
  case move
  case exclusiveLink
  case trash
  case makeCopy
}

public struct PutioFileMenu: Equatable, Sendable {
  public struct Capabilities: Equatable, Sendable {
    public var canEdit: Bool
    public var canDownload: Bool
    public var vlcInstalled: Bool
    public var tracksWatched: Bool
    public var canShare: Bool
    public var canLink: Bool
    public var canCopy: Bool
    /// Whether the item is pinned; `nil` leaves Pin and Unpin out.
    public var pinned: Bool?
    /// The method a video's "Play with" and "Download with" rows name: the
    /// one that is not the account's. `nil` leaves both rows out.
    public var otherPlaybackMethod: PutioPlaybackMethod?
    public var canSelect = true
    /// A panel lists Open for folders and Start over for started videos.
    public var isPanel = false

    /// Apple TV's panel: no selection, downloads, sharing, links or copies;
    /// Open in VLC is always offered.
    public static func tv(tracksWatched: Bool, pinned: Bool?) -> Capabilities {
      var capabilities = Capabilities(
        canEdit: true, canDownload: false, vlcInstalled: true, tracksWatched: tracksWatched,
        pinned: pinned)
      capabilities.canSelect = false
      capabilities.isPanel = true
      return capabilities
    }

    public init(
      canEdit: Bool, canDownload: Bool, vlcInstalled: Bool, tracksWatched: Bool,
      canShare: Bool = false, canLink: Bool = false, canCopy: Bool = false, pinned: Bool? = nil,
      otherPlaybackMethod: PutioPlaybackMethod? = nil
    ) {
      self.canEdit = canEdit
      self.canDownload = canDownload
      self.vlcInstalled = vlcInstalled
      self.tracksWatched = tracksWatched
      self.canShare = canShare
      self.canLink = canLink
      self.pinned = pinned
      self.canCopy = canCopy
      self.otherPlaybackMethod = otherPlaybackMethod
    }
  }

  public let sections: [[PutioFileMenuRow]]

  public init(item: PutioFileItem, capabilities: Capabilities, isDownloaded: Bool = false) {
    guard !(item.isShared && item.kind == .folder) else {
      sections = capabilities.pinned == true ? [[.unpin]] : []
      return
    }
    let route = item.kind == .folder ? nil : PutioFileRoute(item: item)
    var playback: [PutioFileMenuRow] = []
    if capabilities.isPanel, item.kind == .folder { playback.append(.open) }
    if let route, route.isPlayable {
      playback.append(.play)
      if capabilities.isPanel, item.kind == .video, item.resumePositionSeconds > 0 {
        playback.append(.startOver)
      }
      if capabilities.otherPlaybackMethod != nil, item.kind == .video {
        playback.append(.playWithOtherMethod)
      }
      if capabilities.canDownload, route.supportsOfflineDownload {
        playback.append(.download)
        if capabilities.otherPlaybackMethod != nil, item.kind == .video {
          playback.append(.downloadWithOtherMethod)
        }
      }
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
    let editable = capabilities.canEdit && !item.isShared
    if editable, capabilities.canSelect { organize.append(.select) }
    if let pinned = capabilities.pinned, pinned || !item.isShared {
      organize.append(pinned ? .unpin : .pin)
    }
    if editable {
      if capabilities.tracksWatched, item.kind == .video {
        organize.append(item.isWatched ? .markUnwatched : .markWatched)
      }
      edit = capabilities.canLink ? [.rename, .move, .exclusiveLink] : [.rename, .move]
      destructive = [.trash]
    }
    let copy: [PutioFileMenuRow] = capabilities.canCopy && item.isShared ? [.makeCopy] : []
    sections = [playback, copy, organize, edit, destructive].filter { !$0.isEmpty }
  }

  private init(sections: [[PutioFileMenuRow]]) {
    self.sections = sections
  }

  /// The long-press menu of a row in the Pinned section.
  public static func pinnedRow(
    item: PutioFileItem, canEdit: Bool, canLink: Bool = false
  ) -> PutioFileMenu {
    guard canEdit, !item.isShared else { return PutioFileMenu(sections: [[.unpin]]) }
    return PutioFileMenu(sections: [[.unpin], canLink ? [.move, .exclusiveLink] : [.move]])
  }

  /// A search result's menu: the item menu without Select, Rename and Trash.
  public static func searchResult(
    item: PutioFileItem, capabilities: Capabilities, isDownloaded: Bool = false
  ) -> PutioFileMenu {
    let excluded: Set<PutioFileMenuRow> = [.select, .rename, .trash]
    let full = PutioFileMenu(item: item, capabilities: capabilities, isDownloaded: isDownloaded)
    return PutioFileMenu(
      sections: full.sections.map { $0.filter { !excluded.contains($0) } }.filter { !$0.isEmpty })
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

  public func itemMenu(_ actions: [PutioFileMenuRow: PutioItemAction]) -> PutioItemMenu {
    PutioItemMenu(
      sections.map { section in
        section.compactMap { row in
          if let primary = Self.variants.first(where: { $0.value == row })?.key,
            actions[primary] != nil
          {
            return nil
          }
          guard let action = actions[row] else { return nil }
          guard let variant = Self.variants[row].flatMap({ actions[$0] }) else { return action }
          return PutioItemAction(
            submenu: "\(action.id)-menu", title: action.title, icon: action.icon,
            children: [action, variant])
        }
      })
  }

  private static let variants: [PutioFileMenuRow: PutioFileMenuRow] = [
    .play: .playWithOtherMethod, .download: .downloadWithOtherMethod,
  ]
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
