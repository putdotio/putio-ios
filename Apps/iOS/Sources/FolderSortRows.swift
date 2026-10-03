import Foundation
import PutioCore
import SwiftUI

struct PutioFolderSortRows: View {
  let current: PutioFolderSort?
  let isDisabled: Bool
  let onSelect: @MainActor (PutioFolderSort) -> Void

  /// VoiceOver label for the menu holding these rows. The sort rides in the
  /// label because iOS 27 drops a `Menu`'s accessibility value.
  static func menuLabel(for current: PutioFolderSort?) -> String {
    guard let current else { return "More, using the account default sort" }
    return "More, sorted by \(current.title)"
  }

  var body: some View {
    if current == nil {
      Text("Using the account default")
    }
    ForEach(PutioFolderSortKey.allCases, id: \.self) { key in
      Button {
        onSelect(key.selection(from: current))
      } label: {
        if let current, current.key == key {
          // Menu subtitles must be direct children of the button label.
          Text(key.title)
          Text(current.directionTitle)
          Image(systemName: "checkmark")
        } else {
          Text(key.title)
        }
      }
      .disabled(isDisabled)
      .accessibilityIdentifier("files.sort.\(key)")
    }
  }
}
