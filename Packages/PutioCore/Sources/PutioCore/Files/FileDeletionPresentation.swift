import Foundation

public struct PutioFileDeletionPresentation: Equatable, Sendable {
  let trashEnabled: Bool

  public init(trashEnabled: Bool) {
    self.trashEnabled = trashEnabled
  }

  public var actionTitle: String {
    trashEnabled
      ? String(localized: "Trash", bundle: .module)
      : String(localized: "Delete", bundle: .module)
  }

  public var singleSuccessTitle: String {
    trashEnabled
      ? String(localized: "Moved to Trash", bundle: .module)
      : String(localized: "Item deleted", bundle: .module)
  }

  public var singleFailureTitle: String {
    trashEnabled
      ? String(localized: "Could not move item to Trash", bundle: .module)
      : String(localized: "Could not delete item", bundle: .module)
  }

  public func confirmationTitle(itemName: String) -> String {
    if trashEnabled {
      return String(
        localized: "Move “\(itemName)” to Trash?", bundle: .module)
    }
    return String(
      localized: "Delete “\(itemName)” permanently?", bundle: .module)
  }

  public func confirmationTitle(itemCount: Int) -> String {
    if trashEnabled {
      return String(
        localized: "Move \(itemCount) items to Trash?", bundle: .module)
    }
    return String(
      localized: "Delete \(itemCount) items permanently?", bundle: .module)
  }

  public func confirmationMessage(itemCount: Int) -> String {
    if trashEnabled {
      return itemCount == 1
        ? String(localized: "You can restore this item from Trash.", bundle: .module)
        : String(localized: "You can restore these items from Trash.", bundle: .module)
    }
    return itemCount == 1
      ? String(localized: "This item cannot be restored.", bundle: .module)
      : String(localized: "These items cannot be restored.", bundle: .module)
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
