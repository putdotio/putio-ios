import PutioCore
import SwiftUI

struct PutioFolderSortMenu: View {
  let current: PutioFolderSort?
  let isDisabled: Bool
  var isBusy = false
  let onSelect: @MainActor (PutioFolderSort) -> Void

  private var choices: PutioFolderSortChoices {
    PutioFolderSortChoices(current: current)
  }

  static func accessibilityLabel(for current: PutioFolderSort?) -> String {
    guard let current else { return String(localized: "Sort files") }
    return String(localized: "Sort files, \(current.menuLabel)")
  }

  var body: some View {
    Menu {
      Section("Sort by") {
        ForEach(PutioFolderSortChoices.fields, id: \.self) { field in
          row(field.menuTitle, isChecked: choices.checkedField == field) {
            choices.selecting(field)
          }
        }
      }
      Section("Order") {
        ForEach(choices.orders, id: \.self) { order in
          row(order.orderTitle, isChecked: choices.isChecked(order)) { order }
        }
      }
      Section("Videos") {
        ForEach(PutioFolderSortChoices.videoOrders, id: \.self) { order in
          row(order.orderTitle, isChecked: choices.isChecked(order)) { order }
        }
      }
    } label: {
      Label("Sort files", systemImage: "arrow.up.arrow.down")
    }
    .disabled(isDisabled)
    .allowsHitTesting(!isBusy)
    .accessibilityRespondsToUserInteraction(!isBusy)
    .accessibilityIdentifier("files.sort")
    .accessibilityLabel(Self.accessibilityLabel(for: current))
    .accessibilityValue(isBusy ? Text("Updating file order") : Text(verbatim: ""))
  }

  private func row(
    _ title: String, isChecked: Bool, sort: @escaping @MainActor () -> PutioFolderSort
  ) -> some View {
    Button {
      let choice = sort()
      guard choice != current else { return }
      onSelect(choice)
    } label: {
      Label {
        Text(title)
      } icon: {
        Image(uiImage: isChecked ? Self.checkmark : Self.uncheckedSpace)
      }
    }
    .accessibilityAddTraits(isChecked ? .isSelected : [])
  }

  private static let checkmark =
    UIImage(systemName: "checkmark")?
    .withTintColor(UIColor(PutioTheme.Colors.accent), renderingMode: .alwaysOriginal) ?? UIImage()
  private static let uncheckedSpace = UIGraphicsImageRenderer(size: checkmark.size).image { _ in }
}
