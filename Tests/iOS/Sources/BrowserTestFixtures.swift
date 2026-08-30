import Foundation
import PutioCore

enum BrowserTestFixtures {
  static let referenceDate = Date(timeIntervalSince1970: 1_777_464_000)

  static func item(
    id: Int,
    parentID: Int = 0,
    name: String? = nil,
    kind: PutioFileKind = .video,
    sizeBytes: Int64 = 1_024,
    updatedAt: Date? = nil,
    resumePositionSeconds: Int = 0
  ) -> PutioFileItem {
    PutioFileItem(
      id: PutioFileID(rawValue: id),
      parentID: PutioFileID(rawValue: parentID),
      name: name ?? "File \(id)",
      kind: kind,
      sizeBytes: sizeBytes,
      createdAt: referenceDate.addingTimeInterval(-172_800),
      updatedAt: updatedAt ?? referenceDate.addingTimeInterval(-86_400),
      resumePositionSeconds: resumePositionSeconds
    )
  }

  static func contents(
    folderID: Int = 0,
    items: [PutioFileItem],
    hasMore: Bool = false
  ) -> PutioFolderContents {
    PutioFolderContents(
      folder: item(
        id: folderID,
        parentID: 0,
        name: folderID == 0 ? "Files" : "Folder \(folderID)",
        kind: .folder,
        sizeBytes: 0
      ),
      items: items,
      hasMore: hasMore
    )
  }
}
