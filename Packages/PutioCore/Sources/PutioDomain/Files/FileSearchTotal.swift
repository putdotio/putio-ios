import Foundation

public struct PutioFileSearchTotal: Equatable, Sendable {
  public static let cap = 1_000

  public let count: Int
  public let isAtLeast: Bool

  public init(count: Int, isAtLeast: Bool) {
    self.count = max(count, 0)
    self.isAtLeast = isAtLeast
  }

  public init?(
    page: PutioFileSearchPage, filter: PutioFileSearchFilter, hiddenIDs: Set<PutioFileID> = []
  ) {
    let shown = page.items.filter { !hiddenIDs.contains($0.id) && filter.accepts($0) }.count
    let removed = page.items.filter { hiddenIDs.contains($0.id) }.count
    let matched = page.totalCount - removed
    let capped = page.totalCount >= Self.cap
    let complete = page.nextCursor == nil
    switch filter {
    case .subtitles:
      guard complete else { return nil }
      self.init(count: shown, isAtLeast: capped)
    default:
      if capped {
        self.init(count: max(matched, shown), isAtLeast: true)
      } else if complete {
        self.init(count: shown, isAtLeast: false)
      } else {
        self.init(count: max(matched, shown), isAtLeast: false)
      }
    }
  }

  public func label(locale: Locale = .current) -> String {
    isAtLeast
      ? String(localized: "\(count)+ results", bundle: .module, locale: locale)
      : String(localized: "\(count) results", bundle: .module, locale: locale)
  }
}
