import Foundation
import Observation
import PutioCore

struct PutioHistoryActions: Sendable {
  let list: @MainActor @Sendable (Int?) async throws -> PutioHistoryPage
  let delete: @MainActor @Sendable (Int) async throws -> Void
  let clear: @MainActor @Sendable () async throws -> Void
  let file: @MainActor @Sendable (PutioFileID) async throws -> PutioFileItem

  init(runtime: PutioRuntime) {
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

struct PutioHistoryFailure: Equatable {
  let message: String

  init(message: String) { self.message = message }

  init?(error: Error) {
    guard !(error is CancellationError) else { return nil }
    switch error as? PutioRuntimeError {
    case .authenticationRequired, .sessionExpired: return nil
    case .notFound: message = "This item is no longer available."
    case .rateLimited: message = "put.io is receiving too many requests. Try again shortly."
    case .transient: message = "Check your connection and try again."
    case .invalidResponse: message = "put.io returned an invalid response. Try again."
    case .unknown, nil: message = "put.io could not complete the request. Try again."
    }
  }
}

@MainActor
@Observable
final class PutioHistoryModel {
  enum State: Equatable {
    case loading
    case loaded(PutioHistoryPage)
    case failed(PutioHistoryFailure)
  }

  enum Mutation: Equatable {
    case delete(Int)
    case clear
  }

  private(set) var state: State = .loading
  private(set) var isRefreshing = false
  private(set) var isLoadingMore = false
  private(set) var refreshFailure: PutioHistoryFailure?
  private(set) var loadMoreFailure: PutioHistoryFailure?
  private(set) var paginationEpoch: UInt64 = 0
  private(set) var mutation: Mutation?
  private(set) var failedMutation: Mutation?
  private(set) var mutationFailure: PutioHistoryFailure?
  private(set) var openingEventID: Int?
  private(set) var openedFile: PutioFileItem?
  private(set) var openFailure: PutioHistoryFailure?
  @ObservationIgnored private let actions: PutioHistoryActions
  private(set) var generation: UInt64 = 0
  @ObservationIgnored private var failedOpen: PutioHistoryEventItem?
  @ObservationIgnored private var openGeneration: UInt64 = 0

  init(actions: PutioHistoryActions) {
    self.actions = actions
  }

  var page: PutioHistoryPage? {
    if case .loaded(let page) = state { return page }
    return nil
  }

  func loadIfNeeded() async {
    guard case .loading = state else { return }
    await refresh()
  }

  func refresh() async {
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
      state = .loaded(
        PutioHistoryPage(
          items: page.items.filter { ids.insert($0.id).inserted }, nextBefore: page.nextBefore))
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

  func loadMore() async {
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
      var ids = Set(current.items.map(\.id))
      let appended = page.items.filter { ids.insert($0.id).inserted }
      state = .loaded(
        PutioHistoryPage(
          items: current.items + appended, nextBefore: page.nextBefore))
    } catch {
      guard request == generation, !Task.isCancelled else { return }
      loadMoreFailure = PutioHistoryFailure(error: error)
    }
  }

  func delete(eventID: Int) async {
    guard case .loaded(let page) = state, page.items.contains(where: { $0.id == eventID }) else {
      return
    }
    await mutate(.delete(eventID), page: page)
  }

  func clear() async {
    guard case .loaded(let page) = state else { return }
    await mutate(.clear, page: page)
  }

  private func mutate(_ operation: Mutation, page: PutioHistoryPage) async {
    guard mutation == nil else { return }
    generation &+= 1
    isRefreshing = false
    isLoadingMore = false
    mutation = operation
    mutationFailure = nil
    failedMutation = nil
    let task = Task { @MainActor in
      do {
        switch operation {
        case .delete(let id):
          try await actions.delete(id)
          if failedOpen?.id == id || openingEventID == id { cancelOpen() }
          state = .loaded(
            PutioHistoryPage(
              items: page.items.filter { $0.id != id }, nextBefore: page.nextBefore))
        case .clear:
          try await actions.clear()
          cancelOpen()
          state = .loaded(PutioHistoryPage(items: [], nextBefore: nil))
        }
        refreshFailure = nil
        loadMoreFailure = nil
      } catch {
        mutationFailure = PutioHistoryFailure(error: error)
        if mutationFailure != nil { failedMutation = operation }
      }
      mutation = nil
      paginationEpoch &+= 1
    }
    await task.value
  }

  func retryMutation() async {
    guard let failedMutation else { return }
    switch failedMutation {
    case .delete(let id): await delete(eventID: id)
    case .clear: await clear()
    }
  }

  func openFile(event: PutioHistoryEventItem) async {
    guard let fileID = event.fileID, fileID.rawValue > 0 else { return }
    failedOpen = nil
    openGeneration &+= 1
    let request = openGeneration
    openingEventID = event.id
    openedFile = nil
    openFailure = nil
    defer { if request == openGeneration { openingEventID = nil } }
    do {
      try Task.checkCancellation()
      let file = try await actions.file(fileID)
      try Task.checkCancellation()
      guard request == openGeneration else { return }
      guard file.id == fileID else { throw PutioRuntimeError.invalidResponse }
      openedFile = file
    } catch {
      guard request == openGeneration, !Task.isCancelled else { return }
      openFailure = PutioHistoryFailure(error: error)
      if openFailure != nil { failedOpen = event }
    }
  }

  func daySections(now: Date = .now, calendar: Calendar = .current) -> [PutioHistorySection] {
    PutioHistorySection.group(page?.items ?? [], now: now, calendar: calendar)
  }

  func cancelOpen() {
    openGeneration &+= 1
    openingEventID = nil
    openedFile = nil
    openFailure = nil
    failedOpen = nil
  }

  func retryOpen() async {
    guard let failedOpen else { return }
    await openFile(event: failedOpen)
  }

  func clearOpenedFile() { openedFile = nil }
  func clearMutationFailure() {
    mutationFailure = nil
    failedMutation = nil
  }
  func clearOpenFailure() {
    openFailure = nil
    failedOpen = nil
  }
}

struct PutioHistorySection: Identifiable {
  enum Day: String, CaseIterable {
    case today = "Today"
    case yesterday = "Yesterday"
    case earlier = "Earlier"
  }

  let id: Day
  let items: [PutioHistoryEventItem]
  var title: String { id.rawValue }

  static func group(
    _ items: [PutioHistoryEventItem], now: Date = .now, calendar: Calendar = .current
  ) -> [PutioHistorySection] {
    let today = calendar.startOfDay(for: now)
    let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
    let groups = Dictionary(grouping: items) { item -> Day in
      if item.createdAt >= today { return .today }
      if item.createdAt >= yesterday { return .yesterday }
      return .earlier
    }
    return Day.allCases.compactMap { day in
      groups[day].map { PutioHistorySection(id: day, items: $0) }
    }
  }
}
