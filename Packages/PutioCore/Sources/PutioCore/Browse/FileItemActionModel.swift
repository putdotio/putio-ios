import Observation

/// Runs single-item file actions on rows no folder model owns, such as search
/// results. Every settled action, failed ones included since the server may
/// have applied them, requests a refresh of the screens that show the item;
/// the refresh revision also re-runs the search.
@MainActor
@Observable
public final class PutioFileItemActionModel {
  private(set) var activeAction: PutioFileAction?
  public private(set) var outcome: PutioFileActionOutcome?
  /// Rows to leave out of the results: a Trash move hides its row as it is
  /// tapped, and a committed delete keeps it hidden until the results reload.
  /// A delete that did not commit shows the row again.
  public private(set) var hiddenIDs: Set<PutioFileID> = []

  @ObservationIgnored private let actions: PutioFileActions
  @ObservationIgnored private let refreshRequests: PutioFolderRefreshRequests

  public init(actions: PutioFileActions, refreshRequests: PutioFolderRefreshRequests) {
    self.actions = actions
    self.refreshRequests = refreshRequests
  }

  /// Hides a row in the same transaction as the tap that moves it to Trash.
  public func hideForTrash(_ item: PutioFileItem) {
    hiddenIDs.insert(item.id)
  }

  /// The results reloaded, so they now reflect every settled delete.
  public func revealHiddenItems() {
    hiddenIDs = []
  }

  public var canStartAction: Bool { activeAction == nil }

  public var canDelete: Bool { canStartAction && actions.canDelete() }

  public func rename(_ item: PutioFileItem, to proposedName: String) async {
    let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name != item.name else { return }
    await run(.rename(fileID: item.id, oldName: item.name, newName: name)) { [actions] in
      try await actions.renameFile(item.id, name)
    }
  }

  public func delete(_ item: PutioFileItem) async {
    let settled: PutioFileActionOutcome? =
      canDelete
      ? await run(.delete(fileID: item.id, name: item.name)) { [actions] in
        try await actions.deleteFile(item.id)
        // Hidden before the refresh this delete requests can reload results.
        self.hiddenIDs.insert(item.id)
      } : nil
    if case .succeeded = settled { return }
    hiddenIDs.remove(item.id)
  }

  public func move(_ item: PutioFileItem, to destination: PutioFolderRoute) async {
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

  public func clearOutcome() {
    outcome = nil
  }

  /// Returns the settled outcome, or `nil` when the action did not start or
  /// its failure has no presentation.
  @discardableResult
  private func run(
    _ action: PutioFileAction,
    operation: @escaping @MainActor @Sendable () async throws -> Void
  ) async -> PutioFileActionOutcome? {
    guard canStartAction else { return nil }
    activeAction = action
    outcome = nil
    // A model-owned task: the server may apply the request even when the
    // caller goes away, so the outcome must still be observed.
    let task = Task { @MainActor in
      let settled: PutioFileActionOutcome?
      do {
        try await operation()
        settled = .succeeded(action)
      } catch {
        settled = PutioFileActionFailure(action: action, error: error).map {
          .failed(action, $0)
        }
      }
      requestRefreshes(after: action)
      outcome = settled
      activeAction = nil
      return settled
    }
    return await task.value
  }

  private func requestRefreshes(after action: PutioFileAction) {
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
  }
}
