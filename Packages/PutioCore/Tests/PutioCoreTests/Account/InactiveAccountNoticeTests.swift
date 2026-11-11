import Foundation
import PutioSDK
import XCTest

@testable import PutioCore

final class InactiveAccountNoticeTests: XCTestCase {
  private let deletion = Date(timeIntervalSince1970: 1_792_051_200)

  func testActiveAndStrangerAccountsSeeNoNotice() {
    XCTAssertNil(PutioInactiveAccountNotice(account: account(.active, deletion: deletion)))
    XCTAssertNil(PutioInactiveAccountNotice(account: account(.stranger)))
  }

  func testInactiveOwnerKeepsTheDeletionDate() {
    XCTAssertEqual(
      PutioInactiveAccountNotice(account: account(.inactive, deletion: deletion)),
      .deactivated(filesDeletionDate: deletion))
    XCTAssertEqual(
      PutioInactiveAccountNotice(account: account(.inactive)),
      .deactivated(filesDeletionDate: nil))
  }

  func testInactiveFamilyMemberGetsTheFamilyNotice() {
    XCTAssertEqual(
      PutioInactiveAccountNotice(account: account(.inactive, subAccount: true, deletion: deletion)),
      .familyPlanExpired)
  }

  func testTitlesMatchTheBoards() {
    XCTAssertEqual(
      PutioInactiveAccountNotice.deactivated(filesDeletionDate: nil).title,
      "Your account has been deactivated 😢")
    XCTAssertEqual(
      PutioInactiveAccountNotice.familyPlanExpired.title, "Your family plan is no longer active.")
  }

  func testMessageUsesTheSingularForOneDay() {
    XCTAssertEqual(
      PutioInactiveAccountNotice.filesDeletionMessage(days: 12),
      "Your files are still here, but they are scheduled to be deleted in 12 days.")
    XCTAssertEqual(
      PutioInactiveAccountNotice.filesDeletionMessage(days: 1),
      "Your files are still here, but they are scheduled to be deleted in 1 day.")
  }

  func testDeletionDaysCountCalendarDaysInTheViewersZone() throws {
    let notice = PutioInactiveAccountNotice.deactivated(
      filesDeletionDate: try date("2026-10-15T01:00:00Z"))
    let now = try date("2026-10-01T22:00:00Z")

    XCTAssertEqual(notice.daysUntilFilesDeleted(now: now, calendar: try calendar(hours: 0)), 14)
    XCTAssertEqual(notice.daysUntilFilesDeleted(now: now, calendar: try calendar(hours: 3)), 13)
    XCTAssertEqual(
      notice.daysUntilFilesDeleted(now: try date("2026-10-15T23:00:00Z"), calendar: try calendar(hours: 0)),
      0)
    XCTAssertEqual(
      notice.daysUntilFilesDeleted(now: try date("2026-10-17T00:00:00Z"), calendar: try calendar(hours: 0)),
      2)
    XCTAssertNil(
      PutioInactiveAccountNotice.deactivated(filesDeletionDate: nil).daysUntilFilesDeleted(now: now))
    XCTAssertNil(PutioInactiveAccountNotice.familyPlanExpired.daysUntilFilesDeleted(now: now))
  }

  func testTimestampsWithoutAZoneReadAsUTC() throws {
    XCTAssertEqual(
      PutioAccountSnapshot.timestamp("2026-10-15T08:00:00"), try date("2026-10-15T08:00:00Z"))
    XCTAssertEqual(
      PutioAccountSnapshot.timestamp("2026-10-15T11:00:00+03:00"), try date("2026-10-15T08:00:00Z"))
    XCTAssertNotNil(PutioAccountSnapshot.timestamp("2026-10-15T08:00:00.250"))
    XCTAssertNil(PutioAccountSnapshot.timestamp(""))
    XCTAssertNil(PutioAccountSnapshot.timestamp("soon"))
  }

  func testStatusFallsBackToTheActiveFlagOnlyWithoutAStatus() {
    XCTAssertEqual(PutioAccountSnapshot.Status(accountStatus: nil, accountActive: false), .inactive)
    XCTAssertEqual(PutioAccountSnapshot.Status(accountStatus: nil, accountActive: true), .active)
    XCTAssertEqual(
      PutioAccountSnapshot.Status(accountStatus: .inactive, accountActive: true), .inactive)
    XCTAssertEqual(
      PutioAccountSnapshot.Status(accountStatus: .active, accountActive: false), .active)
    XCTAssertEqual(
      PutioAccountSnapshot.Status(accountStatus: .stranger, accountActive: false), .stranger)
  }

  private func account(
    _ status: PutioAccountSnapshot.Status, subAccount: Bool = false, deletion: Date? = nil
  ) -> PutioAccountSnapshot {
    PutioAccountSnapshot(
      id: 1, username: "user", email: "user@example.com", suggestNextVideo: false,
      rememberVideoTime: false, defaultSort: nil, historyEnabled: true, trashEnabled: true,
      storage: .init(availableBytes: 1, totalBytes: 2, usedBytes: 1), status: status,
      isSubAccount: subAccount, filesDeletionDate: deletion)
  }

  private func date(_ value: String) throws -> Date {
    try XCTUnwrap(ISO8601DateFormatter().date(from: value))
  }

  private func calendar(hours: Int) throws -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: hours * 3600))
    return calendar
  }
}
