import Foundation
import XCTest

@testable import PutioCore

final class TrashExpiryTests: XCTestCase {
  private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Istanbul")!
    return calendar
  }()

  private func date(_ day: Int, _ hour: Int) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
  }

  func testExpiryReadsTodayTomorrowOrDaysByCalendarDay() {
    let now = date(13, 22)
    let cases: [(Date, String)] = [
      (date(13, 23), "Gone today"),
      (date(14, 1), "Gone tomorrow"),
      (date(16, 0), "Gone in 3 days"),
      (date(27, 9), "Gone in 14 days"),
    ]
    for (expiry, expected) in cases {
      XCTAssertEqual(PutioTrashExpiry.text(until: expiry, from: now, calendar: calendar), expected)
    }
  }

  func testAnExpiryThatAlreadyPassedReadsToday() {
    XCTAssertEqual(
      PutioTrashExpiry.text(until: date(10, 12), from: date(13, 9), calendar: calendar),
      "Gone today")
  }
}
