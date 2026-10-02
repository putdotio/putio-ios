import Foundation
import PutioCore
import XCTest

@testable import Putio

@MainActor
final class TrashManagementViewTests: XCTestCase {
  func testRowsShowWhenTheItemWasDeletedAndWhenItExpires() throws {
    let deletedAt = Date(timeIntervalSince1970: 1_790_000_000)
    let item = PutioTrashItem(
      id: PutioFileID(rawValue: 91),
      parentID: .root,
      name: "Old.mkv",
      kind: .video,
      sizeBytes: 2_048,
      deletedAt: deletedAt,
      expiresAt: deletedAt.addingTimeInterval(14 * 86_400)
    )
    let locale = Locale(identifier: "en_US")

    let row = TrashManagementView.rowModel(
      for: item, relativeTo: deletedAt.addingTimeInterval(3 * 86_400), locale: locale)

    let size = PutioFileRowModel.sizeText(bytes: item.sizeBytes, locale: locale)
    XCTAssertEqual(row.sizeText, "\(size) · Deleted 3 days ago")
    let expiry = item.expiresAt.formatted(Date.FormatStyle(locale: locale).month(.wide).day())
    XCTAssertEqual(row.secondaryText, "Expires on \(expiry)")
  }
}
