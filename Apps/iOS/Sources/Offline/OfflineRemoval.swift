import Foundation
import PutioCore
import SwiftUI

struct PutioOfflineRemovalCopy: Equatable {
  let isPad: Bool

  var actionTitle: String {
    isPad
      ? String(localized: "Remove from this iPad")
      : String(localized: "Remove from this iPhone")
  }

  func title(count: Int) -> String {
    switch (count == 1, isPad) {
    case (true, true): String(localized: "Remove from this iPad?")
    case (true, false): String(localized: "Remove from this iPhone?")
    case (false, true): String(localized: "Remove \(count) downloads from this iPad?")
    case (false, false): String(localized: "Remove \(count) downloads from this iPhone?")
    }
  }

  func message(names: [String]) -> String {
    switch (names.count == 1 ? names.first : nil, isPad) {
    case (let name?, true):
      String(
        localized: "“\(name)” stays in your put.io files. Only the copy on this iPad is removed.")
    case (let name?, false):
      String(
        localized: "“\(name)” stays in your put.io files. Only the copy on this iPhone is removed.")
    case (nil, true):
      String(
        localized:
          "The files stay in your put.io account. Only the copies on this iPad are removed.")
    case (nil, false):
      String(
        localized:
          "The files stay in your put.io account. Only the copies on this iPhone are removed.")
    }
  }

  func failureTitle(count: Int) -> String {
    count == 1
      ? String(localized: "Could not remove download")
      : String(localized: "Could not remove downloads")
  }

  func failureMessage(count: Int) -> String {
    switch (count == 1, isPad) {
    case (true, true):
      String(
        localized:
          "Nothing was removed because this iPad could not save the change. Remove the download again."
      )
    case (true, false):
      String(
        localized:
          "Nothing was removed because this iPhone could not save the change. Remove the download again."
      )
    case (false, true):
      String(
        localized:
          "Nothing was removed because this iPad could not save the change. Remove the downloads again."
      )
    case (false, false):
      String(
        localized:
          "Nothing was removed because this iPhone could not save the change. Remove the downloads again."
      )
    }
  }
}

private struct PutioOfflineRemovalAlert: ViewModifier {
  @Binding var pending: [PutioOfflineItem]?
  let queue: PutioOfflineQueue
  let copy: PutioOfflineRemovalCopy
  let onRemoved: @MainActor () -> Void

  @State private var failed: [PutioFileID]?

  func body(content: Content) -> some View {
    content
      .putioAlert(
        copy.title(count: pending?.count ?? 1),
        isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
        message: pending.map { copy.message(names: $0.map(\.name)) },
        actions: removalActions
      )
      .putioAlert(
        copy.failureTitle(count: failed?.count ?? 1),
        isPresented: Binding(get: { failed != nil }, set: { if !$0 { failed = nil } }),
        message: failed.map { copy.failureMessage(count: $0.count) },
        actions: failureActions
      )
  }

  private var removalActions: [PutioAlertAction] {
    guard let fileIDs = pending?.map(\.id) else { return [] }
    return [
      PutioAlertAction(String(localized: "Cancel"), tier: .cancel, id: "downloads.remove-cancel"),
      PutioAlertAction(
        String(localized: "Remove"), tier: .destructive, id: "downloads.remove-confirm"
      ) {
        remove(fileIDs)
      },
    ]
  }

  private var failureActions: [PutioAlertAction] {
    guard let fileIDs = failed else { return [] }
    return [
      PutioAlertAction(String(localized: "OK"), tier: .cancel, id: "downloads.remove-failed-ok"),
      PutioAlertAction(
        String(localized: "Try again"), tier: .primary, id: "downloads.remove-failed-retry"
      ) {
        remove(fileIDs)
      },
    ]
  }

  private func remove(_ fileIDs: [PutioFileID]) {
    let present = fileIDs.filter { queue.item(for: $0) != nil }
    guard !present.isEmpty else { return }
    if queue.removeSaved(fileIDs: present) == nil {
      failed = present
    } else {
      onRemoved()
    }
  }
}

extension View {
  func putioOfflineRemovalAlert(
    _ pending: Binding<[PutioOfflineItem]?>, queue: PutioOfflineQueue, isPad: Bool,
    onRemoved: @escaping @MainActor () -> Void
  ) -> some View {
    modifier(
      PutioOfflineRemovalAlert(
        pending: pending, queue: queue, copy: PutioOfflineRemovalCopy(isPad: isPad),
        onRemoved: onRemoved))
  }
}
