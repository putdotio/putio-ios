import Foundation

extension PutioFolderContents {
  /// Where focus goes when a row leaves the list: the row after it, or the
  /// one before it at the end. A removal reloads only the first page, so the
  /// target must be a row in `firstPage`; on a later page that is the first
  /// page's last row.
  public static func neighbour(
    afterRemoving id: PutioFileID, from items: [PutioFileItem], firstPage: Set<PutioFileID>
  ) -> PutioFileID? {
    guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
    let following = items[(index + 1)...]
    let preceding = items[..<index].reversed()
    return (following + preceding).first { firstPage.contains($0.id) }?.id
  }

  /// Where focus goes when a row stays but the list reloads its first page:
  /// the row itself if that page holds it, otherwise that page's last row.
  public static func neighbour(
    keeping id: PutioFileID, in items: [PutioFileItem], firstPage: Set<PutioFileID>
  ) -> PutioFileID? {
    firstPage.contains(id) ? id : neighbour(afterRemoving: id, from: items, firstPage: firstPage)
  }
}
