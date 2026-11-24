import Foundation

public struct PutioFileDeletionPresentation: Equatable, Sendable {
  let trashEnabled: Bool

  public init(trashEnabled: Bool) {
    self.trashEnabled = trashEnabled
  }

  public var actionTitle: String {
    trashEnabled ? String(localized: "Move to trash", bundle: .module) : Self.deletePermanently
  }

  public static var deletePermanently: String {
    String(localized: "Delete permanently", bundle: .module)
  }

  public static var settingUnknown: String {
    String(localized: "Waiting for confirmed trash settings.", bundle: .module)
  }

  public static var trashed: String { String(localized: "Moved to trash", bundle: .module) }

  public static var deleted: String { String(localized: "Item deleted", bundle: .module) }

  public static var undo: String { String(localized: "Undo", bundle: .module) }

  public var singleFailureTitle: String {
    trashEnabled
      ? String(localized: "Could not move item to Trash", bundle: .module)
      : String(localized: "Could not delete item", bundle: .module)
  }

  public static func permanentDeleteAlert(
    itemCount: Int, confirm: @escaping @MainActor @Sendable () -> Void
  ) -> PutioConfirmAlert {
    PutioConfirmAlert(
      title: String(localized: "Delete \(itemCount) items permanently?", bundle: .module),
      message: String(
        localized: "Trash is off for this account, so this can’t be undone.", bundle: .module),
      confirmTitle: String(localized: "Delete", bundle: .module),
      confirm: confirm)
  }

  public static func trashLimitAlert(
    confirm: @escaping @MainActor @Sendable () -> Void
  ) -> PutioConfirmAlert {
    PutioConfirmAlert(
      title: String(localized: "We couldn’t send these files to trash", bundle: .module),
      message: String(
        localized: "This folder contains too many files. Delete it permanently?",
        bundle: .module),
      confirmTitle: deletePermanently,
      confirm: confirm)
  }

  public func progressTitle(currentItem: Int, totalItems: Int) -> String {
    if trashEnabled {
      return String(
        localized: "Moving item \(currentItem) of \(totalItems) to Trash…", bundle: .module)
    }
    return String(
      localized: "Deleting item \(currentItem) of \(totalItems)…", bundle: .module)
  }

  public func failureTitle(allItemsFailed: Bool) -> String {
    switch (trashEnabled, allItemsFailed) {
    case (true, true):
      String(localized: "Could not move items to Trash", bundle: .module)
    case (true, false):
      String(localized: "Some items couldn’t be moved to Trash", bundle: .module)
    case (false, true):
      String(localized: "Could not delete items", bundle: .module)
    case (false, false):
      String(localized: "Some items couldn’t be deleted", bundle: .module)
    }
  }

  public func outcomeMessage(succeeded: Int, failed: Int) -> String {
    let successText =
      trashEnabled
      ? String(localized: "Moved \(succeeded) items to Trash.", bundle: .module)
      : String(localized: "Deleted \(succeeded) items.", bundle: .module)
    guard failed > 0 else { return successText }
    let failureText =
      trashEnabled
      ? String(localized: "\(failed) couldn’t be moved to Trash.", bundle: .module)
      : String(localized: "\(failed) couldn’t be deleted.", bundle: .module)
    return "\(successText) \(failureText)"
  }
}
