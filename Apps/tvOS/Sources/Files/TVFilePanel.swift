import PutioCore
import SwiftUI

extension TVFilePresentation {
  static func panelRows(
    _ menu: PutioFileMenu, canStartOver: Bool, canOpenInVLC: Bool, canMove: Bool,
    canDelete: Bool
  ) -> [[PutioFileMenuRow]] {
    menu.sections.map { section in
      section.filter { row in
        switch row {
        case .open, .play, .markWatched, .markUnwatched, .rename, .pin, .unpin: true
        case .startOver: canStartOver
        case .openInVLC: canOpenInVLC
        case .move: canMove
        case .trash: canDelete
        default: false
        }
      }
    }
    .filter { !$0.isEmpty }
  }

  static func toast(for outcome: PutioFileActionOutcome, trashEnabled: Bool) -> PutioToast? {
    guard let title = outcome.toastTitle(trashEnabled: trashEnabled) else { return nil }
    switch outcome {
    case .failed:
      return PutioToast(title, icon: .warning, width: .fit)
    case .succeeded(.delete):
      return PutioToast(title, icon: .symbol(.trash), width: .fit)
    case .succeeded(.setWatched(_, _, _, let watched)):
      return PutioToast(title, icon: .symbol(watched ? .eye : .eyeSlash), width: .fit)
    case .succeeded(.move(_, _, _, _, let destinationName)):
      return PutioToast(
        PutioMoveCopy.moved(to: destinationName), icon: .symbol(.folder), width: .fit)
    case .succeeded:
      return PutioToast(title, width: .fit)
    }
  }
}

struct TVFilePanel: View {
  let item: PutioFileItem
  let row: PutioFileRowModel
  let sections: [[PutioFileMenuRow]]
  let trashEnabled: Bool
  let identifier: String
  let perform: (PutioFileMenuRow) -> Void

  var body: some View {
    TVDetailPanel(icon: row.kind.icon, title: item.name, identifier: identifier) {
      HStack(spacing: PutioTheme.TV.Spacing.xs) {
        if let size = row.sizeText {
          Text(size)
            .putioFont(PutioTheme.TV.Typography.numeric)
          Text(verbatim: "·").accessibilityHidden(true)
        }
        Text(row.dateText ?? "")
      }
    } facts: {
      EmptyView()
    } actions: {
      ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
        if section.contains(.trash) { TVDetailDivider() }
        ForEach(section, id: \.panelSlot) { menuRow in
          if let title = menuRow.title(for: item, style: .panel, trashEnabled: trashEnabled) {
            TVDetailAction(
              title: title, icon: menuRow.icon, isDestructive: menuRow.isDestructive
            ) {
              perform(menuRow)
            }
            .accessibilityIdentifier("\(identifier).\(menuRow.rawValue)")
          }
        }
      }
    }
  }
}

extension PutioFileMenuRow {
  fileprivate var panelSlot: String {
    switch self {
    case .unpin: PutioFileMenuRow.pin.rawValue
    case .markUnwatched: PutioFileMenuRow.markWatched.rawValue
    default: rawValue
    }
  }
}
