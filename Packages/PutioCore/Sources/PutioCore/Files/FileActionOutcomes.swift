import Foundation

public enum PutioFileAction: Equatable, Sendable {
  case createFolder(name: String)
  case sort(folderID: PutioFileID, sort: PutioFolderSort)
  case rename(fileID: PutioFileID, oldName: String, newName: String)
  case delete(fileID: PutioFileID, name: String, permanently: Bool = false)
  case move(
    fileID: PutioFileID,
    name: String,
    sourceParentID: PutioFileID,
    destinationID: PutioFileID,
    destinationName: String
  )
  case setWatched(fileID: PutioFileID, parentID: PutioFileID, name: String, watched: Bool)
  case restore(fileIDs: [PutioFileID])
}

/// put.io refused a move because the destination already holds an item with
/// the moved item's name.
public struct PutioMoveNameTaken: Error, Equatable, Sendable {}

public struct PutioTrashChildrenLimit: Error, Equatable, Sendable {}

public struct PutioFileActionFailure: Equatable, Sendable {
  public let title: String
  public let message: String
  public let isNameTaken: Bool
  public let isTrashLimit: Bool

  init?(action: PutioFileAction, error: Error) {
    guard let browserFailure = PutioBrowserErrorPresentation(error: error) else {
      return nil
    }
    switch action {
    case .createFolder:
      title = String(localized: "Couldn’t create folder.", bundle: .module)
    case .rename:
      title = String(localized: "Could not rename item", bundle: .module)
    case .delete:
      title = String(localized: "Could not remove item", bundle: .module)
    case .move:
      title = String(localized: "Could not move item", bundle: .module)
    case .sort:
      title = String(localized: "Couldn’t change sorting.", bundle: .module)
    case .setWatched:
      title = String(localized: "Could not update watch status", bundle: .module)
    case .restore:
      title = String(localized: "Could not restore item", bundle: .module)
    }
    message = browserFailure.message
    isNameTaken = error is PutioMoveNameTaken
    isTrashLimit = error is PutioTrashChildrenLimit
  }
}

public enum PutioFileActionOutcome: Equatable, Sendable {
  case succeeded(PutioFileAction)
  case failed(PutioFileAction, PutioFileActionFailure)

  public var action: PutioFileAction {
    switch self {
    case .succeeded(let action), .failed(let action, _): action
    }
  }

  /// The toast an outcome shows, or `nil` when the screen already shows it.
  public func toastTitle(trashEnabled: Bool) -> String? {
    switch self {
    case .succeeded(.delete(_, _, let permanently)):
      trashEnabled && !permanently
        ? PutioFileDeletionPresentation.trashed : PutioFileDeletionPresentation.deleted
    case .succeeded(.move):
      PutioMoveCopy.moved(1)
    case .succeeded(.setWatched(_, _, _, let watched)):
      PutioFileActionCopy.watchStatus(watched)
    case .succeeded(.createFolder), .succeeded(.rename), .succeeded(.sort),
      .succeeded(.restore):
      nil
    case .failed(.delete(_, _, let permanently), _):
      PutioFileDeletionPresentation(trashEnabled: trashEnabled && !permanently)
        .singleFailureTitle
    case .failed(_, let failure):
      failure.title
    }
  }

  public func isNameTaken(movingFileID id: PutioFileID) -> Bool {
    guard case .failed(.move(let fileID, _, _, _, _), let failure) = self else { return false }
    return fileID == id && failure.isNameTaken
  }
}

public enum PutioMoveCopy {
  public static func moved(_ count: Int) -> String {
    String(localized: "\(count) items are in the selected folder.", bundle: .module)
  }

  public static func moved(to folder: String) -> String {
    String(localized: "Moved to \(folder)", bundle: .module)
  }
}

public enum PutioFileActionCopy {
  public static func watchStatus(_ watched: Bool) -> String {
    watched
      ? String(localized: "Marked as watched", bundle: .module)
      : String(localized: "Marked as unwatched", bundle: .module)
  }
}

public enum PutioBulkFileAction: Equatable, Sendable {
  case delete
  case move(destination: PutioFolderRoute)
  case setWatched(Bool)
}

public struct PutioBulkFileProgress: Equatable, Sendable {
  public let action: PutioBulkFileAction
  public let completedCount: Int
  public let totalCount: Int
  public let currentItem: PutioFileItem
}

public struct PutioBulkFileItemFailure: Equatable, Sendable {
  public let item: PutioFileItem
  let error: PutioRuntimeError
  let presentation: PutioFileActionFailure?
}

public struct PutioBulkFileOutcome: Equatable, Sendable {
  public let action: PutioBulkFileAction
  public let succeeded: [PutioFileItem]
  public let failures: [PutioBulkFileItemFailure]

  public var completedCount: Int {
    succeeded.count + failures.count
  }

  public func retryableItems(
    in currentItems: [PutioFileItem], listingIsComplete: Bool = true
  ) -> [PutioFileItem] {
    let currentItemsByID = Dictionary(uniqueKeysWithValues: currentItems.map { ($0.id, $0) })
    return failures.compactMap {
      currentItemsByID[$0.item.id] ?? (listingIsComplete ? nil : $0.item)
    }
  }
}

public enum PutioBulkRetryPreparation: Equatable, Sendable {
  case ready([PutioFileItem])
  case failed
}
