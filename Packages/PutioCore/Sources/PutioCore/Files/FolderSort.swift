import Foundation

/// A sort key as the Files app presents it: one row per key, direction as a
/// subtitle, and re-selecting the current key flips direction.
public enum PutioFolderSortKey: CaseIterable, Hashable, Sendable {
  case name, size, dateAdded, dateModified, type, watchStatus

  public var title: String {
    switch self {
    case .name: String(localized: "Name", bundle: .module)
    case .size: String(localized: "Size", bundle: .module)
    case .dateAdded: String(localized: "Date Added", bundle: .module)
    case .dateModified: String(localized: "Date Modified", bundle: .module)
    case .type: String(localized: "Type", bundle: .module)
    case .watchStatus: String(localized: "Watch Status", bundle: .module)
    }
  }

  public func sort(ascending: Bool) -> PutioFolderSort {
    switch (self, ascending) {
    case (.name, true): .nameAscending
    case (.name, false): .nameDescending
    case (.size, true): .sizeAscending
    case (.size, false): .sizeDescending
    case (.dateAdded, true): .dateAddedAscending
    case (.dateAdded, false): .dateAddedDescending
    case (.dateModified, true): .dateModifiedAscending
    case (.dateModified, false): .dateModifiedDescending
    case (.type, true): .typeAscending
    case (.type, false): .typeDescending
    case (.watchStatus, true): .watchStatusAscending
    case (.watchStatus, false): .watchStatusDescending
    }
  }

  /// The sort to request when the user taps this key while `current` applies.
  public func selection(from current: PutioFolderSort?) -> PutioFolderSort {
    guard let current, current.key == self else { return sort(ascending: true) }
    return sort(ascending: !current.isAscending)
  }
}

extension PutioFolderSort {
  public var key: PutioFolderSortKey {
    switch self {
    case .nameAscending, .nameDescending: .name
    case .sizeAscending, .sizeDescending: .size
    case .dateAddedAscending, .dateAddedDescending: .dateAdded
    case .dateModifiedAscending, .dateModifiedDescending: .dateModified
    case .typeAscending, .typeDescending: .type
    case .watchStatusAscending, .watchStatusDescending: .watchStatus
    }
  }

  public var isAscending: Bool {
    switch self {
    case .nameAscending, .sizeAscending, .dateAddedAscending, .dateModifiedAscending,
      .typeAscending, .watchStatusAscending:
      true
    default:
      false
    }
  }

  public var directionTitle: String {
    isAscending
      ? String(localized: "Ascending", bundle: .module)
      : String(localized: "Descending", bundle: .module)
  }

  public var title: String {
    "\(key.title), \(directionTitle.lowercased())"
  }
}

public struct PutioFolderSortChoices: Equatable, Sendable {
  public static let fields: [PutioFolderSortKey] = [.name, .size, .dateAdded, .dateModified, .type]
  public static let videoOrders: [PutioFolderSort] = [
    .watchStatusAscending, .watchStatusDescending,
  ]

  public let current: PutioFolderSort?

  public init(current: PutioFolderSort?) {
    self.current = current
  }

  public var checkedField: PutioFolderSortKey? {
    guard let current, current.key != .watchStatus else { return nil }
    return current.key
  }

  public var orders: [PutioFolderSort] {
    let field = checkedField ?? .name
    return [field.sort(ascending: true), field.sort(ascending: false)]
  }

  public func isChecked(_ sort: PutioFolderSort) -> Bool {
    sort == current
  }

  public func selecting(_ field: PutioFolderSortKey) -> PutioFolderSort {
    field.sort(ascending: checkedField == nil || current?.isAscending == true)
  }
}

extension PutioFolderSortKey {
  public var menuTitle: String {
    switch self {
    case .name: String(localized: "Name", bundle: .module)
    case .size: String(localized: "Size", bundle: .module)
    case .dateAdded: String(localized: "Date added", bundle: .module)
    case .dateModified: String(localized: "Date modified", bundle: .module)
    case .type: String(localized: "Type", bundle: .module)
    case .watchStatus: String(localized: "Videos", bundle: .module)
    }
  }
}

extension PutioFolderSort {
  public var orderTitle: String {
    switch self {
    case .nameAscending, .typeAscending: String(localized: "A to Z", bundle: .module)
    case .nameDescending, .typeDescending: String(localized: "Z to A", bundle: .module)
    case .sizeAscending: String(localized: "Smallest first", bundle: .module)
    case .sizeDescending: String(localized: "Largest first", bundle: .module)
    case .dateAddedAscending, .dateModifiedAscending:
      String(localized: "Oldest first", bundle: .module)
    case .dateAddedDescending, .dateModifiedDescending:
      String(localized: "Newest first", bundle: .module)
    case .watchStatusAscending: String(localized: "Unwatched first", bundle: .module)
    case .watchStatusDescending: String(localized: "Watched first", bundle: .module)
    }
  }

  public var menuLabel: String {
    switch self {
    case .nameAscending: String(localized: "Name, A to Z", bundle: .module)
    case .nameDescending: String(localized: "Name, Z to A", bundle: .module)
    case .sizeAscending: String(localized: "Size, smallest first", bundle: .module)
    case .sizeDescending: String(localized: "Size, largest first", bundle: .module)
    case .dateAddedAscending: String(localized: "Date added, oldest first", bundle: .module)
    case .dateAddedDescending: String(localized: "Date added, newest first", bundle: .module)
    case .dateModifiedAscending: String(localized: "Date modified, oldest first", bundle: .module)
    case .dateModifiedDescending:
      String(localized: "Date modified, newest first", bundle: .module)
    case .typeAscending: String(localized: "Type, A to Z", bundle: .module)
    case .typeDescending: String(localized: "Type, Z to A", bundle: .module)
    case .watchStatusAscending: String(localized: "Unwatched first", bundle: .module)
    case .watchStatusDescending: String(localized: "Watched first", bundle: .module)
    }
  }
}
