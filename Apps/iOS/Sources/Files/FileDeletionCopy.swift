import Foundation
import PutioCore

/// Files wording for removing items, which names what happens: a move to
/// Trash or a delete that cannot be undone.
struct PutioFileDeletionCopy {
  let trashEnabled: Bool

  var actionTitle: String {
    trashEnabled ? String(localized: "Move to trash") : Self.deletePermanently
  }

  static var deletePermanently: String { String(localized: "Delete permanently") }

  static var settingUnknown: String { String(localized: "Waiting for confirmed trash settings.") }

  static var trashed: String { String(localized: "Moved to trash") }

  static var deleted: String { String(localized: "Item deleted") }

  static var undo: String { String(localized: "Undo") }

  static func permanentDeleteAlert(
    itemCount: Int, confirm: @escaping @MainActor @Sendable () -> Void
  ) -> PutioConfirmAlert {
    PutioConfirmAlert(
      title: String(localized: "Delete \(itemCount) items permanently?"),
      message: String(localized: "Trash is off for this account, so this can’t be undone."),
      confirmTitle: String(localized: "Delete"),
      confirm: confirm)
  }

  static func trashLimitAlert(
    confirm: @escaping @MainActor @Sendable () -> Void
  ) -> PutioConfirmAlert {
    PutioConfirmAlert(
      title: String(localized: "We couldn’t send these files to trash"),
      message: String(localized: "This folder contains too many files. Delete it permanently?"),
      confirmTitle: deletePermanently,
      confirm: confirm)
  }
}
