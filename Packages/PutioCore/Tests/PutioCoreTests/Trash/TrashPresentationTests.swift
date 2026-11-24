import Foundation
import XCTest

@testable import PutioCore

final class TrashPresentationTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_790_000_000)

  private func item(_ id: Int, name: String = "notes.txt") -> PutioTrashItem {
    PutioTrashItem(
      id: PutioFileID(rawValue: id), parentID: .root, name: name, kind: .text, sizeBytes: 2_000,
      deletedAt: now.addingTimeInterval(-13 * 86_400),
      expiresAt: now.addingTimeInterval(12 * 86_400))
  }

  func testRowsShowTheFilesGlyphSizeAndWhenTheItemIsGone() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
    let locale = Locale(identifier: "en_US")

    let row = item(91).rowModel(relativeTo: now, locale: locale, calendar: calendar)

    XCTAssertEqual(row.kind, .text)
    XCTAssertEqual(row.sizeText, PutioFileRowModel.sizeText(bytes: 2_000, locale: locale))
    XCTAssertEqual(row.dateText, "Gone in 12 days")
    XCTAssertNil(row.secondaryText)
  }

  func testOutcomesReadAsTheirToasts() {
    let one = item(1, name: "Delete Me")
    let failure = PutioTrashErrorPresentation(title: "Could not restore", message: "Try again.")
    let cases: [(PutioTrashMutationOutcome, PutioTrashNotice)] = [
      (.restored(one), .done("Restore started")),
      (.restoredItems([one]), .done("Restore started")),
      (.restoredAll, .done("Restore started")),
      (.permanentlyDeleted(one), .done("“Delete Me” is no longer in trash.")),
      (.permanentlyDeletedItems([one]), .done("1 item is no longer in trash.")),
      (.permanentlyDeletedItems([one, item(2)]), .done("2 items are no longer in trash.")),
      (.emptied(), .done("Trash is empty.")),
      (.failed(.permanentlyDelete(one), failure), .failed("The request could not start")),
      (.failed(.permanentlyDeleteItems([one]), failure), .failed("The request could not start")),
      (.failed(.empty, failure), .failed("The request could not start")),
      (.failed(.restore(one), failure), .failed("Restore could not start")),
      (.failed(.restoreAll, failure), .failed("Restore could not start")),
      (
        .failed(.restoreItems([one, item(2)]), failure),
        .restoreFailed("Couldn’t restore 2 items from trash", items: [one, item(2)])
      ),
    ]
    for (outcome, notice) in cases {
      XCTAssertEqual(outcome.notice, notice, "\(outcome)")
    }
  }

  func testAnItemStillMovingToTrashExplainsWhyRestoreCannotStart() throws {
    let stillMoving = try XCTUnwrap(
      PutioTrashErrorPresentation(title: "Could not restore", error: PutioTrashStillMoving()))
    for mutation in [PutioTrashMutation.restore(item(1)), .restoreItems([item(1)])] {
      XCTAssertEqual(
        PutioTrashMutationOutcome.failed(mutation, stillMoving).notice,
        .stillMoving(
          title: "Restore could not start",
          message: "This item is still moving to trash. You can try restoring it later."))
    }
  }
}
