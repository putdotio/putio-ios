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

    XCTAssertEqual(row.kind, .file)
    XCTAssertEqual(row.sizeText, PutioFileRowModel.sizeText(bytes: 2_000, locale: locale))
    XCTAssertEqual(row.dateText, "Gone in 12 days")
    XCTAssertNil(row.secondaryText)
  }
}
