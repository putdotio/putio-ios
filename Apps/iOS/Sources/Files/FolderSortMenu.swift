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

  var body: some View {
    Menu {
      Section("Sort by") {
        ForEach(PutioFolderSortChoices.fields, id: \.self) { field in
          row(field.menuTitle, isChecked: choices.checkedField == field) {
            onSelect(choices.selecting(field))
          }
        }
      }
      Section("Order") {
        ForEach(choices.orders, id: \.self) { order in
          row(order.orderTitle, isChecked: choices.isChecked(order)) {
            onSelect(order)
          }
        }
      }
      Section("Videos") {
        ForEach(PutioFolderSortChoices.videoOrders, id: \.self) { order in
          row(order.orderTitle, isChecked: choices.isChecked(order)) {
            onSelect(order)
          }
        }
      }
    } label: {
      Label("Sort files", systemImage: "arrow.up.arrow.down")
    }
    .disabled(isDisabled)
    .accessibilityIdentifier("files.sort")
    .accessibilityValue(current.map(\.menuLabel) ?? String())
  }

  private func row(
    _ title: String, isChecked: Bool, select: @escaping @MainActor () -> Void
  ) -> some View {
    Toggle(
      title,
      isOn: Binding(
        get: { isChecked },
        set: { _ in select() }
      )
    )
  }
}
