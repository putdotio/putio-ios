import PutioCore
import SwiftUI

extension EnvironmentValues {
  @Entry var putioFolderScrollAnchors: PutioFolderScrollAnchors? = nil
}

@MainActor
final class PutioFolderScrollAnchors {
  private var anchors: [PutioFileID: PutioFileID] = [:]

  func anchor(for folderID: PutioFileID) -> PutioFileID? {
    anchors[folderID]
  }

  func save(_ itemID: PutioFileID?, for folderID: PutioFileID) {
    anchors[folderID] = itemID
  }

  func keep(only folderIDs: Set<PutioFileID>) {
    anchors = anchors.filter { folderIDs.contains($0.key) }
  }
}

@MainActor
final class PutioVisibleRows {
  private var ids: Set<PutioFileID> = []

  func appear(_ id: PutioFileID) { ids.insert(id) }

  func disappear(_ id: PutioFileID) { ids.remove(id) }

  func topmost(in items: [PutioFileItem]) -> PutioFileID? {
    items.first { ids.contains($0.id) }?.id
  }
}
