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

public struct PutioHistoryFailure: Equatable {
  public let message: String

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
public final class PutioHistoryModel {
  public enum State: Equatable {
    case loading
    case loaded(PutioHistoryPage)
    case failed(PutioHistoryFailure)
  }

  public enum Mutation: Equatable {
    case delete(Int)
    case clear
  }

  public private(set) var state: State = .loading
  public private(set) var isRefreshing = false
  private(set) var isLoadingMore = false
  public private(set) var refreshFailure: PutioHistoryFailure?
  public private(set) var loadMoreFailure: PutioHistoryFailure?
  public private(set) var paginationEpoch: UInt64 = 0
  public private(set) var mutation: Mutation?
  private(set) var failedMutation: Mutation?
  public private(set) var mutationFailure: PutioHistoryFailure?
  public private(set) var openingEventID: Int?
  public private(set) var openedFile: PutioFileItem?
  public private(set) var openFailure: PutioHistoryFailure?
  @ObservationIgnored private let actions: PutioHistoryActions
  public private(set) var generation: UInt64 = 0
  @ObservationIgnored private var failedOpen: PutioHistoryEventItem?
  @ObservationIgnored private var openGeneration: UInt64 = 0

  public init(actions: PutioHistoryActions) {
    self.actions = actions
  }

  public var page: PutioHistoryPage? {
    if case .loaded(let page) = state { return page }
    return nil
  }

  public func loadIfNeeded() async {
    guard case .loading = state else { return }
    await refresh()
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
      state = .loaded(
        PutioHistoryPage(
          items: page.items.filter { ids.insert($0.id).inserted }, nextBefore: page.nextBefore))
      switch failedMutation {
      case .delete(let id) where !ids.contains(id): clearMutationFailure()
      case .clear where page.items.isEmpty && page.nextBefore == nil: clearMutationFailure()
      default: break
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

  public func delete(eventID: Int) async {
    guard case .loaded(let page) = state, page.items.contains(where: { $0.id == eventID }) else {
      return
    }
    await mutate(.delete(eventID), page: page)
  }

  public func clear() async {
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
    // A lookup resolving mid-clear would open a file from the list being
    // cleared.
    if operation == .clear { cancelOpen() }
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

  public func retryMutation() async {
    guard let failedMutation else { return }
    switch failedMutation {
    case .delete(let id): await delete(eventID: id)
    case .clear: await clear()
    }
  }

  public func openFile(event: PutioHistoryEventItem) async {
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

  public func cancelOpen() {
    openGeneration &+= 1
    openingEventID = nil
    openedFile = nil
    openFailure = nil
    failedOpen = nil
  }

  public func retryOpen() async {
    guard let failedOpen else { return }
    await openFile(event: failedOpen)
  }

  public func clearOpenedFile() { openedFile = nil }
  func clearMutationFailure() {
    mutationFailure = nil
    failedMutation = nil
  }
  func clearOpenFailure() {
    openFailure = nil
    failedOpen = nil
  }
}

public struct PutioHistorySection: Identifiable {
  public enum Day: String, CaseIterable {
    case today = "Today"
    case yesterday = "Yesterday"
    case lastWeek = "Last week"
    case ancientTimes = "Ancient times"
  }

  public let id: Day
  public let items: [PutioHistoryEventItem]
  public var title: String { id.rawValue }

  /// Calendar days back from `now`: today, yesterday, the rest of the last
  /// week (under 8 days), then everything older.
  public static func group(
    _ items: [PutioHistoryEventItem], now: Date = .now, calendar: Calendar = .current
  ) -> [PutioHistorySection] {
    let today = calendar.startOfDay(for: now)
    let groups = Dictionary(grouping: items) { item -> Day in
      let days =
        calendar.dateComponents([.day], from: calendar.startOfDay(for: item.createdAt), to: today)
        .day ?? 0
      switch days {
      case ...0: return .today
      case 1: return .yesterday
      case 2..<8: return .lastWeek
      default: return .ancientTimes
      }
    }
    return Day.allCases.compactMap { day in
      groups[day].map { PutioHistorySection(id: day, items: $0) }
    }
  }
}
