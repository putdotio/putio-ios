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
  private(set) var ids: Set<PutioFileID> = []

  func appear(_ id: PutioFileID) { ids.insert(id) }

  func disappear(_ id: PutioFileID) { ids.remove(id) }

  func topmost(in items: [PutioFileItem]) -> PutioFileID? {
    guard let first = items.first(where: { ids.contains($0.id) }), first.id != items.first?.id
    else { return nil }
    return first.id
  }
}
