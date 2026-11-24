import Observation
import PutioCore
import SwiftUI

/// Presents the rename alert, move picker, and permanent-delete confirmation
/// for `request`, runs the action, and reports it with a toast.
struct PutioFileItemActionsHost: ViewModifier {
  @Binding var request: PutioFileItemActionRequest?
  let model: PutioFileItemActionModel
  let actions: PutioFileActions
  let load: PutioFolderLoad
  let continueLoad: PutioFolderContinue
  let trashEnabled: Bool
  let refreshRequests: PutioFolderRefreshRequests

  @State private var toast: PutioToast?
  @State private var renameAlert: PutioTextAlert?
  @State private var confirmAlert: PutioConfirmAlert?

  func body(content: Content) -> some View {
    content
      .putioTextAlert($renameAlert)
      .sheet(item: moveBinding) { item in
        PutioMovePicker(
          items: [item],
          load: actions.loadFolders ?? load,
          continueLoad: actions.continueFolders ?? continueLoad,
          actions: actions,
          refreshRequests: refreshRequests,
          onMove: { destination in
            await model.move(item, to: destination)
            switch model.settleMove(of: item) {
            case .nameTaken(let name): return .nameTaken(name)
            case .settled(let outcome):
              present(outcome)
              return .closed
            }
          }
        )
      }
      .putioConfirmAlert($confirmAlert)
      .onChange(of: request) { _, request in
        guard let step = request?.step(trashEnabled: trashEnabled) else { return }
        switch step {
        case .askForName(let item):
          self.request = nil
          renameAlert = Self.renameAlert(for: item, model: model)
        case .trash(let item):
          self.request = nil
          perform { await model.delete(item) }
        case .confirmPermanentDelete(let item):
          self.request = nil
          confirmAlert = PutioFileDeletionPresentation.permanentDeleteAlert(itemCount: 1) {
            perform { await model.delete(item, permanently: true) }
          }
        case .setWatched(let item, let watched):
          self.request = nil
          perform { await model.setWatched(item, watched) }
        case .pickDestination:
          break
        }
      }
      .putioToast($toast)
  }

  private static func renameAlert(
    for item: PutioFileItem, model: PutioFileItemActionModel
  ) -> PutioTextAlert {
    PutioTextAlert(
      title: String(localized: "Rename"),
      initialText: item.name,
      submitTitle: String(localized: "Rename"),
      failureText: String(localized: "Couldn’t rename.")
    ) { name in
      await model.rename(item, to: name)
      try model.settleRename(of: item)
    }
  }

  private func perform(_ operation: @escaping @MainActor () async -> Void) {
    Task {
      await operation()
      present(model.outcome)
    }
  }

  private func present(_ outcome: PutioFileActionOutcome?) {
    guard let outcome else { return }
    if let title = outcome.toastTitle(trashEnabled: trashEnabled) {
      toast = PutioToast(title)
    }
    model.clearOutcome()
  }

  private var moveBinding: Binding<PutioFileItem?> {
    Binding(
      get: {
        guard case .move(let item) = request else { return nil }
        return item
      },
      set: { if $0 == nil, case .move = request { request = nil } }
    )
  }
}
