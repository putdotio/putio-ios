import Foundation

public struct PutioFileDeletionPresentation: Equatable, Sendable {
  let trashEnabled: Bool

  public init(trashEnabled: Bool) {
    self.trashEnabled = trashEnabled
  }

  public var actionTitle: String {
    trashEnabled
      ? String(localized: "Trash", comment: "File action that moves an item to Trash")
      : String(localized: "Delete", comment: "File action that permanently deletes an item")
  }

  public var singleSuccessTitle: String {
    trashEnabled
      ? String(localized: "Moved to Trash", comment: "File action success title")
      : String(localized: "Item deleted", comment: "Permanent file deletion success title")
  }

  public var bulkSuccessTitle: String {
    trashEnabled
      ? String(localized: "Items moved to Trash", comment: "Bulk file action success title")
      : String(localized: "Items deleted", comment: "Bulk permanent deletion success title")
  }

  public var singleFailureTitle: String {
    trashEnabled
      ? String(localized: "Could not move item to Trash", comment: "File action failure title")
      : String(localized: "Could not delete item", comment: "Permanent deletion failure title")
  }

  public func confirmationTitle(itemName: String) -> String {
    if trashEnabled {
      return String(
        localized: "Move “\(itemName)” to Trash?",
        comment: "Confirmation title for moving one file to Trash"
      )
    }
    return String(
      localized: "Delete “\(itemName)” permanently?",
      comment: "Confirmation title for permanently deleting one file"
    )
  }

  public func confirmationTitle(itemCount: Int) -> String {
    if trashEnabled {
      return String(
        localized: "Move \(itemCount) \(itemNoun(itemCount)) to Trash?",
        comment: "Confirmation title for moving selected files to Trash"
      )
    }
    return String(
      localized: "Delete \(itemCount) \(itemNoun(itemCount)) permanently?",
      comment: "Confirmation title for permanently deleting selected files"
    )
  }

  public func confirmationMessage(itemCount: Int) -> String {
    if trashEnabled {
      return itemCount == 1
        ? String(localized: "You can restore this item from Trash.")
        : String(localized: "You can restore these items from Trash.")
    }
    return itemCount == 1
      ? String(localized: "This item cannot be restored.")
      : String(localized: "These items cannot be restored.")
  }

  public func progressTitle(currentItem: Int, totalItems: Int) -> String {
    if trashEnabled {
      return String(
        localized: "Moving item \(currentItem) of \(totalItems) to Trash…",
        comment: "Progress title for a bulk Trash action"
      )
    }
    return String(
      localized: "Deleting item \(currentItem) of \(totalItems)…",
      comment: "Progress title for bulk permanent deletion"
    )
  }

  public func failureTitle(allItemsFailed: Bool) -> String {
    switch (trashEnabled, allItemsFailed) {
    case (true, true):
      String(localized: "Could not move items to Trash")
    case (true, false):
      String(localized: "Some items couldn’t be moved to Trash")
    case (false, true):
      String(localized: "Could not delete items")
    case (false, false):
      String(localized: "Some items couldn’t be deleted")
    }
  }

  public func outcomeMessage(succeeded: Int, failed: Int) -> String {
    let successText =
      trashEnabled
      ? String(localized: "Moved \(succeeded) \(itemNoun(succeeded)) to Trash.")
      : String(localized: "Deleted \(succeeded) \(itemNoun(succeeded)).")
    guard failed > 0 else { return successText }
    let failureText =
      trashEnabled
      ? String(localized: "\(failed) couldn’t be moved to Trash.")
      : String(localized: "\(failed) couldn’t be deleted.")
    return "\(successText) \(failureText)"
  }

  private func itemNoun(_ count: Int) -> String {
    count == 1 ? String(localized: "item") : String(localized: "items")
  }
}
