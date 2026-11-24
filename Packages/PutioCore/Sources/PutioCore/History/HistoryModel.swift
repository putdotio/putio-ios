import Foundation
import Observation

public struct PutioHistoryActions: Sendable {
  let list: @MainActor @Sendable (Int?) async throws -> PutioHistoryPage
  let delete: @MainActor @Sendable (Int) async throws -> Void
  let clear: @MainActor @Sendable () async throws -> Void
  let file: @MainActor @Sendable (PutioFileID) async throws -> PutioFileItem

  public init(runtime: PutioRuntime) {
    list = { try await runtime.listHistory(before: $0) }
    delete = { try await runtime.deleteHistoryEvent(id: $0) }
    clear = { try await runtime.clearHistory() }
    file = { try await runtime.getFile(fileID: $0) }
  }

  init(
    list: @escaping @MainActor @Sendable (Int?) async throws -> PutioHistoryPage,
    delete: @escaping @MainActor @Sendable (Int) async throws -> Void,
    clear: @escaping @MainActor @Sendable () async throws -> Void,
    file: @escaping @MainActor @Sendable (PutioFileID) async throws -> PutioFileItem
  ) {
    self.list = list
    self.delete = delete
    self.clear = clear
    self.file = file
  }
}

public struct PutioHistoryFailure: Equatable, Sendable {
  public let message: String
  let isNotFound: Bool
  public let isOffline: Bool

  init?(error: Error) {
    guard !(error is CancellationError) else { return nil }
    isNotFound = error as? PutioRuntimeError == .notFound
    isOffline = error as? PutioFolderLoadError == .offline
    if isOffline {
      message = String(localized: "Check your connection and try again.", bundle: .module)
      return
    }
    switch error as? PutioRuntimeError {
    case .authenticationRequired, .sessionExpired: return nil
    case .notFound:
      message = String(localized: "This item is no longer available.", bundle: .module)
    case .rateLimited:
      message = String(
        localized: "put.io is receiving too many requests. Try again shortly.", bundle: .module)
    case .transient:
      message = String(localized: "Check your connection and try again.", bundle: .module)
    case .invalidResponse:
      message = String(
        localized: "put.io returned an invalid response. Try again.", bundle: .module)
    case .unknown, nil:
      message = String(
        localized: "put.io could not complete the request. Try again.", bundle: .module)
    }
  }
}

public struct PutioHistoryFileGone: Equatable, Sendable {
  public let eventID: Int
  let attempt: UInt64
}

@MainActor
@Observable
public final class PutioHistoryModel {
  public enum State: Equatable {
    case loading
    case loaded(PutioHistoryPage)
    case failed(PutioHistoryFailure)
  }

  public enum Mutation: Equatable {
    case clear
  }

  public private(set) var state: State = .loading
  public private(set) var isRefreshing = false
  private(set) var isLoadingMore = false
  public private(set) var refreshFailure: PutioHistoryFailure?
  public private(set) var loadMoreFailure: PutioHistoryFailure?
  public private(set) var paginationEpoch: UInt64 = 0
  public private(set) var mutation: Mutation?
  public private(set) var failedMutation: Mutation?
  public private(set) var mutationFailure: PutioHistoryFailure?
  public private(set) var openingEventID: Int?
  public private(set) var openedFile: PutioFileItem?
  public private(set) var openFailure: PutioHistoryFailure?
  public private(set) var fileGone: PutioHistoryFileGone?
  public private(set) var deletingEventIDs: Set<Int> = []
  @ObservationIgnored private var deletedEventIDs: Set<Int> = []
  @ObservationIgnored private var clearCount: UInt64 = 0
  @ObservationIgnored private let actions: PutioHistoryActions
  public private(set) var generation: UInt64 = 0
  @ObservationIgnored private var failedOpen: PutioHistoryEventItem?
  @ObservationIgnored private var openGeneration: UInt64 = 0

  public init(actions: PutioHistoryActions) {
    self.actions = actions
  }

  public var page: PutioHistoryPage? {
    guard case .loaded(let page) = state else { return nil }
    let hidden = deletingEventIDs.union(deletedEventIDs)
    guard !hidden.isEmpty else { return page }
    return PutioHistoryPage(
      items: page.items.filter { !hidden.contains($0.id) }, nextBefore: page.nextBefore)
  }

  public func loadIfNeeded() async {
    guard case .loading = state else { return }
    await refresh()
  }

  public func retryFailedLoad() {
    guard case .failed = state else { return }
    state = .loading
  }

  public func refresh() async {
    guard mutation == nil else { return }
    let previous = state
    generation &+= 1
    let request = generation
    isRefreshing = true
    isLoadingMore = false
    refreshFailure = nil
    loadMoreFailure = nil
    defer {
      if request == generation {
        isRefreshing = false
        paginationEpoch &+= 1
      }
    }
    do {
      try Task.checkCancellation()
      let page = try await actions.list(nil)
      try Task.checkCancellation()
      guard request == generation else { return }
      guard page.nextBefore.map({ $0 > 0 }) ?? true else {
        throw PutioRuntimeError.invalidResponse
      }
      var ids: Set<Int> = []
      let items = page.items.filter {
        !deletedEventIDs.contains($0.id) && ids.insert($0.id).inserted
      }
      state = .loaded(PutioHistoryPage(items: items, nextBefore: page.nextBefore))
      if failedMutation == .clear, page.items.isEmpty, page.nextBefore == nil {
        dismissMutationFailure()
      }
      if let eventID = openingEventID ?? failedOpen?.id, !ids.contains(eventID) {
        cancelOpen()
      }
    } catch {
      guard request == generation, !Task.isCancelled,
        let failure = PutioHistoryFailure(error: error)
      else { return }
      if case .loaded = previous {
        refreshFailure = failure
      } else {
        state = .failed(failure)
      }
    }
  }

  public func loadMore() async {
    guard mutation == nil, !isRefreshing, !isLoadingMore, refreshFailure == nil,
      case .loaded(let current) = state, let before = current.nextBefore
    else { return }
    let request = generation
    isLoadingMore = true
    loadMoreFailure = nil
    defer {
      if request == generation {
        isLoadingMore = false
        if Task.isCancelled { paginationEpoch &+= 1 }
      }
    }
    do {
      try Task.checkCancellation()
      let page = try await actions.list(before)
      try Task.checkCancellation()
      guard request == generation else { return }
      guard page.nextBefore.map({ $0 > 0 && $0 < before }) ?? true else {
        throw PutioRuntimeError.invalidResponse
      }
      var ids = Set(current.items.map(\.id)).union(deletedEventIDs)
      let appended = page.items.filter { ids.insert($0.id).inserted }
      state = .loaded(
        PutioHistoryPage(
          items: current.items + appended, nextBefore: page.nextBefore))
    } catch {
      guard request == generation, !Task.isCancelled else { return }
      loadMoreFailure = PutioHistoryFailure(error: error)
    }
  }

  @discardableResult
  public func beginDelete(eventID: Int) -> Bool {
    guard mutation == nil, !deletingEventIDs.contains(eventID),
      page?.items.contains(where: { $0.id == eventID }) == true
    else { return false }
    deletingEventIDs.insert(eventID)
    if failedOpen?.id == eventID || openingEventID == eventID { cancelOpen() }
    return true
  }

  public func finishDelete(eventID: Int) async -> PutioHistoryFailure? {
    guard deletingEventIDs.contains(eventID) else { return nil }
    let clears = clearCount
    let task = Task { @MainActor in
      do {
        try await actions.delete(eventID)
        deletedEventIDs.insert(eventID)
        deletingEventIDs.remove(eventID)
        return nil as PutioHistoryFailure?
      } catch {
        deletingEventIDs.remove(eventID)
        guard clears == clearCount else { return nil }
        return PutioHistoryFailure(error: error)
      }
    }
    return await task.value
  }

  public func clear() async {
    guard mutation == nil, case .loaded = state else { return }
    generation &+= 1
    isRefreshing = false
    isLoadingMore = false
    mutation = .clear
    mutationFailure = nil
    failedMutation = nil
    cancelOpen()
    let task = Task { @MainActor in
      do {
        try await actions.clear()
        clearCount &+= 1
        cancelOpen()
        deletingEventIDs = []
        state = .loaded(PutioHistoryPage(items: [], nextBefore: nil))
        refreshFailure = nil
        loadMoreFailure = nil
      } catch {
        mutationFailure = PutioHistoryFailure(error: error)
        if mutationFailure != nil { failedMutation = .clear }
      }
      mutation = nil
      paginationEpoch &+= 1
    }
    await task.value
  }

  public func retryMutation() async {
    guard failedMutation == .clear else { return }
    await clear()
  }

  public func openFile(event: PutioHistoryEventItem) async {
    guard let fileID = event.fileID, fileID.rawValue > 0 else { return }
    failedOpen = nil
    openGeneration &+= 1
    let request = openGeneration
    openingEventID = event.id
    openedFile = nil
    openFailure = nil
    fileGone = nil
    defer { if request == openGeneration { openingEventID = nil } }
    do {
      try Task.checkCancellation()
      let file = try await actions.file(fileID)
      try Task.checkCancellation()
      guard request == openGeneration else { return }
      guard file.id == fileID else { throw PutioRuntimeError.invalidResponse }
      openedFile = file
    } catch {
      guard request == openGeneration, !Task.isCancelled,
        let failure = PutioHistoryFailure(error: error)
      else { return }
      if failure.isNotFound {
        fileGone = PutioHistoryFileGone(eventID: event.id, attempt: request)
      } else {
        openFailure = failure
        failedOpen = event
      }
    }
  }

  public func cancelOpen() {
    openGeneration &+= 1
    openingEventID = nil
    openedFile = nil
    openFailure = nil
    fileGone = nil
    failedOpen = nil
  }

  public func retryOpen() async {
    guard let failedOpen else { return }
    await openFile(event: failedOpen)
  }

  public func clearOpenedFile() { openedFile = nil }
  public func dismissFileGone() { fileGone = nil }
  public func dismissMutationFailure() {
    mutationFailure = nil
    failedMutation = nil
  }
}
