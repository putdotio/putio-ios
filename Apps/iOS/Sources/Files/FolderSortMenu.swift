import PutioCore
import SwiftUI

/// The folder's sort button: one stock menu with Sort by, Order and Videos,
/// each choice checked in place.
struct PutioFolderSortMenu: View {
  let current: PutioFolderSort?
  let isDisabled: Bool
  let onSelect: @MainActor (PutioFolderSort) -> Void

  private var choices: PutioFolderSortChoices {
    PutioFolderSortChoices(current: current)
  }

  /// VoiceOver label for the button. The sort rides in the label because
  /// iOS 27 drops a `Menu`'s accessibility value.
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
    .accessibilityIdentifier("files.sort")
    .accessibilityLabel(Self.accessibilityLabel(for: current))
  }

  /// A checked row stays checked: choosing it again sends nothing, so a
  /// folder that follows the account default keeps following it.
  private func row(
    _ title: String, isChecked: Bool, sort: @escaping @MainActor () -> PutioFolderSort
  ) -> some View {
    Toggle(
      title,
      isOn: Binding(
        get: { isChecked },
        set: { _ in
          let choice = sort()
          guard choice != current else { return }
          onSelect(choice)
        }
      )
    )
  }
}
