import PutioCore
import SwiftUI

extension EnvironmentValues {
  @Entry var putioFolderScrollAnchors: PutioFolderScrollAnchors? = nil
}

@MainActor
final class PutioFolderScrollAnchors {
  private var offsets: [PutioFileID: CGFloat] = [:]

  func offset(for folderID: PutioFileID) -> CGFloat? {
    offsets[folderID]
  }

  func save(_ offset: CGFloat, for folderID: PutioFileID) {
    offsets[folderID] = offset
  }

  func keep(only folderIDs: Set<PutioFileID>) {
    offsets = offsets.filter { folderIDs.contains($0.key) }
  }
}
