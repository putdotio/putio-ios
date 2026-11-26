import Foundation
import XCTest

@testable import PutioDomain

final class HistoryPresentationTests: XCTestCase {
  private let english = Locale(identifier: "en_US")

  private func calendar(_ zone: String) throws -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
    return calendar
  }

  func testDaysReadTodayYesterdayThenTheDateAndMoveAtMidnight() throws {
    let calendar = try calendar("Europe/Istanbul")
    func at(_ day: Int, _ hour: Int, month: Int = 11, year: Int = 2026) throws -> Date {
      try XCTUnwrap(
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour)))
    }
    let items = [
      event(5, at: try at(10, 23)), event(4, at: try at(10, 1)), event(3, at: try at(9, 20)),
      event(2, at: try at(8, 21)), event(1, at: try at(28, 9, month: 12, year: 2025)),
    ]

    let beforeMidnight = PutioHistoryDay.group(
      items, now: try at(10, 23), calendar: calendar, locale: english)
    XCTAssertEqual(
      beforeMidnight.map(\.title), ["Today", "Yesterday", "Nov 8", "Dec 28, 2025"])
    XCTAssertEqual(beforeMidnight.map { $0.items.map(\.id) }, [[5, 4], [3], [2], [1]])

    let afterMidnight = PutioHistoryDay.group(
      items, now: try at(11, 0), calendar: calendar, locale: english)
    XCTAssertEqual(
      afterMidnight.map(\.title), ["Yesterday", "Nov 9", "Nov 8", "Dec 28, 2025"])
  }

  func testDaysFollowTheCalendarAcrossDaylightSaving() throws {
    let calendar = try calendar("America/New_York")
    let now = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 1)))
    let lateSaturday = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 23, minute: 30)))
    let earlySunday = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 3)))

    let days = PutioHistoryDay.group(
      [event(2, at: earlySunday), event(1, at: lateSaturday)], now: now, calendar: calendar,
      locale: english)

    XCTAssertEqual(days.map(\.title), ["Yesterday", "Mar 7"])
  }

  func testAFutureStampReadsAsToday() throws {
    let calendar = try calendar("UTC")
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let days = PutioHistoryDay.group(
      [event(1, at: now.addingTimeInterval(2 * 86_400))], now: now, calendar: calendar,
      locale: english)
    XCTAssertEqual(days.map(\.title), ["Today"])
  }

  func testKindsMapToAndroidLabelsAndGlyphs() {
    let file = PutioFileID(rawValue: 7)
    let cases: [(PutioHistoryEventKind, String, PutioIcon, PutioHistoryEventPresentation.Tone)] = [
      (
        .fileShared(name: "a", sharingUserName: "Friend", fileID: file), "Shared with you",
        .shareNetwork, .secondary
      ),
      (
        .transferCompleted(name: "a", sizeBytes: 1, fileID: file), "Transfer completed",
        .checkCircle, .secondary
      ),
      (.upload(name: "a", sizeBytes: 1, fileID: file), "Uploaded", .uploadSimple, .secondary),
      (.transferError(name: "a"), "Transfer failed", .warningCircle, .destructive),
      (.fileFromRSSDeleted(name: "a", sizeBytes: 1), "Deleted to free space", .trash, .secondary),
      (.rssFilterPaused(title: "a"), "RSS filter paused", .pauseCircle, .secondary),
      (.transferFromRSSError(name: "a"), "RSS transfer failed", .warningCircle, .destructive),
      (.transferCallbackError(name: "a"), "Callback failed", .warningCircle, .destructive),
    ]
    for (kind, label, icon, tone) in cases {
      let presentation = PutioHistoryEventPresentation(
        PutioHistoryEventItem(id: 1, createdAt: .now, kind: kind))
      XCTAssertEqual(presentation.name, "a")
      XCTAssertEqual(presentation.kind, label)
      XCTAssertEqual(presentation.icon, icon, label)
      XCTAssertEqual(presentation.tone, tone, label)
    }
  }

  func testOnlyFileEventsOfferPlayAndGoToFolderAndCarryTheirSize() {
    let file = PutioFileID(rawValue: 7)
    let cases: [(PutioHistoryEventKind, Bool, Int64?)] = [
      (.fileShared(name: "a", sharingUserName: "Friend", fileID: file), true, nil),
      (.transferCompleted(name: "a", sizeBytes: 3, fileID: file), true, 3),
      (.upload(name: "a", sizeBytes: 2, fileID: file), true, 2),
      (.fileFromRSSDeleted(name: "a", sizeBytes: 1), true, 1),
      (.transferError(name: "a"), false, nil),
      (.rssFilterPaused(title: "a"), false, nil),
      (.transferFromRSSError(name: "a"), false, nil),
      (.transferCallbackError(name: "a"), false, nil),
    ]
    for (kind, offersFileActions, size) in cases {
      let presentation = PutioHistoryEventPresentation(
        PutioHistoryEventItem(id: 1, createdAt: .now, kind: kind))
      XCTAssertEqual(presentation.offersFileActions, offersFileActions, "\(kind)")
      XCTAssertEqual(presentation.sizeBytes, size, "\(kind)")
    }
  }

  func testTimeReadsAsTimeOfDay() throws {
    let zone = try XCTUnwrap(TimeZone(identifier: "UTC"))
    let date = Date(timeIntervalSince1970: 1_793_643_300)
    XCTAssertEqual(
      PutioHistoryEventPresentation.time(date, locale: english, timeZone: zone), "6:15 PM")
  }

  private func event(_ id: Int, at date: Date) -> PutioHistoryEventItem {
    PutioHistoryEventItem(id: id, createdAt: date, kind: .transferError(name: "Transfer \(id)"))
  }
}
