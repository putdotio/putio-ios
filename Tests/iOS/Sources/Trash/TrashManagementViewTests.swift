import Foundation
import PutioCore
import XCTest

@testable import Putio

@MainActor
final class TrashManagementViewTests: XCTestCase {
  func testRowsShowTheFilesGlyphSizeAndWhenTheItemIsGone() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let item = PutioTrashItem(
      id: PutioFileID(rawValue: 91),
      parentID: .root,
      name: "notes.txt",
      kind: .text,
      sizeBytes: 2_000,
      deletedAt: now.addingTimeInterval(-13 * 86_400),
      expiresAt: now.addingTimeInterval(12 * 86_400)
    )

    let locale = Locale(identifier: "en_US")
    let row = TrashManagementView.rowModel(
      for: item, relativeTo: now, locale: locale, calendar: calendar)

    XCTAssertEqual(row.kind, .text)
    XCTAssertEqual(row.sizeText, PutioFileRowModel.sizeText(bytes: 2_000, locale: locale))
    XCTAssertEqual(row.dateText, "Gone in 12 days")
    XCTAssertNil(row.secondaryText)
  }

  func testARestoringRowLeavesTheShownPageAndItsSize() {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let rows = [91, 92, 93].map { id in
      PutioTrashItem(
        id: PutioFileID(rawValue: id), parentID: .root, name: "\(id).mkv", kind: .video,
        sizeBytes: 2_048, deletedAt: now, expiresAt: now.addingTimeInterval(86_400))
    }
    let page = PutioTrashPage(items: rows, nextCursor: nil, totalCount: 3, sizeBytes: 6_144)

    let shown = TrashManagementView.shownPage(page, restoring: rows[1])

    XCTAssertEqual(shown.items, [rows[0], rows[2]])
    XCTAssertEqual(shown.sizeBytes, 4_096)
    XCTAssertEqual(shown.totalCount, 2)
    XCTAssertEqual(TrashManagementView.shownPage(page, restoring: nil), page)
  }
}
