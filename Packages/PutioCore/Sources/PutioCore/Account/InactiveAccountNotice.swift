import Foundation
import PutioSDK

extension PutioAccountSnapshot.Status {
  init(accountStatus: PutioAccountStatus?, accountActive: Bool) {
    if accountStatus == .active {
      self = .active
    } else if accountStatus == .inactive {
      self = .inactive
    } else if accountStatus == .stranger {
      self = .stranger
    } else {
      self = accountActive ? .active : .inactive
    }
  }
}

extension PutioAccountSnapshot {
  static func timestamp(_ value: String) -> Date? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let optionSets: [ISO8601DateFormatter.Options] = [
      [.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds],
    ]
    for candidate in [trimmed, trimmed + "Z"] {
      for options in optionSets {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = options
        if let date = formatter.date(from: candidate) { return date }
      }
    }
    return nil
  }
}

public enum PutioInactiveAccountNotice: Equatable, Sendable {
  case deactivated(filesDeletionDate: Date?)
  case familyPlanExpired

  public init?(account: PutioAccountSnapshot) {
    guard account.status == .inactive else { return nil }
    self =
      account.isSubAccount
      ? .familyPlanExpired : .deactivated(filesDeletionDate: account.filesDeletionDate)
  }

  public var title: String {
    switch self {
    case .deactivated:
      String(localized: "Your account has been deactivated 😢", bundle: .module)
    case .familyPlanExpired:
      String(localized: "Your family plan is no longer active.", bundle: .module)
    }
  }

  public func daysUntilFilesDeleted(now: Date = .now, calendar: Calendar = .current) -> Int? {
    guard case .deactivated(let date?) = self else { return nil }
    let days = calendar.dateComponents(
      [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)
    ).day
    return days.map(abs)
  }

  public static func filesDeletionMessage(days: Int) -> String {
    String(
      localized:
        "Your files are still here, but they are scheduled to be deleted in \(days) days.",
      bundle: .module)
  }
}
