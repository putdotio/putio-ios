import Observation
import PutioCore
import SwiftUI

/// Runs single-item file actions on rows no folder model owns, such as search
/// results. Screens showing the item refresh through folder refresh requests.
@MainActor
@Observable
final class PutioFileItemActionModel {
  private(set) var activeAction: PutioFileAction?
  private(set) var outcome: PutioFileActionOutcome?

  @ObservationIgnored private let actions: PutioFileActions

  init(actions: PutioFileActions) {
    self.actions = actions
  }

  var canStartAction: Bool { activeAction == nil }

  var canDelete: Bool { canStartAction && actions.canDelete() }

  func rename(_ item: PutioFileItem, to proposedName: String) async {
    let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name != item.name else { return }
    await run(.rename(fileID: item.id, oldName: item.name, newName: name)) { [actions] in
      try await actions.renameFile(item.id, name)
    }
  }

  func delete(_ item: PutioFileItem) async {
    guard canDelete else { return }
    await run(.delete(fileID: item.id, name: item.name)) { [actions] in
      try await actions.deleteFile(item.id)
    }
  }

  func move(_ item: PutioFileItem, to destination: PutioFolderRoute) async {
    guard destination.id != item.parentID, destination.id != item.id else { return }
    let action = PutioFileAction.move(
      fileID: item.id,
      name: item.name,
      sourceParentID: item.parentID,
      destinationID: destination.id,
      destinationName: destination.title
    )
    await run(action) { [actions] in
      try await actions.moveFile(item.id, destination.id)
    }
  }

  func clearOutcome() {
    outcome = nil
  }

  private func run(
    _ action: PutioFileAction,
    operation: @escaping @MainActor @Sendable () async throws -> Void
  ) async {
    guard canStartAction else { return }
    activeAction = action
    outcome = nil
    // A model-owned task: the server may apply the request even when the
    // caller goes away, so the outcome must still be observed.
    let task = Task { @MainActor in
      do {
        try await operation()
        outcome = .succeeded(action)
      } catch {
        outcome = PutioFileActionFailure(action: action, error: error).map {
          .failed(action, $0)
        }
      }
      activeAction = nil
    }
    await task.value
  }
}

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

/// Presents the rename editor, move picker, and permanent-delete confirmation
/// for `request`, runs the action, and reports it with a toast.
struct PutioFileItemActionsHost: ViewModifier {
  @Binding var request: PutioFileItemActionRequest?
  let model: PutioFileItemActionModel
  let actions: PutioFileActions
  let load: PutioFolderLoad
  let continueLoad: PutioFolderContinue
  let trashEnabled: Bool
  let refreshRequests: PutioFolderRefreshRequests

  @State private var editorName = ""
  @State private var toast: PutioToast?

  func body(content: Content) -> some View {
    content
      .sheet(item: renameBinding) { item in
        NavigationStack {
          Form {
            TextField("Name", text: $editorName)
              .accessibilityIdentifier("files.action-name")
          }
          .navigationTitle("Rename Item")
          .navigationBarTitleDisplayMode(.inline)
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              Button("Cancel", role: .cancel) { request = nil }
            }
            ToolbarItem(placement: .confirmationAction) {
              Button("Rename") {
                let name = editorName
                request = nil
                perform { await model.rename(item, to: name) }
              }
              .disabled(!isValidName(for: item))
              .accessibilityIdentifier("files.action-submit")
            }
          }
        }
        .presentationDetents([.height(220)])
        .onAppear { editorName = item.name }
      }
      .sheet(item: moveBinding) { item in
        PutioMovePicker(
          items: [item],
          load: actions.loadFolders ?? load,
          continueLoad: continueLoad,
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
        // Trash is recoverable, so only a permanent deletion asks first.
        guard trashEnabled, case .delete(let item) = request else { return }
        self.request = nil
        perform { await model.delete(item) }
      }
      .putioToast($toast)
      .task(id: toast) {
        guard let presentedToast = toast else { return }
        try? await Task.sleep(for: .seconds(3))
        guard !Task.isCancelled, toast == presentedToast else { return }
        toast = nil
      }
  }

  private var deletion: PutioFileDeletionPresentation {
    PutioFileDeletionPresentation(trashEnabled: trashEnabled)
  }

  private var deletionTitle: String {
    guard case .delete(let item) = request else { return deletion.actionTitle }
    return deletion.confirmationTitle(itemName: item.name)
  }

  private func isValidName(for item: PutioFileItem) -> Bool {
    let name = editorName.trimmingCharacters(in: .whitespacesAndNewlines)
    return !name.isEmpty && name != item.name
  }

  private func perform(_ operation: @escaping @MainActor () async -> Void) {
    Task {
      await operation()
      present(model.outcome)
    }
  }

  private func present(_ outcome: PutioFileActionOutcome?) {
    guard let outcome else { return }
    let action =
      switch outcome {
      case .succeeded(let action), .failed(let action, _): action
      }
    // A failed mutation may still have reached the server.
    switch action {
    case .delete:
      // A deleted folder can contain any mounted folder.
      refreshRequests.requestAllLoadedFolders()
    case .rename(let fileID, _, _):
      refreshRequests.requestAllLoadedFolders()
      refreshRequests.request(folderID: fileID)
    case .move(let fileID, _, let sourceParentID, let destinationID, _):
      refreshRequests.request(folderID: sourceParentID)
      refreshRequests.request(folderID: destinationID)
      refreshRequests.request(folderID: fileID)
    case .createFolder, .sort:
      break
    }
    switch outcome {
    case .succeeded(.rename(_, _, let newName)):
      toast = PutioToast(variant: .success, title: "Item renamed", message: newName)
    case .succeeded(.delete(_, let name)):
      toast = PutioToast(variant: .success, title: deletion.singleSuccessTitle, message: name)
    case .succeeded(.move(_, let name, _, _, let destinationName)):
      toast = PutioToast(
        variant: .success, title: "Item moved", message: "\(name) to \(destinationName)")
    case .succeeded:
      break
    case .failed(let action, let failure):
      let title: String
      if case .delete = action {
        title = deletion.singleFailureTitle
      } else {
        title = failure.title
      }
      toast = PutioToast(variant: .danger, title: title, message: failure.message)
    }
    model.clearOutcome()
  }

  private var renameBinding: Binding<PutioFileItem?> {
    Binding(
      get: {
        guard case .rename(let item) = request else { return nil }
        return item
      },
      set: { if $0 == nil, case .rename = request { request = nil } }
    )
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
