import Foundation
import Observation
import PutioCore

typealias PutioFolderLoad =
  @MainActor @Sendable (PutioFileID) async throws -> PutioFolderContents
typealias PutioFolderCreate =
  @MainActor @Sendable (String, PutioFileID) async throws -> PutioFileItem
typealias PutioFileRename =
  @MainActor @Sendable (PutioFileID, String) async throws -> Void
typealias PutioFileDelete =
  @MainActor @Sendable (PutioFileID) async throws -> Void
typealias PutioFileMove =
  @MainActor @Sendable (PutioFileID, PutioFileID) async throws -> Void

struct PutioFileActions: Sendable {
  let createFolder: PutioFolderCreate
  let renameFile: PutioFileRename
  let deleteFile: PutioFileDelete
  let moveFile: PutioFileMove

  init(runtime: PutioRuntime) {
    createFolder = { name, parentID in
      try await runtime.createFolder(name: name, parentID: parentID)
    }
    renameFile = { fileID, name in
      try await runtime.renameFile(fileID: fileID, name: name)
    }
    deleteFile = { fileID in
      try await runtime.deleteFile(fileID: fileID)
    }
    moveFile = { fileID, parentID in
      try await runtime.moveFile(fileID: fileID, to: parentID)
    }
  }

  init(
    createFolder: @escaping PutioFolderCreate,
    renameFile: @escaping PutioFileRename,
    deleteFile: @escaping PutioFileDelete,
    moveFile: @escaping PutioFileMove = { _, _ in throw PutioRuntimeError.unknown }
  ) {
    self.createFolder = createFolder
    self.renameFile = renameFile
    self.deleteFile = deleteFile
    self.moveFile = moveFile
  }
}

struct PutioFolderRoute: Identifiable, Sendable {
  let id: PutioFileID
  let title: String

  static let root = PutioFolderRoute(id: .root, title: "Files")
}

@Observable
final class PutioFolderRefreshRequests {
  struct Sequence: Equatable, Sendable {
    let folder: UInt64
    let allFolders: UInt64
  }

  private var sequences: [PutioFileID: UInt64] = [:]
  private var allFoldersSequence: UInt64 = 0
  private var consumed: [PutioFileID: Sequence] = [:]

  func request(folderID: PutioFileID) {
    sequences[folderID, default: 0] &+= 1
  }

  func requestAllLoadedFolders() {
    allFoldersSequence &+= 1
  }

  /// The request `folderID` has not yet honored, or nil. A folder screen
  /// consumes it after refreshing so later appearances do not refresh again.
  func sequence(for folderID: PutioFileID) -> Sequence? {
    let current = Sequence(
      folder: sequences[folderID, default: 0], allFolders: allFoldersSequence)
    guard current.folder > 0 || current.allFolders > 0 else { return nil }
    guard consumed[folderID] != current else { return nil }
    return current
  }

  func markConsumed(_ sequence: Sequence, for folderID: PutioFileID) {
    consumed[folderID] = sequence
  }
}

struct PutioMovePickerPolicy: Sendable {
  let items: [PutioFileItem]

  init(item: PutioFileItem) {
    items = [item]
  }

  init(items: [PutioFileItem]) {
    self.items = items
  }

  func canMove(to destination: PutioFolderRoute) -> Bool {
    !items.isEmpty
      && items.allSatisfy { item in
        destination.id != item.parentID
          && !(item.kind == .folder && destination.id == item.id)
      }
  }

  func folders(in contents: PutioFolderContents) -> [PutioFileItem] {
    let selectedFolderIDs = Set(
      items.lazy.filter { $0.kind == .folder }.map(\.id)
    )
    return contents.items.filter { candidate in
      candidate.kind == .folder && !selectedFolderIDs.contains(candidate.id)
    }
  }
}

extension PutioFolderRoute: Hashable {
  static func == (lhs: PutioFolderRoute, rhs: PutioFolderRoute) -> Bool {
    lhs.id == rhs.id
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }
}

struct PutioFileRoute: Identifiable, Hashable, Sendable {
  let item: PutioFileItem

  var id: PutioFileID {
    item.id
  }

  var videoPlaybackRoute: PutioVideoRoute? {
    guard item.kind == .video else { return nil }
    return PutioVideoRoute(id: item.id, parentID: item.parentID, title: item.name)
  }
}

struct PutioVideoRoute: Identifiable, Sendable {
  let id: PutioFileID
  let parentID: PutioFileID
  let title: String
  let initialResolution: PutioPlaybackResolution?

  init(
    id: PutioFileID,
    parentID: PutioFileID,
    title: String,
    initialResolution: PutioPlaybackResolution? = nil
  ) {
    self.id = id
    self.parentID = parentID
    self.title = title
    self.initialResolution = initialResolution
  }

  init(nextVideo: PutioPlayableNextVideo) {
    self.init(
      id: nextVideo.video.id,
      parentID: nextVideo.video.parentID,
      title: nextVideo.video.name,
      initialResolution: nextVideo.initialResolution
    )
  }
}

enum PutioBrowserErrorKind: Hashable, Sendable {
  case notFound
  case rateLimited
  case transient
  case invalidResponse
  case unknown
}

struct PutioBrowserErrorPresentation: Equatable, Sendable {
  let kind: PutioBrowserErrorKind
  let title: String
  let message: String

  init?(error: Error) {
    switch error as? PutioRuntimeError {
    case .authenticationRequired, .sessionExpired:
      return nil
    case .notFound:
      self.init(
        kind: .notFound,
        title: "Folder not found",
        message: "It may have been moved or deleted."
      )
    case .rateLimited:
      self.init(
        kind: .rateLimited,
        title: "Could not load files",
        message: "put.io is receiving too many requests. Try again shortly."
      )
    case .transient:
      self.init(
        kind: .transient,
        title: "Could not load files",
        message: "Check your connection and try again."
      )
    case .invalidResponse:
      self.init(
        kind: .invalidResponse,
        title: "Could not load files",
        message: "put.io returned an invalid response. Try again."
      )
    case .unknown, nil:
      self.init(
        kind: .unknown,
        title: "Could not load files",
        message: "put.io could not complete the request. Try again."
      )
    }
  }

  private init(kind: PutioBrowserErrorKind, title: String, message: String) {
    self.kind = kind
    self.title = title
    self.message = message
  }
}

enum PutioFolderLoadState: Equatable, Sendable {
  case loading
  case loaded(PutioFolderContents)
  case failed(PutioBrowserErrorPresentation)
}

enum PutioFileAction: Equatable, Sendable {
  case createFolder(name: String)
  case rename(fileID: PutioFileID, oldName: String, newName: String)
  case delete(fileID: PutioFileID, name: String)
  case move(
    fileID: PutioFileID,
    name: String,
    sourceParentID: PutioFileID,
    destinationID: PutioFileID,
    destinationName: String
  )
}

struct PutioFileActionFailure: Equatable, Sendable {
  let title: String
  let message: String

  init?(action: PutioFileAction, error: Error) {
    guard let browserFailure = PutioBrowserErrorPresentation(error: error) else {
      return nil
    }
    switch action {
    case .createFolder:
      title = "Could not create folder"
    case .rename:
      title = "Could not rename item"
    case .delete:
      title = "Could not remove item"
    case .move:
      title = "Could not move item"
    }
    message = browserFailure.message
  }
}

enum PutioFileActionOutcome: Equatable, Sendable {
  case succeeded(PutioFileAction)
  case failed(PutioFileAction, PutioFileActionFailure)
}

enum PutioBulkFileAction: Equatable, Sendable {
  case delete
  case move(destination: PutioFolderRoute)
}

struct PutioBulkFileProgress: Equatable, Sendable {
  let action: PutioBulkFileAction
  let completedCount: Int
  let totalCount: Int
  let currentItem: PutioFileItem
}

struct PutioBulkFileItemFailure: Equatable, Sendable {
  let item: PutioFileItem
  let error: PutioRuntimeError
  let presentation: PutioFileActionFailure?
}

struct PutioBulkFileOutcome: Equatable, Sendable {
  let action: PutioBulkFileAction
  let succeeded: [PutioFileItem]
  let failures: [PutioBulkFileItemFailure]

  var completedCount: Int {
    succeeded.count + failures.count
  }

  func retryableItems(in currentItems: [PutioFileItem]) -> [PutioFileItem] {
    let currentItemsByID = Dictionary(uniqueKeysWithValues: currentItems.map { ($0.id, $0) })
    return failures.compactMap { currentItemsByID[$0.item.id] }
  }
}

enum PutioBulkRetryPreparation: Equatable, Sendable {
  case ready([PutioFileItem])
  case failed
}

@MainActor
@Observable
final class PutioFolderModel {
  let folderID: PutioFileID

  private(set) var state: PutioFolderLoadState
  private(set) var refreshFailure: PutioBrowserErrorPresentation?
  private(set) var activeAction: PutioFileAction?
  private(set) var actionOutcome: PutioFileActionOutcome?
  private(set) var activeBulkAction: PutioBulkFileAction?
  private(set) var bulkProgress: PutioBulkFileProgress?
  private(set) var bulkOutcome: PutioBulkFileOutcome?

  @ObservationIgnored private let load: PutioFolderLoad
  @ObservationIgnored private let actions: PutioFileActions?
  @ObservationIgnored private var generation: UInt64 = 0
  @ObservationIgnored private var inFlightLoadGeneration: UInt64?
  @ObservationIgnored private var actionTask: Task<Void, Never>?
  @ObservationIgnored private var queuedRefresh: (id: UUID, task: Task<Bool, Never>)?
  @ObservationIgnored private var refreshRequestedWhileActionActive = false

  init(
    folderID: PutioFileID,
    load: @escaping PutioFolderLoad,
    actions: PutioFileActions? = nil,
    initialContents: PutioFolderContents? = nil
  ) {
    self.folderID = folderID
    self.load = load
    self.actions = actions
    state = initialContents.map { .loaded($0) } ?? .loading
  }

  var supportsActions: Bool {
    actions != nil
  }

  var canStartAction: Bool {
    guard supportsActions, !mutationIsActive, case .loaded = state else { return false }
    return true
  }

  private var mutationIsActive: Bool {
    activeAction != nil || activeBulkAction != nil
  }

  func loadIfNeeded() async {
    // `.loading` means the initial attempt never settled — including a
    // cancelled attempt that is still unwinding when the screen is
    // re-entered. Starting a new request here supersedes that unwind via
    // the generation check, so a late restore cannot strand the spinner.
    guard case .loading = state else { return }
    _ = await performLoad(mode: .replace)
  }

  func retry() async {
    _ = await performLoad(mode: .replace)
  }

  @discardableResult
  func refresh() async -> Bool {
    guard case .loaded = state else { return false }
    guard !mutationIsActive else {
      refreshRequestedWhileActionActive = true
      return false
    }
    return await performLoad(mode: .refresh)
  }

  func createFolder(name: String) async {
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

  func rename(_ item: PutioFileItem, to proposedName: String) async {
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

  func delete(_ item: PutioFileItem) async {
    guard let actions, canStartAction, case .loaded(let contents) = state else { return }
    guard let currentItem = contents.items.first(where: { $0.id == item.id }) else { return }
    let action = PutioFileAction.delete(fileID: currentItem.id, name: currentItem.name)
    begin(action)
    state = .loaded(contents.removing(currentItem.id))

    await run(action, rollback: contents) {
      try await actions.deleteFile(currentItem.id)
      return nil
    }
  }

  func move(_ item: PutioFileItem, to destination: PutioFolderRoute) async {
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

  func delete(_ selectedItems: [PutioFileItem]) async {
    guard
      let actions,
      canStartAction,
      case .loaded(let contents) = state,
      let items = latestItems(for: selectedItems, in: contents)
    else { return }

    let action = PutioBulkFileAction.delete
    beginBulk(action, items: items)
    state = .loaded(contents.removing(Set(items.map(\.id))))

    await runBulk(action, items: items, originalContents: contents) { item in
      try await actions.deleteFile(item.id)
    }
  }

  func move(_ selectedItems: [PutioFileItem], to destination: PutioFolderRoute) async {
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

    await runBulk(action, items: items, originalContents: contents) { item in
      try await actions.moveFile(item.id, destination.id)
    }
  }

  /// Suspends until the active mutation, if any, has settled. Callers whose
  /// own task was cancelled mid-mutation use this to rejoin the outcome.
  func waitForActiveAction() async {
    await actionTask?.value
  }

  func clearActionOutcome() {
    actionOutcome = nil
  }

  func clearBulkOutcome() {
    bulkOutcome = nil
  }

  func restoreBulkOutcome(_ outcome: PutioBulkFileOutcome) {
    guard bulkOutcome == nil, !mutationIsActive else { return }
    bulkOutcome = outcome
  }

  func prepareBulkRetry(_ outcome: PutioBulkFileOutcome) async -> PutioBulkRetryPreparation {
    let refreshed: Bool
    if let queuedRefresh {
      refreshed = await queuedRefresh.task.value
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
    // Superseding an in-flight refresh drops its response, so the server
    // state it carried must be fetched again once this action settles.
    if inFlightLoadGeneration == generation {
      refreshRequestedWhileActionActive = true
    }
    generation &+= 1
    activeAction = action
    actionOutcome = nil
  }

  private func beginBulk(_ action: PutioBulkFileAction, items: [PutioFileItem]) {
    if inFlightLoadGeneration == generation {
      refreshRequestedWhileActionActive = true
    }
    generation &+= 1
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
  private func run(
    _ action: PutioFileAction,
    rollback: PutioFolderContents,
    operation: @escaping @MainActor @Sendable () async throws -> PutioFolderContents?
  ) async {
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let updated = try await operation()
        guard activeAction == action else { return }
        if let updated {
          state = .loaded(updated)
        }
        activeAction = nil
        actionOutcome = .succeeded(action)
      } catch {
        settleFailure(action: action, error: error, rollback: rollback)
      }
      startQueuedRefreshIfNeeded()
    }
    actionTask = task
    await task.value
  }

  private func runBulk(
    _ action: PutioBulkFileAction,
    items: [PutioFileItem],
    originalContents: PutioFolderContents,
    operation: @escaping @MainActor @Sendable (PutioFileItem) async throws -> Void
  ) async {
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      var removedIDs = Set(items.map(\.id))
      var succeeded: [PutioFileItem] = []
      var failures: [PutioBulkFileItemFailure] = []

      for (index, item) in items.enumerated() {
        do {
          try await operation(item)
          succeeded.append(item)
        } catch {
          let runtimeError = error as? PutioRuntimeError ?? .unknown
          removedIDs.remove(item.id)
          let itemAction = singleAction(for: action, item: item)
          failures.append(
            PutioBulkFileItemFailure(
              item: item,
              error: runtimeError,
              presentation: PutioFileActionFailure(action: itemAction, error: error)
            )
          )
          if runtimeError == .rateLimited {
            for deferredItem in items.dropFirst(index + 1) {
              removedIDs.remove(deferredItem.id)
              let deferredAction = singleAction(for: action, item: deferredItem)
              failures.append(
                PutioBulkFileItemFailure(
                  item: deferredItem,
                  error: .rateLimited,
                  presentation: PutioFileActionFailure(
                    action: deferredAction,
                    error: PutioRuntimeError.rateLimited
                  )
                )
              )
            }
            state = .loaded(originalContents.removing(removedIDs))
            break
          }
          state = .loaded(originalContents.removing(removedIDs))
        }

        if let nextItem = items.dropFirst(index + 1).first {
          bulkProgress = PutioBulkFileProgress(
            action: action,
            completedCount: index + 1,
            totalCount: items.count,
            currentItem: nextItem
          )
        }
      }

      guard activeBulkAction == action else { return }
      state = .loaded(originalContents.removing(removedIDs))
      activeBulkAction = nil
      bulkProgress = nil
      bulkOutcome = PutioBulkFileOutcome(
        action: action,
        succeeded: succeeded,
        failures: failures
      )
      refreshRequestedWhileActionActive = true
      startQueuedRefreshIfNeeded()
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
    let id = UUID()
    let task = Task { @MainActor [weak self] in
      guard let self else { return false }
      defer {
        if queuedRefresh?.id == id { queuedRefresh = nil }
      }
      return await refresh()
    }
    queuedRefresh = (id, task)
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
    }

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
        state = previousState
        refreshFailure = presentation
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
    PutioFolderContents(folder: folder, items: items + [item], hasMore: hasMore)
  }

  fileprivate func replacing(_ item: PutioFileItem) -> PutioFolderContents {
    PutioFolderContents(
      folder: folder,
      items: items.map { $0.id == item.id ? item : $0 },
      hasMore: hasMore
    )
  }

  fileprivate func removing(_ id: PutioFileID) -> PutioFolderContents {
    PutioFolderContents(folder: folder, items: items.filter { $0.id != id }, hasMore: hasMore)
  }

  fileprivate func removing(_ ids: Set<PutioFileID>) -> PutioFolderContents {
    PutioFolderContents(
      folder: folder,
      items: items.filter { !ids.contains($0.id) },
      hasMore: hasMore
    )
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
      resumePositionSeconds: resumePositionSeconds
    )
  }
}

private enum LoadMode {
  case replace
  case refresh
}

struct PutioBrowserItemPresentation: Equatable, Identifiable, Sendable {
  let item: PutioFileItem
  let row: PutioFileRowModel

  var id: PutioFileID {
    item.id
  }

  var folderRoute: PutioFolderRoute? {
    guard item.kind == .folder else { return nil }
    return PutioFolderRoute(id: item.id, title: item.name)
  }

  var fileRoute: PutioFileRoute? {
    guard item.kind != .folder else { return nil }
    return PutioFileRoute(item: item)
  }

  init(
    item: PutioFileItem,
    relativeTo referenceDate: Date = .now,
    locale: Locale = .current
  ) {
    self.item = item
    row = PutioFileRowModel(
      name: item.name,
      kind: Self.rowKind(for: item.kind),
      sizeText: Self.detailText(for: item, relativeTo: referenceDate, locale: locale),
      isWatched: item.isWatched
    )
  }

  private static func rowKind(for kind: PutioFileKind) -> PutioFileRowModel.Kind {
    switch kind {
    case .folder: .folder
    case .video: .video
    case .audio: .audio
    case .image: .image
    case .pdf, .other: .file
    }
  }

  private static func detailText(
    for item: PutioFileItem,
    relativeTo referenceDate: Date,
    locale: Locale
  ) -> String? {
    guard item.kind != .folder else { return nil }
    let size = PutioFileRowModel.sizeText(bytes: item.sizeBytes, locale: locale)
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = locale
    formatter.dateTimeStyle = .named
    formatter.unitsStyle = .full
    let relativeDate = formatter.localizedString(for: item.updatedAt, relativeTo: referenceDate)
    return "\(size) · \(relativeDate)"
  }
}
