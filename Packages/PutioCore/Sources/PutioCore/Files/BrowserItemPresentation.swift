import Foundation
import Synchronization

public struct PutioBrowserItemPresentation: Equatable, Identifiable, Sendable {
  public let item: PutioFileItem
  public let row: PutioFileRowModel

  public var id: PutioFileID {
    item.id
  }

  public var folderRoute: PutioFolderRoute? {
    guard item.kind == .folder else { return nil }
    return PutioFolderRoute(id: item.id, title: item.name)
  }

  public var fileRoute: PutioFileRoute? {
    guard item.kind != .folder else { return nil }
    return PutioFileRoute(item: item)
  }

  /// `sort` is the folder's effective sort: rows show when an item was added
  /// under Date Added, and when it last changed otherwise.
  public init(
    item: PutioFileItem,
    relativeTo referenceDate: Date = .now,
    locale: Locale = .current,
    sort: PutioFolderSort? = nil
  ) {
    self.item = item
    row = PutioFileRowModel(
      name: item.name,
      kind: Self.rowKind(for: item.kind),
      sizeText: Self.detailText(
        for: item,
        date: sort?.key == .dateAdded ? item.createdAt : item.updatedAt,
        relativeTo: referenceDate,
        locale: locale
      ),
      isWatched: item.isWatched
    )
  }

  public static func rowKind(for kind: PutioFileKind) -> PutioFileRowModel.Kind {
    switch kind {
    case .folder: .folder
    case .video: .video
    case .audio: .audio
    case .image: .image
    case .pdf, .other: .file
    }
  }

  private static func detailText(
    for item: PutioFileItem,
    date: Date,
    relativeTo referenceDate: Date,
    locale: Locale
  ) -> String? {
    guard item.kind != .folder else { return nil }
    let size = PutioFileRowModel.sizeText(bytes: item.sizeBytes, locale: locale)
    let relativeDate = relativeDateText(for: date, relativeTo: referenceDate, locale: locale)
    return "\(size) · \(relativeDate)"
  }

  /// A named relative date such as "yesterday" or "3 days ago".
  public static func relativeDateText(
    for date: Date, relativeTo referenceDate: Date = .now, locale: Locale = .current
  ) -> String {
    relativeDateFormatters.withLock { formatters in
      let formatter: RelativeDateTimeFormatter
      if let cached = formatters[locale] {
        formatter = cached
      } else {
        formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        formatters[locale] = formatter
      }
      return formatter.localizedString(for: date, relativeTo: referenceDate)
    }
  }

  // Rows rebuild their presentation on every render, so each locale's
  // formatter is built once and used only under the lock.
  private static let relativeDateFormatters = Mutex<[Locale: RelativeDateTimeFormatter]>([:])
}
