import Foundation
import Observation
import PutioCore

typealias PutioFolderLoad =
  @MainActor @Sendable (PutioFileID) async throws -> PutioFolderContents
typealias PutioFolderContinue =
  @MainActor @Sendable (String) async throws -> PutioFolderContents
typealias PutioFolderSortUpdate =
  @MainActor @Sendable (PutioFileID, PutioFolderSort) async throws -> Void
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
  let setSort: PutioFolderSortUpdate
  let canDelete: @MainActor @Sendable () -> Bool

  init(runtime: PutioRuntime) {
    canDelete = {
      !runtime.session.isAccountPreferencesStale && !runtime.session.isUpdatingAccountPreferences
    }
    setSort = { folderID, sort in
      try await runtime.setFolderSort(folderID: folderID, sort: sort)
    }
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
    moveFile: @escaping PutioFileMove = { _, _ in throw PutioRuntimeError.unknown },
    setSort: @escaping PutioFolderSortUpdate = { _, _ in throw PutioRuntimeError.unknown },
    canDelete: @escaping @MainActor @Sendable () -> Bool = { true }
  ) {
    self.createFolder = createFolder
    self.renameFile = renameFile
    self.deleteFile = deleteFile
    self.moveFile = moveFile
    self.setSort = setSort
    self.canDelete = canDelete
  }
}

struct PutioFolderRoute: Identifiable, Sendable {
  let id: PutioFileID
  let title: String

  static let root = PutioFolderRoute(id: .root, title: "Files")
}

@Observable
final class PutioFolderRefreshRequests {
  private(set) var revision: UInt64 = 0
  struct Sequence: Equatable, Sendable {
    let folder: UInt64
    let allFolders: UInt64
  }

  private var sequences: [PutioFileID: UInt64] = [:]
  private var allFoldersSequence: UInt64 = 0
  private struct Registration {
    var broadcastSequence: UInt64 = 0
    var folderSequence: UInt64 = 0
    var consumed: Sequence?
  }

  private var registrations: [PutioFileID: [UUID: Registration]] = [:]

  func register(folderID: PutioFileID, owner: UUID) {
    guard registrations[folderID]?[owner] == nil else { return }
    registrations[folderID, default: [:]][owner] = Registration()
  }

  func unregister(folderID: PutioFileID, owner: UUID) {
    registrations[folderID]?[owner] = nil
    if registrations[folderID]?.isEmpty == true {
      registrations[folderID] = nil
      sequences[folderID] = nil
    }
  }

  func request(folderID: PutioFileID, excludingOwner: UUID? = nil) {
    revision &+= 1
    sequences[folderID, default: 0] &+= 1
    let owners = registrations[folderID].map { Array($0.keys) } ?? []
    for owner in owners {
      guard owner != excludingOwner else { continue }
      registrations[folderID]?[owner]?.folderSequence = sequences[folderID, default: 0]
    }
  }

  func requestAllLoadedFolders(excludingOwner: UUID? = nil) {
    revision &+= 1
    allFoldersSequence &+= 1
    for folderID in Array(registrations.keys) {
      let owners = registrations[folderID].map { Array($0.keys) } ?? []
      for owner in owners {
        guard owner != excludingOwner else { continue }
        registrations[folderID]?[owner]?.broadcastSequence = allFoldersSequence
      }
    }
  }

  /// Each mounted screen consumes its own refresh, including when Files and
  /// Search both display the same folder.
  func sequence(for folderID: PutioFileID, owner: UUID) -> Sequence? {
    guard let registration = registrations[folderID]?[owner] else { return nil }
    let current = Sequence(
      folder: registration.folderSequence,
      allFolders: registration.broadcastSequence)
    guard current.folder > 0 || current.allFolders > 0 else { return nil }
    guard registration.consumed != current else { return nil }
    return current
  }

  func markConsumed(_ sequence: Sequence, for folderID: PutioFileID, owner: UUID) {
    registrations[folderID]?[owner]?.consumed = sequence
  }
}

/// Lives in a folder screen's `@State`. SwiftUI releases that state only when
/// the screen is discarded (a pop, not a tab switch), which is exactly when
/// the folder's refresh registration should go.
///
/// The view struct's initializer runs on every parent re-render and builds a
/// throwaway instance each time; only the instance SwiftUI retains ever calls
/// `activate()`, so only that one registers and unregisters.
@MainActor
final class PutioFolderRefreshRegistration {
  private let folderID: PutioFileID
  private let requests: PutioFolderRefreshRequests
  let owner = UUID()
  private var isActive = false

  init(folderID: PutioFileID, requests: PutioFolderRefreshRequests) {
    self.folderID = folderID
    self.requests = requests
  }

  func activate() {
    guard !isActive else { return }
    isActive = true
    requests.register(folderID: folderID, owner: owner)
  }

  deinit {
    guard isActive else { return }
    let folderID = self.folderID
    let requests = self.requests
    let owner = self.owner
    Task { @MainActor in requests.unregister(folderID: folderID, owner: owner) }
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

  var audioPlaybackRoute: PutioAudioRoute? {
    guard item.kind == .audio else { return nil }
    return PutioAudioRoute(id: item.id, parentID: item.parentID, title: item.name)
  }

  var previewRoute: PutioPreviewRoute? {
    switch item.kind {
    case .image:
      PutioPreviewRoute(id: item.id, parentID: item.parentID, title: item.name, kind: .image)
    case .pdf:
      PutioPreviewRoute(id: item.id, parentID: item.parentID, title: item.name, kind: .pdf)
    case .folder, .video, .audio, .other:
      nil
    }
  }

  /// The typed routing table: every non-folder item resolves to exactly one
  /// action, so a tap never lands on a dead row.
  var openAction: PutioFileOpenAction {
    if let videoPlaybackRoute { return .video(videoPlaybackRoute) }
    if let audioPlaybackRoute { return .audio(audioPlaybackRoute) }
    if let previewRoute { return .preview(previewRoute) }
    return .unsupported(PutioUnsupportedFileRoute(item: item))
  }

  /// A route that opens a player of any kind.
  var isPlayable: Bool {
    videoPlaybackRoute != nil || audioPlaybackRoute != nil
  }

  /// Media the VLC handoff can stream; previews and unknown types stay in-app.
  var supportsExternalPlayback: Bool {
    isPlayable
  }
}

enum PutioFileOpenAction: Equatable, Sendable {
  case video(PutioVideoRoute)
  case audio(PutioAudioRoute)
  case preview(PutioPreviewRoute)
  case unsupported(PutioUnsupportedFileRoute)
}

struct PutioPreviewRoute: Identifiable, Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    case image
    case pdf
  }

  let id: PutioFileID
  let parentID: PutioFileID
  let title: String
  let kind: Kind
}

struct PutioUnsupportedFileRoute: Identifiable, Equatable, Sendable {
  let item: PutioFileItem

  var id: PutioFileID { item.id }
}

struct PutioAudioRoute: Identifiable, Equatable, Sendable {
  let id: PutioFileID
  let parentID: PutioFileID
  let title: String
}

struct PutioVideoRoute: Identifiable, Equatable, Sendable {
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
  case sort(folderID: PutioFileID, sort: PutioFolderSort)
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
    case .sort:
      title = "Could not change sorting"
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
  private(set) var isLoadingMore = false
  private(set) var loadMoreFailure: PutioBrowserErrorPresentation?
  // Bumped whenever a load or mutation settles, so a continuation the
  // settling work superseded starts again even when the cursor is unchanged.
  private(set) var continuationEpoch: UInt64 = 0
  private(set) var activeAction: PutioFileAction?
  private(set) var actionOutcome: PutioFileActionOutcome?
  private(set) var activeBulkAction: PutioBulkFileAction?
  private(set) var bulkProgress: PutioBulkFileProgress?
  private(set) var bulkOutcome: PutioBulkFileOutcome?

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

  init(
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
  }

  var supportsActions: Bool {
    actions != nil
  }

  var canStartAction: Bool {
    guard supportsActions, !mutationIsActive, case .loaded = state else { return false }
    return true
  }

  var canDelete: Bool { canStartAction && actions?.canDelete() == true }

  private var mutationIsActive: Bool {
    activeAction != nil || activeBulkAction != nil
  }

  var isLoaded: Bool {
    if case .loaded = state { return true }
    return false
  }

  var canLoadMore: Bool {
    guard continueLoad != nil, !mutationIsActive, !isLoadingMore,
      inFlightLoadGeneration == nil, case .loaded(let contents) = state
    else { return false }
    return contents.nextCursor != nil
  }

  struct ContinuationKey: Hashable {
    let cursor: String?
    let epoch: UInt64
  }

  var nextCursor: String? {
    if case .loaded(let contents) = state { return contents.nextCursor }
    return nil
  }

  /// Identity for the view task that fetches the next page.
  var continuationKey: ContinuationKey {
    ContinuationKey(cursor: nextCursor, epoch: continuationEpoch)
  }

  /// The folder's own server-side sort, or `nil` when it inherits the account
  /// default. Inherited folders accept any explicit choice.
  var sort: PutioFolderSort? {
    if case .loaded(let contents) = state { return contents.sort }
    return nil
  }

  /// Appends the next page. Any full reload in flight or started meanwhile
  /// supersedes the result through the load generation.
  @discardableResult
  func loadMore() async -> Bool {
    guard let continueLoad, canLoadMore, case .loaded(let contents) = state,
      let cursor = contents.nextCursor
    else { return false }
    let requestGeneration = generation
    isLoadingMore = true
    loadMoreFailure = nil
    defer { if requestGeneration == generation { isLoadingMore = false } }

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
  func setSort(_ sort: PutioFolderSort) async {
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
  func loadIfNeeded() async -> Bool {
    // `.loading` means the initial attempt never settled — including a
    // cancelled attempt that is still unwinding when the screen is
    // re-entered. Starting a new request here supersedes that unwind via
    // the generation check, so a late restore cannot strand the spinner.
    guard case .loading = state else { return false }
    return await performLoad(mode: .replace)
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

  /// Like `refresh()`, but a call that lands during a mutation waits for the
  /// refresh queued behind that mutation and reports its result, so a pending
  /// folder request can be consumed by the refresh that actually served it.
  func refreshWhenIdle() async -> Bool {
    guard case .loaded = state else { return false }
    guard mutationIsActive else { return await performLoad(mode: .refresh) }
    refreshRequestedWhileActionActive = true
    await actionTask?.value
    guard let queuedRefresh else { return false }
    return await queuedRefresh.value
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
    guard let actions, canDelete, case .loaded(let contents) = state else { return }
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
      canDelete,
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
      } catch {
        settleFailure(action: action, error: error, rollback: rollback)
      }
      startQueuedRefreshIfNeeded()
      continuationEpoch &+= 1
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
          let failure = itemFailure(for: action, item: item, error: error)
          removedIDs.remove(item.id)
          failures.append(failure)
          let rateLimited = failure.error == .rateLimited
          if rateLimited {
            for deferredItem in items.dropFirst(index + 1) {
              removedIDs.remove(deferredItem.id)
              failures.append(
                itemFailure(
                  for: action, item: deferredItem, error: PutioRuntimeError.rateLimited)
              )
            }
          }
          state = .loaded(originalContents.removing(removedIDs))
          if rateLimited { break }
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

/// A sort key as the Files app presents it: one row per key, direction as a
/// subtitle, and re-selecting the current key flips direction.
enum PutioFolderSortKey: CaseIterable, Hashable {
  case name, size, dateAdded, dateModified, type, watchStatus

  var title: String {
    switch self {
    case .name: "Name"
    case .size: "Size"
    case .dateAdded: "Date Added"
    case .dateModified: "Date Modified"
    case .type: "Kind"
    case .watchStatus: "Watched"
    }
  }

  func sort(ascending: Bool) -> PutioFolderSort {
    switch (self, ascending) {
    case (.name, true): .nameAscending
    case (.name, false): .nameDescending
    case (.size, true): .sizeAscending
    case (.size, false): .sizeDescending
    case (.dateAdded, true): .dateAddedAscending
    case (.dateAdded, false): .dateAddedDescending
    case (.dateModified, true): .dateModifiedAscending
    case (.dateModified, false): .dateModifiedDescending
    case (.type, true): .typeAscending
    case (.type, false): .typeDescending
    case (.watchStatus, true): .watchStatusAscending
    case (.watchStatus, false): .watchStatusDescending
    }
  }

  /// The sort to request when the user taps this key while `current` applies.
  func selection(from current: PutioFolderSort?) -> PutioFolderSort {
    guard let current, current.key == self else { return sort(ascending: true) }
    return sort(ascending: !current.isAscending)
  }
}

extension PutioFolderSort {
  var key: PutioFolderSortKey {
    switch self {
    case .nameAscending, .nameDescending: .name
    case .sizeAscending, .sizeDescending: .size
    case .dateAddedAscending, .dateAddedDescending: .dateAdded
    case .dateModifiedAscending, .dateModifiedDescending: .dateModified
    case .typeAscending, .typeDescending: .type
    case .watchStatusAscending, .watchStatusDescending: .watchStatus
    }
  }

  var isAscending: Bool {
    switch self {
    case .nameAscending, .sizeAscending, .dateAddedAscending, .dateModifiedAscending,
      .typeAscending, .watchStatusAscending:
      true
    default:
      false
    }
  }

  var directionTitle: String {
    isAscending ? "Ascending" : "Descending"
  }

  var title: String {
    "\(key.title), \(directionTitle.lowercased())"
  }
}
