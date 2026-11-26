import Foundation

public enum PutioTrashExpiry {
  public static func daysLeft(
    until expiresAt: Date, from now: Date, calendar: Calendar = .current
  ) -> Int {
    let days = calendar.dateComponents(
      [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: expiresAt)
    ).day
    return max(0, days ?? 0)
  }

  public static func text(
    until expiresAt: Date, from now: Date, calendar: Calendar = .current
  ) -> String {
    let days = daysLeft(until: expiresAt, from: now, calendar: calendar)
    switch days {
    case 0: return String(localized: "Gone today", bundle: .module)
    case 1: return String(localized: "Gone tomorrow", bundle: .module)
    default: return String(localized: "Gone in \(days) days", bundle: .module)
    }
  }
}
