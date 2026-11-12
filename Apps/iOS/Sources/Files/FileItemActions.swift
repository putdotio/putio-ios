import Observation
import PutioCore
import SwiftUI

enum PutioFileItemActionRequest: Equatable, Identifiable {
  case rename(PutioFileItem)
  case move(PutioFileItem)
  case delete(PutioFileItem)
  case setWatched(PutioFileItem, Bool)

  var id: String {
    switch self {
    case .rename(let item): "rename.\(item.id.rawValue)"
    case .move(let item): "move.\(item.id.rawValue)"
    case .delete(let item): "delete.\(item.id.rawValue)"
    case .setWatched(let item, let watched): "watched.\(item.id.rawValue).\(watched)"
    }
  }
}

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
            if model.outcome?.isNameTaken(movingFileID: item.id) == true {
              model.clearOutcome()
              return .nameTaken(item.name)
            }
            present(model.outcome)
            return .closed
          }
        )
      }
      .putioConfirmAlert($confirmAlert)
      .onChange(of: request) { _, request in
        switch request {
        case .rename(let item):
          self.request = nil
          renameAlert = Self.renameAlert(for: item, model: model)
        case .delete(let item):
          self.request = nil
          // Trash is recoverable, so only a permanent deletion asks first.
          if trashEnabled {
            perform { await model.delete(item) }
          } else {
            confirmAlert = PutioFileDeletionCopy.permanentDeleteAlert(itemCount: 1) {
              perform { await model.delete(item, permanently: true) }
            }
          }
        case .setWatched(let item, let watched):
          self.request = nil
          perform { await model.setWatched(item, watched) }
        case .move, nil:
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
      guard case .succeeded(.rename) = model.outcome else {
        if case .failed(.rename, _) = model.outcome { model.clearOutcome() }
        throw PutioRenameFailure()
      }
      model.clearOutcome()
    }
  }

  private var deletion: PutioFileDeletionPresentation {
    PutioFileDeletionPresentation(trashEnabled: trashEnabled)
  }

  private func perform(_ operation: @escaping @MainActor () async -> Void) {
    Task {
      await operation()
      present(model.outcome)
    }
  }

  private func present(_ outcome: PutioFileActionOutcome?) {
    guard let outcome else { return }
    switch outcome {
    case .succeeded(.delete(_, _, let permanently)):
      toast = PutioToast(
        permanently ? PutioFileDeletionCopy.deleted : PutioFileDeletionCopy.trashed)
    case .succeeded(.move):
      toast = PutioToast(PutioMoveCopy.moved(1))
    case .succeeded(.setWatched(_, _, _, let watched)):
      toast = PutioToast(
        watched
          ? String(localized: "Marked as watched") : String(localized: "Marked as unwatched"))
    case .succeeded:
      break
    case .failed(let action, let failure):
      let title: String
      if case .delete = action {
        title = deletion.singleFailureTitle
      } else {
        title = failure.title
      }
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

private struct PutioRenameFailure: Error {}
