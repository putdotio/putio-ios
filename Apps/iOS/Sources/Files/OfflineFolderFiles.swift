import PutioCore
import UIKit

enum PutioOfflineFileStatus: Equatable {
  case remote
  case queued
  case onDevice
}

@MainActor
struct PutioOfflineFolderFiles {
  let items: (PutioFileID) -> [PutioFileItem]
  let open: (PutioFileID) -> Void
  let status: (PutioFileID) -> PutioOfflineFileStatus
  let downloadState: (PutioFileID) -> PutioDownloadState
  let isOnDevice: (PutioFileID) -> Bool
  let perform: (PutioDownloadAction, PutioFileID) -> Void

  init(queue: PutioOfflineQueue, open: @escaping (PutioOfflineItem) -> Void) {
    let device: PutioDownloadDevice = UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone
    downloadState = { queue.downloadState(for: $0, on: device) }
    isOnDevice = { queue.item(for: $0)?.stage == .completed }
    perform = { queue.perform($0, fileID: $1) }
    items = { folderID in
      queue.items
        .filter { $0.parentID == folderID && $0.isPlayable }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        .map(\.folderFileItem)
    }
    status = { fileID in
      guard let item = queue.item(for: fileID) else { return .remote }
      return item.isPlayable ? .onDevice : .queued
    }
    self.open = { fileID in
      guard let item = queue.item(for: fileID), item.isPlayable else { return }
      open(item)
    }
  }
}

extension PutioOfflineItem {
  fileprivate var folderFileItem: PutioFileItem {
    PutioFileItem(
      id: id,
      parentID: parentID,
      name: name,
      kind: kind == .audio ? .audio : .video,
      sizeBytes: storedBytes,
      createdAt: createdAt,
      updatedAt: createdAt,
      resumePositionSeconds: pendingPositionSeconds ?? resumePositionSeconds
    )
  }
}
