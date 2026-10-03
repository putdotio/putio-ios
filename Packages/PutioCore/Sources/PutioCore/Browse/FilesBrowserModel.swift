import Foundation
import Observation

public enum PutioFolderLoadState: Equatable, Sendable {
  case loading
  case loaded(PutioFolderContents)
  case failed(PutioBrowserErrorPresentation)
}

@MainActor
@Observable
public final class PutioFolderModel {
  let folderID: PutioFileID

  public private(set) var state: PutioFolderLoadState
  public private(set) var refreshFailure: PutioBrowserErrorPresentation?
  public private(set) var isLoadingMore = false
  public private(set) var loadMoreFailure: PutioBrowserErrorPresentation?
  // Bumped whenever a load or mutation settles, or a continuation is
  // cancelled, so a continuation the settling work superseded, or one whose
  // row reappeared before the cancelled request unwound, starts again even
  // when the cursor is unchanged.
  private(set) var continuationEpoch: UInt64 = 0
  public private(set) var activeAction: PutioFileAction?
  public private(set) var actionOutcome: PutioFileActionOutcome?
  public private(set) var activeBulkAction: PutioBulkFileAction?
  public private(set) var bulkProgress: PutioBulkFileProgress?
  public private(set) var bulkOutcome: PutioBulkFileOutcome?
  /// Items the latest full load returned on the first page. A refresh after
  /// a mutation keeps only the first page, so later-page rows vanish until
  /// paging reaches them again.
  public private(set) var firstPageIDs: Set<PutioFileID> = []

  @ObservationIgnored private let load: PutioFolderLoad
  @ObservationIgnored private let continueLoad: PutioFolderContinue?
  @ObservationIgnored private let actions: PutioFileActions?
  @ObservationIgnored private var generation: UInt64 = 0
  @ObservationIgnored private var inFlightLoadGeneration: UInt64?
  @ObservationIgnored private var actionTask: Task<Void, Never>?
  // The refresh queued behind the latest mutation. Retained until the next
  // mutation starts (or a bulk retry consumes it) so late waiters read its
  // result instead of a cleared slot.
  @ObservationIgnored private var queuedRefresh: Task<Bool, Never>?
  @ObservationIgnored private var refreshRequestedWhileActionActive = false
  // Kept apart from `actionOutcome`, which screens clear once they show it.
  @ObservationIgnored private var lastCommittedAction: PutioFileAction?

  public init(
    folderID: PutioFileID,
    load: @escaping PutioFolderLoad,
    continueLoad: PutioFolderContinue? = nil,
    actions: PutioFileActions? = nil,
    initialContents: PutioFolderContents? = nil
  ) {
    self.folderID = folderID
    self.load = load
    self.continueLoad = continueLoad
    self.actions = actions
    state = initialContents.map { .loaded($0) } ?? .loading
    firstPageIDs = Set(initialContents?.items.map(\.id) ?? [])
  }

  public var supportsActions: Bool {
    actions != nil
  }

  public var canStartAction: Bool {
    guard supportsActions, !mutationIsActive, case .loaded = state else { return false }
    return true
  }

  public var canDelete: Bool { canStartAction && actions?.canDelete() == true }

  private var mutationIsActive: Bool {
    activeAction != nil || activeBulkAction != nil
  }

  public var isLoaded: Bool {
    if case .loaded = state { return true }
    return false
  }

  var canLoadMore: Bool {
    guard continueLoad != nil, !mutationIsActive, !isLoadingMore,
      inFlightLoadGeneration == nil, case .loaded(let contents) = state
    else { return false }
    return contents.nextCursor != nil
  }

  public struct ContinuationKey: Hashable {
    let cursor: String?
    let epoch: UInt64
  }

  var nextCursor: String? {
    if case .loaded(let contents) = state { return contents.nextCursor }
    return nil
  }

  /// Identity for the view task that fetches the next page.
  public var continuationKey: ContinuationKey {
    ContinuationKey(cursor: nextCursor, epoch: continuationEpoch)
  }

  /// The folder's own server-side sort, or `nil` when it inherits the account
  /// default. Inherited folders accept any explicit choice.
  public var sort: PutioFolderSort? {
    if case .loaded(let contents) = state { return contents.sort }
    return nil
  }

  /// Appends the next page. Any full reload in flight or started meanwhile
  /// supersedes the result through the load generation.
  @discardableResult
  public func loadMore() async -> Bool {
    guard let continueLoad, canLoadMore, case .loaded(let contents) = state,
      let cursor = contents.nextCursor
    else { return false }
    let requestGeneration = generation
    isLoadingMore = true
    loadMoreFailure = nil
    defer {
      if requestGeneration == generation {
        isLoadingMore = false
        if Task.isCancelled { continuationEpoch &+= 1 }
      }
    }

    do {
      let page = try await continueLoad(cursor)
      guard requestGeneration == generation, case .loaded(let current) = state else {
        return false
      }
      state = .loaded(current.appending(page))
      return true
    } catch {
      guard requestGeneration == generation else { return false }
      guard !Task.isCancelled, let presentation = PutioBrowserErrorPresentation(error: error)
      else { return false }
      loadMoreFailure = presentation
      return false
    }
  }

  /// Persists `sort` on the server, then reloads so the list reflects the
  /// server's order. The server call is the action; the reload is the single
  /// refresh queued behind it, so a reload failure surfaces as
  /// `refreshFailure` over the committed sort instead of failing the sort.
  public func setSort(_ sort: PutioFolderSort) async {
    guard let actions, canStartAction, case .loaded(let contents) = state else { return }
    guard sort != self.sort else { return }
    let action = PutioFileAction.sort(folderID: folderID, sort: sort)
    begin(action)

    await run(action, rollback: contents) { [folderID] in
      try await actions.setSort(folderID, sort)
      return contents.sorted(by: sort)
    }
    _ = await queuedRefresh?.value
  }

  /// Returns true when this call performed a successful load.
  @discardableResult
  public func loadIfNeeded() async -> Bool {
    // `.loading` means the initial attempt never settled — including a
    // cancelled attempt that is still unwinding when the screen is
    // re-entered. Starting a new request here supersedes that unwind via
    // the generation check, so a late restore cannot strand the spinner.
    guard case .loading = state else { return false }
    return await performLoad(mode: .replace)
  }

  public func retry() async {
    _ = await performLoad(mode: .replace)
  }

  @discardableResult
  public func refresh() async -> Bool {
    guard case .loaded = state else { return false }
    guard !mutationIsActive else {
      refreshRequestedWhileActionActive = true
      return false
    }
    return await performLoad(mode: .refresh)
  }

  /// Like `refresh()`, but a call that lands during a mutation waits for the
  /// refresh queued behind that mutation and reports its result, so a pending
  /// folder request can be consumed by the refresh that actually served it.
  public func refreshWhenIdle() async -> Bool {
    guard case .loaded = state else { return false }
    guard mutationIsActive else { return await performLoad(mode: .refresh) }
    refreshRequestedWhileActionActive = true
    await actionTask?.value
    guard let queuedRefresh else { return false }
    return await queuedRefresh.value
  }

  public func createFolder(name: String) async {
    guard let actions, canStartAction, case .loaded(let contents) = state else { return }
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    let action = PutioFileAction.createFolder(name: name)
    begin(action)

    await run(action, rollback: contents) { [folderID] in
      let folder = try await actions.createFolder(name, folderID)
      return contents.appending(folder)
    }
  }

  public func rename(_ item: PutioFileItem, to proposedName: String) async {
    guard let actions, canStartAction, case .loaded(let contents) = state else { return }
    guard let currentItem = contents.items.first(where: { $0.id == item.id }) else { return }
    let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name != currentItem.name else { return }
    let action = PutioFileAction.rename(
      fileID: currentItem.id,
      oldName: currentItem.name,
      newName: name
    )
    begin(action)
    state = .loaded(contents.replacing(currentItem.renamed(to: name)))

    await run(action, rollback: contents) {
      try await actions.renameFile(currentItem.id, name)
      return nil
    }
  }

  /// Returns true when the server confirmed the delete.
  @discardableResult
  public func delete(_ item: PutioFileItem) async -> Bool {
    guard let actions, canDelete, case .loaded(let contents) = state else { return false }
    guard let currentItem = contents.items.first(where: { $0.id == item.id }) else { return false }
    let action = PutioFileAction.delete(fileID: currentItem.id, name: currentItem.name)
    begin(action)
    state = .loaded(contents.removing(currentItem.id))

    return await run(action, rollback: contents) {
      try await actions.deleteFile(currentItem.id)
      return nil
    }
  }

  /// Marks a video watched or unwatched; the row's eye follows at once and
  /// rolls back if the server refuses.
  @discardableResult
  public func setWatched(_ item: PutioFileItem, _ watched: Bool) async -> Bool {
    guard let actions, canStartAction, case .loaded(let contents) = state else { return false }
    guard let currentItem = contents.items.first(where: { $0.id == item.id }),
      currentItem.kind == .video, currentItem.isWatched != watched
    else { return false }
    let action = PutioFileAction.setWatched(
      fileID: currentItem.id, parentID: currentItem.parentID, name: currentItem.name,
      watched: watched)
    begin(action)
    state = .loaded(contents.replacing(currentItem.withResumePosition(watched ? 1 : 0)))

    return await run(action, rollback: contents) {
      try await actions.setWatched(currentItem.id, watched)
      return nil
    }
  }

  public func move(_ item: PutioFileItem, to destination: PutioFolderRoute) async {
    guard let actions, canStartAction, case .loaded(let contents) = state else { return }
    guard let currentItem = contents.items.first(where: { $0.id == item.id }) else { return }
    guard destination.id != currentItem.parentID, destination.id != currentItem.id else { return }
    let action = PutioFileAction.move(
      fileID: currentItem.id,
      name: currentItem.name,
      sourceParentID: currentItem.parentID,
      destinationID: destination.id,
      destinationName: destination.title
    )
    begin(action)
    state = .loaded(contents.removing(currentItem.id))

    await run(action, rollback: contents) {
      try await actions.moveFile(currentItem.id, destination.id)
      return nil
    }
  }

  public func delete(_ selectedItems: [PutioFileItem]) async {
    guard
      let actions,
      canDelete,
      case .loaded(let contents) = state,
      let items = latestItems(for: selectedItems, in: contents)
    else { return }

    let action = PutioBulkFileAction.delete
    beginBulk(action, items: items)
    state = .loaded(contents.removing(Set(items.map(\.id))))

    await runBulk(
      action, items: items, batchSize: actions.batchSize, originalContents: contents
    ) { batch in
      try await actions.deleteFiles(batch.map(\.id))
    }
  }

  public func move(_ selectedItems: [PutioFileItem], to destination: PutioFolderRoute) async {
    guard
      let actions,
      canStartAction,
      case .loaded(let contents) = state,
      let items = latestItems(for: selectedItems, in: contents),
      items.allSatisfy({ $0.parentID != destination.id }),
      !items.contains(where: { $0.kind == .folder && $0.id == destination.id })
    else { return }

    let action = PutioBulkFileAction.move(destination: destination)
    beginBulk(action, items: items)
    state = .loaded(contents.removing(Set(items.map(\.id))))

    await runBulk(
      action, items: items, batchSize: actions.batchSize, originalContents: contents
    ) { batch in
      try await actions.moveFiles(batch.map(\.id), destination.id)
    }
  }

  /// Suspends until the active mutation, if any, has settled. Callers whose
  /// own task was cancelled mid-mutation use this to rejoin the outcome.
  public func waitForActiveAction() async {
    await actionTask?.value
  }

  public func clearActionOutcome() {
    actionOutcome = nil
  }

  public func clearBulkOutcome() {
    bulkOutcome = nil
  }

  func restoreBulkOutcome(_ outcome: PutioBulkFileOutcome) {
    guard bulkOutcome == nil, !mutationIsActive else { return }
    bulkOutcome = outcome
  }

  public func prepareBulkRetry(_ outcome: PutioBulkFileOutcome) async -> PutioBulkRetryPreparation {
    let refreshed: Bool
    if let queuedRefresh {
      refreshed = await queuedRefresh.value
      // A retry prepared later must fetch fresh state, not reuse this one.
      self.queuedRefresh = nil
    } else {
      refreshed = await refresh()
    }
    guard refreshed, case .loaded(let contents) = state else {
      restoreBulkOutcome(outcome)
      return .failed
    }
    bulkOutcome = nil
    return .ready(outcome.retryableItems(in: contents.items))
  }

  private func begin(_ action: PutioFileAction) {
    queuedRefresh = nil
    // Superseding an in-flight refresh drops its response, so the server
    // state it carried must be fetched again once this action settles.
    if inFlightLoadGeneration == generation {
      refreshRequestedWhileActionActive = true
    }
    generation &+= 1
    isLoadingMore = false
    loadMoreFailure = nil
    activeAction = action
    actionOutcome = nil
    lastCommittedAction = nil
  }

  private func beginBulk(_ action: PutioBulkFileAction, items: [PutioFileItem]) {
    queuedRefresh = nil
    if inFlightLoadGeneration == generation {
      refreshRequestedWhileActionActive = true
    }
    generation &+= 1
    isLoadingMore = false
    loadMoreFailure = nil
    activeBulkAction = action
    bulkOutcome = nil
    bulkProgress = PutioBulkFileProgress(
      action: action,
      completedCount: 0,
      totalCount: items.count,
      currentItem: items[0]
    )
  }

  // The mutation runs in a model-owned task: a screen that disappears
  // (tab switch, pop) cancels its view task, but the server may already
  // have applied the request, so the outcome must still be observed.
  /// Returns true when the server confirmed the action.
  @discardableResult
  private func run(
    _ action: PutioFileAction,
    rollback: PutioFolderContents,
    operation: @escaping @MainActor @Sendable () async throws -> PutioFolderContents?
  ) async -> Bool {
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let updated = try await operation()
        guard activeAction == action else { return }
        if let updated {
          state = .loaded(updated)
        }
        // A committed mutation invalidates the server's cursor and may
        // change where rows sit under the folder's sort, so the folder
        // reloads from a fresh first page rather than trusting the
        // optimistic rows or continuing the stale listing.
        if case .loaded(let settled) = state {
          state = .loaded(settled.droppingCursor())
          refreshRequestedWhileActionActive = true
        }
        activeAction = nil
        actionOutcome = .succeeded(action)
        lastCommittedAction = action
      } catch {
        settleFailure(action: action, error: error, rollback: rollback)
      }
      startQueuedRefreshIfNeeded()
      continuationEpoch &+= 1
    }
    actionTask = task
    await task.value
    return lastCommittedAction == action
  }

  /// Sends the items in batches. A thrown batch fails all of its items; a
  /// rate-limited item defers every later batch for the retry.
  private func runBulk(
    _ action: PutioBulkFileAction,
    items: [PutioFileItem],
    batchSize: Int,
    originalContents: PutioFolderContents,
    operation:
      @escaping @MainActor @Sendable ([PutioFileItem]) async throws -> [PutioFileID:
      Error]
  ) async {
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      var removedIDs = Set(items.map(\.id))
      var succeeded: [PutioFileItem] = []
      var failures: [PutioBulkFileItemFailure] = []
      let batches = stride(from: 0, to: items.count, by: batchSize).map {
        Array(items[$0..<min($0 + batchSize, items.count)])
      }
      var completedCount = 0

      for (index, batch) in batches.enumerated() {
        let batchFailures: [PutioFileID: Error]
        do {
          batchFailures = try await operation(batch)
        } catch {
          batchFailures = Dictionary(uniqueKeysWithValues: batch.map { ($0.id, error) })
        }
        var rateLimited = false
        for item in batch {
          guard let error = batchFailures[item.id] else {
            succeeded.append(item)
            continue
          }
          let failure = itemFailure(for: action, item: item, error: error)
          removedIDs.remove(item.id)
          failures.append(failure)
          if failure.error == .rateLimited { rateLimited = true }
        }
        completedCount += batch.count
        if rateLimited {
          for deferredItem in batches.dropFirst(index + 1).joined() {
            removedIDs.remove(deferredItem.id)
            failures.append(
              itemFailure(for: action, item: deferredItem, error: PutioRuntimeError.rateLimited)
            )
          }
        }
        if !batchFailures.isEmpty || rateLimited {
          state = .loaded(originalContents.removing(removedIDs))
        }
        if rateLimited { break }

        if let nextItem = batches.dropFirst(index + 1).first?.first {
          bulkProgress = PutioBulkFileProgress(
            action: action,
            completedCount: completedCount,
            totalCount: items.count,
            currentItem: nextItem
          )
        }
      }

      guard activeBulkAction == action else { return }
      state = .loaded(originalContents.removing(removedIDs).droppingCursor())
      activeBulkAction = nil
      bulkProgress = nil
      bulkOutcome = PutioBulkFileOutcome(
        action: action,
        succeeded: succeeded,
        failures: failures
      )
      refreshRequestedWhileActionActive = true
      startQueuedRefreshIfNeeded()
      continuationEpoch &+= 1
    }
    actionTask = task
    await task.value
  }

  private func latestItems(
    for selectedItems: [PutioFileItem],
    in contents: PutioFolderContents
  ) -> [PutioFileItem]? {
    let selectedIDs = selectedItems.map(\.id)
    guard !selectedIDs.isEmpty, Set(selectedIDs).count == selectedIDs.count else { return nil }
    let itemsByID = Dictionary(uniqueKeysWithValues: contents.items.map { ($0.id, $0) })
    let latestItems = selectedIDs.compactMap { itemsByID[$0] }
    guard latestItems.count == selectedIDs.count else { return nil }
    return latestItems
  }

  private func itemFailure(
    for action: PutioBulkFileAction,
    item: PutioFileItem,
    error: Error
  ) -> PutioBulkFileItemFailure {
    PutioBulkFileItemFailure(
      item: item,
      error: error as? PutioRuntimeError ?? .unknown,
      presentation: PutioFileActionFailure(
        action: singleAction(for: action, item: item), error: error)
    )
  }

  private func singleAction(
    for action: PutioBulkFileAction,
    item: PutioFileItem
  ) -> PutioFileAction {
    switch action {
    case .delete:
      return .delete(fileID: item.id, name: item.name)
    case .move(let destination):
      return .move(
        fileID: item.id,
        name: item.name,
        sourceParentID: item.parentID,
        destinationID: destination.id,
        destinationName: destination.title
      )
    }
  }

  // The refresh outlives the mutation call so the caller's UI lock releases
  // as soon as the action settles, and a cancelled caller cannot abort it.
  private func startQueuedRefreshIfNeeded() {
    guard refreshRequestedWhileActionActive else { return }
    refreshRequestedWhileActionActive = false
    queuedRefresh = Task { @MainActor [weak self] in
      guard let self else { return false }
      return await refresh()
    }
  }

  private func performLoad(mode: LoadMode) async -> Bool {
    let previousState = state
    let previousRefreshFailure = refreshFailure
    generation += 1
    let requestGeneration = generation
    inFlightLoadGeneration = requestGeneration
    defer {
      if inFlightLoadGeneration == requestGeneration {
        inFlightLoadGeneration = nil
      }
      // A superseded load settling late must not rekey the footer and cancel
      // a continuation the current load legitimately started.
      if requestGeneration == generation {
        continuationEpoch &+= 1
      }
    }

    isLoadingMore = false
    loadMoreFailure = nil
    switch mode {
    case .replace:
      state = .loading
      refreshFailure = nil
    case .refresh:
      refreshFailure = nil
    }

    do {
      try Task.checkCancellation()
      let contents = try await load(folderID)
      try Task.checkCancellation()
      guard requestGeneration == generation else { return false }
      state = .loaded(contents)
      firstPageIDs = Set(contents.items.map(\.id))
      refreshFailure = nil
      return true
    } catch {
      guard requestGeneration == generation else { return false }
      if Task.isCancelled {
        state = previousState
        refreshFailure = previousRefreshFailure
        return false
      }

      guard let presentation = PutioBrowserErrorPresentation(error: error) else {
        state = previousState
        refreshFailure = nil
        return false
      }
      switch mode {
      case .replace:
        state = .failed(presentation)
        refreshFailure = nil
      case .refresh:
        if presentation.kind == .notFound {
          state = .failed(presentation)
          refreshFailure = nil
        } else {
          state = previousState
          refreshFailure = presentation
        }
      }
      return false
    }
  }

  private func settleFailure(
    action: PutioFileAction,
    error: Error,
    rollback: PutioFolderContents
  ) {
    guard activeAction == action else { return }
    state = .loaded(rollback)
    activeAction = nil
    guard !Task.isCancelled, !(error is CancellationError) else {
      actionOutcome = nil
      return
    }
    actionOutcome = PutioFileActionFailure(
      action: action,
      error: error
    ).map {
      .failed(action, $0)
    }
  }
}

extension PutioFolderContents {
  fileprivate func appending(_ item: PutioFileItem) -> PutioFolderContents {
    withItems(items + [item])
  }

  /// Merges a continuation page. The page's cursor replaces this one; rows
  /// already present (the server re-sent an item after a mutation) are
  /// skipped so `List` identity stays unique.
  fileprivate func appending(_ page: PutioFolderContents) -> PutioFolderContents {
    let knownIDs = Set(items.map(\.id))
    return PutioFolderContents(
      folder: folder,
      items: items + page.items.filter { !knownIDs.contains($0.id) },
      nextCursor: page.nextCursor,
      sort: sort
    )
  }

  fileprivate func replacing(_ item: PutioFileItem) -> PutioFolderContents {
    withItems(items.map { $0.id == item.id ? item : $0 })
  }

  fileprivate func removing(_ id: PutioFileID) -> PutioFolderContents {
    withItems(items.filter { $0.id != id })
  }

  fileprivate func removing(_ ids: Set<PutioFileID>) -> PutioFolderContents {
    withItems(items.filter { !ids.contains($0.id) })
  }

  fileprivate func sorted(by sort: PutioFolderSort) -> PutioFolderContents {
    PutioFolderContents(folder: folder, items: items, nextCursor: nextCursor, sort: sort)
  }

  fileprivate func droppingCursor() -> PutioFolderContents {
    PutioFolderContents(folder: folder, items: items, nextCursor: nil, sort: sort)
  }

  private func withItems(_ items: [PutioFileItem]) -> PutioFolderContents {
    PutioFolderContents(folder: folder, items: items, nextCursor: nextCursor, sort: sort)
  }
}

extension PutioFileItem {
  fileprivate func renamed(to name: String) -> PutioFileItem {
    PutioFileItem(
      id: id,
      parentID: parentID,
      name: name,
      kind: kind,
      sizeBytes: sizeBytes,
      createdAt: createdAt,
      updatedAt: updatedAt,
      resumePositionSeconds: resumePositionSeconds,
      isShared: isShared
    )
  }

  fileprivate func withResumePosition(_ seconds: Int) -> PutioFileItem {
    PutioFileItem(
      id: id,
      parentID: parentID,
      name: name,
      kind: kind,
      sizeBytes: sizeBytes,
      createdAt: createdAt,
      updatedAt: updatedAt,
      resumePositionSeconds: seconds,
      isShared: isShared
    )
  }
}

private enum LoadMode {
  case replace
  case refresh
}
