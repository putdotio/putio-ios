import Foundation

public enum PutioFileAction: Equatable, Sendable {
  case createFolder(name: String)
  case sort(folderID: PutioFileID, sort: PutioFolderSort)
  case rename(fileID: PutioFileID, oldName: String, newName: String)
  case delete(fileID: PutioFileID, name: String)
  case move(
    fileID: PutioFileID,
    name: String,
    sourceParentID: PutioFileID,
    destinationID: PutioFileID,
    destinationName: String
  )
  case setWatched(fileID: PutioFileID, parentID: PutioFileID, name: String, watched: Bool)
}

public struct PutioFileActionFailure: Equatable, Sendable {
  public let title: String
  public let message: String

  init?(action: PutioFileAction, error: Error) {
    guard let browserFailure = PutioBrowserErrorPresentation(error: error) else {
      return nil
    }
    switch action {
    case .createFolder:
      title = String(localized: "Could not create folder", bundle: .module)
    case .rename:
      title = String(localized: "Could not rename item", bundle: .module)
    case .delete:
      title = String(localized: "Could not remove item", bundle: .module)
    case .move:
      title = String(localized: "Could not move item", bundle: .module)
    case .sort:
      title = String(localized: "Could not change sorting", bundle: .module)
    case .setWatched:
      title = String(localized: "Could not update watch status", bundle: .module)
    }
    message = browserFailure.message
  }
}

public enum PutioFileActionOutcome: Equatable, Sendable {
  case succeeded(PutioFileAction)
  case failed(PutioFileAction, PutioFileActionFailure)
}

public enum PutioBulkFileAction: Equatable, Sendable {
  case delete
  case move(destination: PutioFolderRoute)
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

  public func retryableItems(in currentItems: [PutioFileItem]) -> [PutioFileItem] {
    let currentItemsByID = Dictionary(uniqueKeysWithValues: currentItems.map { ($0.id, $0) })
    return failures.compactMap { currentItemsByID[$0.item.id] }
  }
}

public enum PutioBulkRetryPreparation: Equatable, Sendable {
  case ready([PutioFileItem])
  case failed
}
