import XCTest
import PutioSDK
@testable import Putio

final class AccountNoticeTests: XCTestCase {
    private let renewal = "Renew your plan at put.io to keep your files."

    func testAccountInGoodStandingHasNoNotice() {
        for status in [PutioAccountStatus.active, .stranger, nil] {
            XCTAssertNil(
                AccountNotice(status: status, isSubAccount: false, filesWillBeDeletedAt: "2026-10-31T09:30:00"),
                "\(status?.rawValue ?? "missing") status"
            )
        }
    }

    func testInactiveAccountCountsDownToDeletion() {
        let notice = AccountNotice(status: .inactive, isSubAccount: false, filesWillBeDeletedAt: "2026-11-01T09:30:00")

        XCTAssertEqual(notice?.title, "Your account has been deactivated 😢")
        XCTAssertEqual(
            notice?.message(now: date("2026-10-18T12:00:00Z"), calendar: calendar("UTC")),
            "Your files are still here, but they are scheduled to be deleted in 14 days. \(renewal)"
        )
    }

    func testOneDayIsSingular() {
        let notice = AccountNotice(status: .inactive, isSubAccount: false, filesWillBeDeletedAt: "2026-10-19T09:30:00")

        XCTAssertEqual(
            notice?.message(now: date("2026-10-18T12:00:00Z"), calendar: calendar("UTC")),
            "Your files are still here, but they are scheduled to be deleted in 1 day. \(renewal)"
        )
    }

    func testMissingOrUnreadableDateDropsTheCountdown() {
        for value in ["", "soon"] {
            let notice = AccountNotice(status: .inactive, isSubAccount: false, filesWillBeDeletedAt: value)

            XCTAssertEqual(notice, .deactivated(filesDeletedAt: nil), value)
            XCTAssertEqual(notice?.message(), renewal, value)
        }
    }

    func testFamilyPlanMemberIsToldThePlanLapsed() {
        let notice = AccountNotice(status: .inactive, isSubAccount: true, filesWillBeDeletedAt: "2026-11-01T09:30:00")

        XCTAssertEqual(notice, .familyPlanExpired)
        XCTAssertEqual(notice?.title, "Your family plan is no longer active.")
        XCTAssertNil(notice?.message())
    }

    func testPastDateReadsAsADistance() {
        let notice = AccountNotice(status: .inactive, isSubAccount: false, filesWillBeDeletedAt: "2026-10-15T09:30:00")

        XCTAssertEqual(
            notice?.message(now: date("2026-10-18T12:00:00Z"), calendar: calendar("UTC")),
            "Your files are still here, but they are scheduled to be deleted in 3 days. \(renewal)"
        )
    }

    // 22:30 UTC on the 20th is already the 21st in Istanbul, so the same
    // instant is two days out in UTC and three in Istanbul. Reading the naive
    // timestamp as local time would make Istanbul two as well.
    func testNaiveTimestampIsUTCAndDaysFollowTheDeviceTimeZone() {
        let now = date("2026-10-18T12:00:00Z")
        let deletion = AccountNotice.timestamp(from: "2026-10-20T22:30:00")

        XCTAssertEqual(deletion, date("2026-10-20T22:30:00Z"))
        XCTAssertEqual(deletion.map { AccountNotice.calendarDays(from: now, to: $0, calendar: calendar("UTC")) }, 2)
        XCTAssertEqual(deletion.map { AccountNotice.calendarDays(from: now, to: $0, calendar: calendar("Europe/Istanbul")) }, 3)
    }

    func testTimestampKeepsAnExplicitOffsetAndToleratesMicroseconds() {
        XCTAssertEqual(AccountNotice.timestamp(from: "2026-10-20T22:30:00+03:00"), date("2026-10-20T19:30:00Z"))
        XCTAssertEqual(AccountNotice.timestamp(from: "2026-10-20T22:30:00.123Z"), date("2026-10-20T22:30:00.123Z"))
        XCTAssertEqual(
            AccountNotice.timestamp(from: "2026-10-20T22:30:00.123456").map { Int($0.timeIntervalSince1970) },
            Int(date("2026-10-20T22:30:00Z").timeIntervalSince1970)
        )
    }

    func testNoticeReadsTheAccountInfoFields() throws {
        let json = """
        {
          "user_id": 1, "username": "u", "mail": "u@example.com",
          "account_active": null, "account_status": "inactive", "is_sub_account": false,
          "files_will_be_deleted_at": "2026-11-01T09:30:00",
          "disk": { "avail": 0, "size": 0, "used": 0 },
          "settings": {}
        }
        """
        let account = try JSONDecoder().decode(PutioAccount.self, from: Data(json.utf8))

        XCTAssertEqual(AccountNotice(account: account), .deactivated(filesDeletedAt: date("2026-11-01T09:30:00Z")))
    }

    private func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = value.contains(".")
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter.date(from: value)!
    }

    private func calendar(_ timeZone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone)!
        return calendar
    }
}
