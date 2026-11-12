import Observation
import PutioCore
import SwiftUI

enum PutioFileItemActionRequest: Equatable, Identifiable {
  case rename(PutioFileItem)
  case move(PutioFileItem)
  case delete(PutioFileItem)

  var id: String {
    switch self {
    case .rename(let item): "rename.\(item.id.rawValue)"
    case .move(let item): "move.\(item.id.rawValue)"
    case .delete(let item): "delete.\(item.id.rawValue)"
    }
  }
}

/// The Move, Rename, and Trash or Delete buttons a folder row offers.
struct PutioFileItemActionButtons: View {
  let item: PutioFileItem
  let trashEnabled: Bool
  let isDisabled: Bool
  let canDelete: Bool
  let onRequest: @MainActor (PutioFileItemActionRequest) -> Void

  var body: some View {
    ControlGroup {
      moveButton
    }
    Section {
      Button {
        onRequest(.rename(item))
      } label: {
        Label("Rename", systemImage: "pencil")
      }
      .disabled(isDisabled)
      .accessibilityIdentifier("files.rename.\(item.id.rawValue)")
    }
    Section {
      deleteButton
    }
  }

  var moveButton: some View {
    Button {
      onRequest(.move(item))
    } label: {
      Label("Move", systemImage: "folder")
    }
    .disabled(isDisabled)
    .accessibilityIdentifier("files.move.\(item.id.rawValue)")
  }

  var deleteButton: some View {
    Button(role: .destructive) {
      onRequest(.delete(item))
    } label: {
      Label(
        PutioFileDeletionPresentation(trashEnabled: trashEnabled).actionTitle,
        systemImage: "trash")
    }
    .disabled(isDisabled || !canDelete)
    .accessibilityIdentifier("files.delete.\(item.id.rawValue)")
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
            request = nil
            perform { await model.move(item, to: destination) }
          }
        )
      }
      .confirmationDialog(
        deletionTitle,
        isPresented: deleteConfirmationPresented,
        titleVisibility: .visible
      ) {
        Button(deletion.actionTitle, role: .destructive) {
          guard case .delete(let item) = request else { return }
          request = nil
          perform { await model.delete(item) }
        }
        .disabled(!model.canDelete)
        .accessibilityIdentifier("files.delete-confirm")
        Button("Cancel", role: .cancel) { request = nil }
      } message: {
        Text(deletion.confirmationMessage(itemCount: 1))
      }
      .onChange(of: request) { _, request in
        if case .rename(let item) = request {
          self.request = nil
          renameAlert = Self.renameAlert(for: item, model: model)
          return
        }
        // Trash is recoverable, so only a permanent deletion asks first.
        guard trashEnabled, case .delete(let item) = request else { return }
        self.request = nil
        perform { await model.delete(item) }
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
      let outcome = model.outcome
      model.clearOutcome()
      guard case .succeeded = outcome else { throw PutioRenameFailure() }
    }
  }

  private var deletion: PutioFileDeletionPresentation {
    PutioFileDeletionPresentation(trashEnabled: trashEnabled)
  }

  private var deletionTitle: String {
    guard case .delete(let item) = request else { return deletion.actionTitle }
    return deletion.confirmationTitle(itemName: item.name)
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
    case .succeeded(.delete):
      toast = PutioToast(deletion.singleSuccessTitle)
    case .succeeded(.move):
      toast = PutioToast(String(localized: "Item moved"))
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

  private var deleteConfirmationPresented: Binding<Bool> {
    Binding(
      get: {
        guard !trashEnabled, case .delete = request else { return false }
        return true
      },
      set: { if !$0, case .delete = request { request = nil } }
    )
  }
}

private struct PutioRenameFailure: Error {}
