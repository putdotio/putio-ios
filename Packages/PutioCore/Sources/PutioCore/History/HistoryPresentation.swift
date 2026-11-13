import Foundation

public struct PutioHistoryDay: Identifiable, Equatable {
  public let id: Date
  public let title: String
  public let items: [PutioHistoryEventItem]

  public static func group(
    _ items: [PutioHistoryEventItem], now: Date = .now, calendar: Calendar = .current,
    locale: Locale = .current
  ) -> [PutioHistoryDay] {
    let today = calendar.startOfDay(for: now)
    var order: [Date] = []
    var groups: [Date: [PutioHistoryEventItem]] = [:]
    for item in items {
      let day = min(calendar.startOfDay(for: item.createdAt), today)
      if groups[day] == nil { order.append(day) }
      groups[day, default: []].append(item)
    }
    return order.map { day in
      PutioHistoryDay(
        id: day, title: title(for: day, today: today, calendar: calendar, locale: locale),
        items: groups[day, default: []])
    }
  }

  static func title(for day: Date, today: Date, calendar: Calendar, locale: Locale) -> String {
    if day == today { return String(localized: "Today", bundle: .module) }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
      calendar.startOfDay(for: yesterday) == day
    {
      return String(localized: "Yesterday", bundle: .module)
    }
    let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
      .month(.abbreviated).day()
    if calendar.component(.year, from: day) == calendar.component(.year, from: today) {
      return day.formatted(style)
    }
    return day.formatted(style.year())
  }
}

public struct PutioHistoryEventPresentation: Equatable {
  public enum Tone: Equatable {
    case secondary
    case destructive
  }

  public let name: String
  public let kind: String
  public let icon: PutioIcon
  public let tone: Tone

  public init(_ event: PutioHistoryEventItem) {
    switch event.kind {
    case .fileShared(let name, _, _):
      self.init(name, String(localized: "Shared with you", bundle: .module), .shareNetwork)
    case .transferCompleted(let name, _, _):
      self.init(name, String(localized: "Transfer completed", bundle: .module), .checkCircle)
    case .upload(let name, _, _):
      self.init(name, String(localized: "Uploaded", bundle: .module), .uploadSimple)
    case .transferError(let name):
      self.init(
        name, String(localized: "Transfer failed", bundle: .module), .warningCircle, .destructive)
    case .fileFromRSSDeleted(let name, _):
      self.init(name, String(localized: "Deleted to free space", bundle: .module), .trash)
    case .rssFilterPaused(let title):
      self.init(title, String(localized: "RSS filter paused", bundle: .module), .pauseCircle)
    case .transferFromRSSError(let name):
      self.init(
        name, String(localized: "RSS transfer failed", bundle: .module), .warningCircle,
        .destructive)
    case .transferCallbackError(let name):
      self.init(
        name, String(localized: "Callback failed", bundle: .module), .warningCircle, .destructive)
    }
  }

  private init(_ name: String, _ kind: String, _ icon: PutioIcon, _ tone: Tone = .secondary) {
    self.name = name
    self.kind = kind
    self.icon = icon
    self.tone = tone
  }

  public static func time(
    _ date: Date, locale: Locale = .current, timeZone: TimeZone = .current
  ) -> String {
    date.formatted(
      Date.FormatStyle(locale: locale, timeZone: timeZone).hour().minute())
  }
}
