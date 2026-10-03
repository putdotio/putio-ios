import Foundation

/// A sort key as the Files app presents it: one row per key, direction as a
/// subtitle, and re-selecting the current key flips direction.
public enum PutioFolderSortKey: CaseIterable, Hashable {
  case name, size, dateAdded, dateModified, type, watchStatus

  public var title: String {
    switch self {
    case .name: "Name"
    case .size: "Size"
    case .dateAdded: "Date Added"
    case .dateModified: "Date Modified"
    case .type: "Type"
    case .watchStatus: "Watch Status"
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
    isAscending ? "Ascending" : "Descending"
  }

  public var title: String {
    "\(key.title), \(directionTitle.lowercased())"
  }
}
