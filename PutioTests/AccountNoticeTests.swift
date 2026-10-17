import UIKit
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
    // instant is two days out in UTC and three in Istanbul. The parse runs
    // with the device in Istanbul, where reading the naive timestamp as local
    // time would make Istanbul two as well, even on a UTC host.
    func testNaiveTimestampIsUTCAndDaysFollowTheDeviceTimeZone() {
        let now = date("2026-10-18T12:00:00Z")
        let deletion = inDeviceTimeZone("Europe/Istanbul") {
            AccountNotice.timestamp(from: "2026-10-20T22:30:00")
        }

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
        XCTAssertEqual(AccountNotice(account: try inactiveAccount()), .deactivated(filesDeletedAt: date("2026-11-01T09:30:00Z")))
    }

    // A download with no local successor falls back to put.io's next file,
    // which would queue a stream behind the playback gate.
    func testInactiveAccountQueuesNoStreamAfterTheLastDownload() throws {
        AccountNoticeStore.shared.update(with: try inactiveAccount())
        defer { AccountNoticeStore.shared.clear() }

        for consumptionType in [MediaPlayerItem.ConsumptionType.offline, .online] {
            let queue = NextMediaQueueSpy()
            let finder = NextMediaFinder()
            finder.delegate = queue

            finder.findNextMedia(for: MediaPlayerItem(
                id: -1,
                name: "Track",
                url: URL(fileURLWithPath: "/dev/null"),
                fileType: .audio,
                consumptionType: consumptionType
            ))

            XCTAssertTrue(queue.ended, consumptionType.rawValue)
            XCTAssertTrue(queue.found.isEmpty, consumptionType.rawValue)
        }
    }

    // The banner sits above every signed-in screen, so at the largest text
    // size on the smallest iPhone it must still leave most of the screen to
    // the files under it.
    func testBannerLeavesTheScreenUsableAtTheLargestTextSize() {
        let screen = CGRect(x: 0, y: 0, width: 375, height: 667)
        let window = UIWindow(frame: screen)
        window.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge

        let banner = AccountNoticeView()
        banner.translatesAutoresizingMaskIntoConstraints = false
        window.addSubview(banner)
        NSLayoutConstraint.activate([
            banner.leadingAnchor.constraint(equalTo: window.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: window.trailingAnchor),
            banner.topAnchor.constraint(equalTo: window.topAnchor)
        ])
        let now = date("2026-10-18T12:00:00Z")
        banner.configure(with: .deactivated(filesDeletedAt: now.addingTimeInterval(14 * 86_400)), now: now)
        window.layoutIfNeeded()

        XCTAssertLessThanOrEqual(banner.bounds.height, screen.height * 0.4, "banner height \(banner.bounds.height)")
    }

    private func inactiveAccount() throws -> PutioAccount {
        let json = """
        {
          "user_id": 1, "username": "u", "mail": "u@example.com",
          "account_active": null, "account_status": "inactive", "is_sub_account": false,
          "files_will_be_deleted_at": "2026-11-01T09:30:00",
          "disk": { "avail": 0, "size": 0, "used": 0 },
          "settings": {}
        }
        """
        return try JSONDecoder().decode(PutioAccount.self, from: Data(json.utf8))
    }

    private func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = value.contains(".")
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter.date(from: value)!
    }

    // TimeZone.current rereads TZ once the cached system zone is reset;
    // setting NSTimeZone.default leaves it alone.
    private func inDeviceTimeZone<T>(_ identifier: String, _ body: () -> T) -> T {
        let hostTZ = getenv("TZ").map { String(cString: $0) }
        setenv("TZ", identifier, 1)
        NSTimeZone.resetSystemTimeZone()
        defer {
            if let hostTZ { setenv("TZ", hostTZ, 1) } else { unsetenv("TZ") }
            NSTimeZone.resetSystemTimeZone()
        }

        XCTAssertEqual(TimeZone.current.identifier, identifier)
        return body()
    }

    private func calendar(_ timeZone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone)!
        return calendar
    }
}

private final class NextMediaQueueSpy: NextMediaFinderDelegate {
    private(set) var found: [MediaPlayerItem] = []
    private(set) var ended = false

    func didFindNextMedia(nextMedia: MediaPlayerItem) {
        found.append(nextMedia)
    }

    func didCannotFindNextMedia() {
        ended = true
    }
}
