import Foundation

extension PutioTrashItem {
  public func rowModel(
    relativeTo now: Date = .now, locale: Locale = .current, calendar: Calendar = .current
  ) -> PutioFileRowModel {
    PutioFileRowModel(
      name: name,
      kind: PutioBrowserItemPresentation.rowKind(for: kind),
      sizeText: PutioFileRowModel.sizeText(bytes: sizeBytes, locale: locale),
      dateText: PutioTrashExpiry.text(until: expiresAt, from: now, calendar: calendar),
      showsDisclosure: false
    )
  }
}

public enum PutioTrashNotice: Equatable, Sendable {
  case done(String)
  case failed(String)
  case restoreFailed(String, items: [PutioTrashItem])
  case stillMoving(title: String, message: String)
}

extension PutioTrashMutationOutcome {
  public var notice: PutioTrashNotice {
    switch self {
    case .restored, .restoredItems, .restoredAll:
      return .done(String(localized: "Restore started", bundle: .module))
    case .permanentlyDeleted(let item, _):
      return .done(String(localized: "“\(item.name)” is no longer in trash.", bundle: .module))
    case .permanentlyDeletedItems(let items, _):
      return .done(
        String(localized: "\(items.count) items are no longer in trash.", bundle: .module))
    case .emptied:
      return .done(String(localized: "Trash is empty.", bundle: .module))
    case .failed(_, let failure) where failure.isStillMovingToTrash:
      return .stillMoving(title: Self.restoreRejected, message: failure.message)
    case .failed(.restoreItems(let items), _):
      return .restoreFailed(
        String(localized: "Couldn’t restore \(items.count) items from trash", bundle: .module),
        items: items)
    case .failed(.permanentlyDelete, _), .failed(.permanentlyDeleteItems, _), .failed(.empty, _):
      return .failed(String(localized: "The request could not start", bundle: .module))
    case .failed(.restore, _), .failed(.restoreAll, _):
      return .failed(Self.restoreRejected)
    }
  }

  private static var restoreRejected: String {
    String(localized: "Restore could not start", bundle: .module)
  }
}
