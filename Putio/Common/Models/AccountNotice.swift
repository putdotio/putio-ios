import Foundation
import PutioSDK

/// The notice an inactive account shows above every signed-in screen and in
/// place of online playback, with the web and Android apps' states: a family
/// plan member is told the plan lapsed, anyone else that the account is
/// deactivated and when the files go. The API never sends `account_active:
/// false`, so `account_status` decides, and a `stranger` sees nothing.
///
/// App Review rules out purchase links and buttons, so the notice states facts
/// and names put.io in plain text.
enum AccountNotice: Equatable {
    /// `filesDeletedAt` is nil when put.io sent no usable date, and the notice
    /// then has no countdown.
    case deactivated(filesDeletedAt: Date?)
    case familyPlanExpired

    init?(account: PutioAccount) {
        self.init(
            status: account.accountStatus,
            isSubAccount: account.isSubAccount,
            filesWillBeDeletedAt: account.filesWillBeDeletedAt
        )
    }

    init?(status: PutioAccountStatus?, isSubAccount: Bool, filesWillBeDeletedAt: String) {
        guard status == .inactive else { return nil }

        self = isSubAccount
            ? .familyPlanExpired
            : .deactivated(filesDeletedAt: Self.timestamp(from: filesWillBeDeletedAt))
    }

    var title: String {
        switch self {
        case .deactivated:
            return NSLocalizedString("Your account has been deactivated 😢", comment: "")
        case .familyPlanExpired:
            return NSLocalizedString("Your family plan is no longer active.", comment: "")
        }
    }

    func message(now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard case .deactivated(let filesDeletedAt) = self else { return nil }

        let renewal = NSLocalizedString("Renew your plan at put.io to keep your files.", comment: "")
        guard let filesDeletedAt else { return renewal }

        let days = Self.calendarDays(from: now, to: filesDeletedAt, calendar: calendar)
        let deletion = days == 1
            ? NSLocalizedString("Your files are still here, but they are scheduled to be deleted in 1 day.", comment: "")
            : String(
                format: NSLocalizedString("Your files are still here, but they are scheduled to be deleted in %d days.", comment: ""),
                days
            )
        return "\(deletion) \(renewal)"
    }

    /// Whole calendar days between the two dates' days in `calendar`'s time
    /// zone, absolute as web's `daysDiffFromNow` counts them, so a date already
    /// past still reads as a distance.
    static func calendarDays(from start: Date, to end: Date, calendar: Calendar) -> Int {
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: start),
            to: calendar.startOfDay(for: end)
        ).day ?? 0
        return abs(days)
    }

    /// put.io sends naive UTC datetimes such as `2026-10-31T09:30:00.123456`.
    /// The offset-less format goes last: ISO8601DateFormatter ignores an offset
    /// it was not asked to read instead of failing.
    static func timestamp(from value: String) -> Date? {
        guard !value.isEmpty else { return nil }

        for options in timestampFormats {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            if let date = formatter.date(from: value) {
                return date
            }
        }

        return nil
    }

    private static let timestampFormats: [ISO8601DateFormatter.Options] = [
        [.withInternetDateTime],
        [.withInternetDateTime, .withFractionalSeconds],
        [.withFullDate, .withTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
    ]
}

extension Notification.Name {
    static let accountNoticeDidChange = Notification.Name("PutioAccountNoticeDidChange")
}

/// The signed-in account's notice, read and written on the main thread. Every
/// `/account/info` answer replaces it and signing out clears it. It lives in
/// memory only, so an offline launch shows no notice until the account answers.
final class AccountNoticeStore {
    static let shared = AccountNoticeStore()

    private(set) var notice: AccountNotice?

    func update(with account: PutioAccount) {
        replace(with: AccountNotice(account: account))
    }

    func clear() {
        replace(with: nil)
    }

    // Posts even when the notice is unchanged, so a refresh redraws a
    // countdown that crossed midnight.
    private func replace(with notice: AccountNotice?) {
        self.notice = notice
        NotificationCenter.default.post(name: .accountNoticeDidChange, object: self)
    }
}
