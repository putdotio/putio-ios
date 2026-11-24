import Foundation

public enum PutioFileMenuStyle: Sendable {
  /// iOS menus and swipes.
  case menu
  /// Apple TV's detail panel, whose pins show on Home.
  case panel
}

extension PutioFileMenuRow {
  /// The row's title. "Play with" and "Download with" name a playback
  /// method, so the screen titles them.
  public func title(
    for item: PutioFileItem, style: PutioFileMenuStyle = .menu, trashEnabled: Bool
  ) -> String? {
    switch self {
    case .open: String(localized: "Open", bundle: .module)
    case .play:
      if style == .panel, item.resumePositionSeconds > 0 {
        String(
          localized:
            "Resume from \(PutioFileDetailText.clock(seconds: item.resumePositionSeconds))",
          bundle: .module)
      } else {
        String(localized: "Play", bundle: .module)
      }
    case .startOver: String(localized: "Start over", bundle: .module)
    case .playWithOtherMethod, .downloadWithOtherMethod: nil
    case .download: String(localized: "Download", bundle: .module)
    case .openInVLC: String(localized: "Open in VLC", bundle: .module)
    case .share: String(localized: "Share", bundle: .module)
    case .select: String(localized: "Select", bundle: .module)
    case .pin:
      style == .panel
        ? String(localized: "Pin to Home", bundle: .module)
        : String(localized: "Pin", bundle: .module)
    case .unpin:
      style == .panel
        ? String(localized: "Unpin from Home", bundle: .module)
        : String(localized: "Unpin", bundle: .module)
    case .markWatched: String(localized: "Mark as watched", bundle: .module)
    case .markUnwatched: String(localized: "Mark as unwatched", bundle: .module)
    case .rename: String(localized: "Rename", bundle: .module)
    case .move: String(localized: "Move", bundle: .module)
    case .exclusiveLink: String(localized: "Exclusive link", bundle: .module)
    case .trash: PutioFileDeletionPresentation(trashEnabled: trashEnabled).actionTitle
    case .makeCopy: String(localized: "Make a copy", bundle: .module)
    }
  }

  public var icon: PutioIcon {
    switch self {
    case .open: .caretRight
    case .play, .playWithOtherMethod: .play
    case .startOver: .arrowCounterClockwise
    case .download, .downloadWithOtherMethod: .arrowCircleDown
    case .openInVLC: .trafficCone
    case .share: .export
    case .select: .checkCircle
    case .pin: .pushPin
    case .unpin: .pushPinSlash
    case .markWatched: .eye
    case .markUnwatched: .eyeSlash
    case .rename: .pencilSimple
    case .move: .folderSimpleDashed
    case .exclusiveLink: .link
    case .trash: .trash
    case .makeCopy: .copy
    }
  }

  public var isDestructive: Bool { self == .trash }
}

/// A row that edits the item: what it asks the screen to do next.
public enum PutioFileItemActionRequest: Equatable, Identifiable, Sendable {
  case rename(PutioFileItem)
  case move(PutioFileItem)
  case delete(PutioFileItem)
  case setWatched(PutioFileItem, Bool)

  public init?(row: PutioFileMenuRow, item: PutioFileItem) {
    switch row {
    case .rename: self = .rename(item)
    case .move: self = .move(item)
    case .trash: self = .delete(item)
    case .markWatched: self = .setWatched(item, true)
    case .markUnwatched: self = .setWatched(item, false)
    default: return nil
    }
  }

  public var id: String {
    switch self {
    case .rename(let item): "rename.\(item.id.rawValue)"
    case .move(let item): "move.\(item.id.rawValue)"
    case .delete(let item): "delete.\(item.id.rawValue)"
    case .setWatched(let item, let watched): "watched.\(item.id.rawValue).\(watched)"
    }
  }

  public enum Step: Equatable, Sendable {
    case askForName(PutioFileItem)
    case pickDestination(PutioFileItem)
    /// Trash is recoverable, so it runs at once.
    case trash(PutioFileItem)
    /// A permanent delete asks first.
    case confirmPermanentDelete(PutioFileItem)
    case setWatched(PutioFileItem, Bool)
  }

  public func step(trashEnabled: Bool) -> Step {
    switch self {
    case .rename(let item): .askForName(item)
    case .move(let item): .pickDestination(item)
    case .delete(let item): trashEnabled ? .trash(item) : .confirmPermanentDelete(item)
    case .setWatched(let item, let watched): .setWatched(item, watched)
    }
  }
}
