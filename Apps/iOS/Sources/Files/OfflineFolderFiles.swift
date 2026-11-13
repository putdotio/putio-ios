import Foundation
import PutioCore

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

  init(queue: PutioOfflineQueue, open: @escaping (PutioOfflineItem) -> Void) {
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
