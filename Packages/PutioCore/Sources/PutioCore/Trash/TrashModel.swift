import Foundation
import Observation

typealias PutioTrashLoad = @MainActor @Sendable (String?) async throws -> PutioTrashPage
typealias PutioTrashRestore =
  @MainActor @Sendable (PutioFileID) async throws -> PutioTrashRestoreResult
typealias PutioTrashItemMutation =
  @MainActor @Sendable (PutioFileID) async throws -> PutioTrashMutationResult
typealias PutioTrashEmpty = @MainActor @Sendable () async throws -> PutioTrashMutationResult
typealias PutioTrashBatchRestore = @MainActor @Sendable ([PutioFileID]) async throws -> Void
typealias PutioTrashBatchMutation =
  @MainActor @Sendable ([PutioFileID]) async throws -> PutioTrashMutationResult
/// Restores all of Trash: the listing cursor when one exists, else the ids.
typealias PutioTrashRestoreAll =
  @MainActor @Sendable (String?, [PutioFileID]) async throws -> Void
typealias PutioTrashStorageRefresh = @MainActor @Sendable () async -> Bool
typealias PutioTrashStorageIsStale = @MainActor @Sendable () -> Bool
public typealias PutioTrashDidRestore = @MainActor @Sendable (PutioFileID?) -> Void

/// Committed Trash removals the server may not list consistently yet. Owned
/// by the composition root so it survives popping and reopening Trash.
///
/// Every tombstone is bounded: it is released when a complete listing omits
/// the item, and also after `consistentListingsBeforeTrust` complete listings
/// that still report it. `deletedAt` has second precision, so a same-second
/// re-trash or a file trashed in the same second as an emptying could match
/// a tombstone; the bound guarantees such an item is hidden for at most a
/// couple of refreshes, never permanently.
@MainActor
@Observable
public final class PutioTrashReconciliation {
  /// One trashed generation of a file: the same file re-trashed later has a
  /// newer `deletedAt` and is a different generation.
  struct Removal: Hashable, Sendable {
    let id: PutioFileID
    let deletedAt: Date
  }

  static let consistentListingsBeforeTrust = 2

  /// Bumped on every committed removal or emptying so a Trash screen that
  /// did not perform the mutation can drop the rows it already shows.
  private(set) var version: UInt64 = 0
  /// A committed removal: how many complete listings have still reported it,
  /// and the `version` it was recorded at. A listing that started earlier
  /// neither counts nor releases it; that listing's pages predate the commit.
  private struct Tombstone {
    var listings: Int
    let version: UInt64
  }

  @ObservationIgnored private var removals: [Removal: Tombstone] = [:]
  /// `version` at which each open listing started.
  @ObservationIgnored private var listingVersions: [UUID: UInt64] = [:]
  /// Set after emptying. Emptying deletes rows on pages never loaded, whose
  /// deletion times are unknown, so every listed row is treated as lag until
  /// a complete listing is empty or the bound above expires.
  @ObservationIgnored private(set) var isEmptyingPending = false
  @ObservationIgnored private var emptiedListings = 0
  /// Rows seen so far per listing. Listings are identified by the caller so
  /// concurrent walks from different Trash screens cannot merge into one.
  @ObservationIgnored private var seenByListing: [UUID: Set<Removal>] = [:]

  public init() {}

  func recordRemoval(of item: PutioTrashItem) {
    version &+= 1
    removals[Removal(id: item.id, deletedAt: item.deletedAt)] = Tombstone(
      listings: 0, version: version)
  }

  func recordEmptied() {
    isEmptyingPending = true
    emptiedListings = 0
    // Only listings started after the emptying may settle the cutoff: a walk
    // begun before it carries pre-empty pages and proves nothing about lag.
    seenByListing.removeAll()
    listingVersions.removeAll()
    version &+= 1
  }

  /// Drops every row a committed mutation has since removed. Used after any
  /// await that captured a page before another screen could mutate.
  /// The continuation is kept while an emptying is pending: a lagging listing
  /// must still be walked to its last page so it can count toward the
  /// emptying bound. Dropping a cursor another screen invalidated is the
  /// model's job (see `PutioTrashModel.repairIfRequested`).
  func prune(_ page: PutioTrashPage) -> PutioTrashPage {
    if isEmptyingPending {
      return PutioTrashPage(items: [], nextCursor: page.nextCursor, totalCount: 0, sizeBytes: 0)
    }
    let survivors = page.items.filter { !isRemoved($0) }
    guard survivors.count != page.items.count else { return page }
    let removedBytes = page.items.filter { isRemoved($0) }.reduce(Int64(0)) { $0 + $1.sizeBytes }
    let removedCount = page.items.count - survivors.count
    return PutioTrashPage(
      items: survivors,
      nextCursor: page.nextCursor,
      totalCount: page.totalCount.map { max(0, $0 - removedCount) },
      sizeBytes: max(0, page.sizeBytes - removedBytes)
    )
  }

  func isRemoved(_ item: PutioTrashItem) -> Bool {
    if isEmptyingPending { return true }
    return removals[Removal(id: item.id, deletedAt: item.deletedAt)] != nil
  }

  /// Drops the accumulator of a listing that will not be walked to its end.
  func abandonListing(_ listingID: UUID) {
    seenByListing[listingID] = nil
    listingVersions[listingID] = nil
  }

  /// Listings started but not yet completed or abandoned.
  var pendingListingCount: Int { seenByListing.count }

  /// Filters a listing page. On the final page of a complete listing it
  /// releases every tombstone the server omitted, and every tombstone the
  /// server has now reported `consistentListingsBeforeTrust` times.
  /// `listingID` ties a first page and its continuations together.
  func reconcile(
    _ listing: PutioTrashPage, listingID: UUID, startsListing: Bool
  ) -> PutioTrashPage {
    if startsListing {
      seenByListing[listingID] = []
      listingVersions[listingID] = version
    }
    // A continuation of an abandoned listing still gets filtered, but it can
    // never complete that listing: its earlier pages are gone.
    if var seen = seenByListing[listingID] {
      seen.formUnion(listing.items.map { Removal(id: $0.id, deletedAt: $0.deletedAt) })
      seenByListing[listingID] = seen
    }
    let survivors = listing.items.filter { !isRemoved($0) }
    if listing.nextCursor == nil {
      if let seen = seenByListing.removeValue(forKey: listingID),
        let startedAt = listingVersions.removeValue(forKey: listingID)
      {
        settleCompleteListing(seen: seen, startedAt: startedAt)
      }
    }
    guard survivors.count != listing.items.count else { return listing }
    // totalCount and sizeBytes are server aggregates, not row sums.
    return PutioTrashPage(
      items: survivors,
      nextCursor: listing.nextCursor,
      totalCount: listing.totalCount,
      sizeBytes: listing.sizeBytes
    )
  }

  private func settleCompleteListing(seen: Set<Removal>, startedAt: UInt64) {
    for (removal, tombstone) in removals {
      // Recorded after this listing began: its pages say nothing about it.
      guard tombstone.version <= startedAt else { continue }
      guard seen.contains(removal) else {
        removals[removal] = nil
        continue
      }
      let reported = tombstone.listings + 1
      removals[removal] =
        reported < Self.consistentListingsBeforeTrust
        ? Tombstone(listings: reported, version: tombstone.version) : nil
    }
    guard isEmptyingPending else { return }
    if seen.isEmpty {
      // The server confirms the empty Trash.
      isEmptyingPending = false
    } else {
      emptiedListings += 1
      if emptiedListings >= Self.consistentListingsBeforeTrust { isEmptyingPending = false }
    }
  }
}

public struct PutioTrashActions: Sendable {
  let load: PutioTrashLoad
  let restore: PutioTrashRestore
  let permanentlyDelete: PutioTrashItemMutation
  let restoreItems: PutioTrashBatchRestore
  let permanentlyDeleteItems: PutioTrashBatchMutation
  let restoreAll: PutioTrashRestoreAll
  /// Items per selected restore or delete request, as for Files bulk actions.
  let batchSize: Int
  let empty: PutioTrashEmpty
  let refreshStorage: PutioTrashStorageRefresh
  /// The session owns stale-storage state so it survives leaving Trash.
  let isStorageStale: PutioTrashStorageIsStale

  init(runtime: PutioRuntime) {
    load = { cursor in try await runtime.listTrash(cursor: cursor) }
    restore = { fileID in try await runtime.restoreTrashItem(fileID: fileID) }
    permanentlyDelete = { fileID in
      try await runtime.permanentlyDeleteTrashItem(fileID: fileID)
    }
    restoreItems = { fileIDs in try await runtime.restoreTrashItems(fileIDs: fileIDs) }
    permanentlyDeleteItems = { fileIDs in
      try await runtime.permanentlyDeleteTrashItems(fileIDs: fileIDs)
    }
    restoreAll = { cursor, fileIDs in
      try await runtime.restoreAllTrash(cursor: cursor, loadedFileIDs: fileIDs)
    }
    batchSize = PutioFileActions.defaultBatchSize
    empty = { try await runtime.emptyTrash() }
    refreshStorage = { await runtime.refreshAccount() }
    isStorageStale = { runtime.session.isAccountStorageStale }
  }

  init(
    load: @escaping PutioTrashLoad,
    restore: @escaping PutioTrashRestore,
    permanentlyDelete: @escaping PutioTrashItemMutation,
    restoreItems: @escaping PutioTrashBatchRestore = { _ in throw PutioRuntimeError.unknown },
    permanentlyDeleteItems: @escaping PutioTrashBatchMutation = { _ in
      throw PutioRuntimeError.unknown
    },
    restoreAll: @escaping PutioTrashRestoreAll = { _, _ in throw PutioRuntimeError.unknown },
    batchSize: Int = PutioFileActions.defaultBatchSize,
    empty: @escaping PutioTrashEmpty,
    refreshStorage: @escaping PutioTrashStorageRefresh = { true },
    isStorageStale: @escaping PutioTrashStorageIsStale = { false }
  ) {
    self.load = load
    self.restore = restore
    self.permanentlyDelete = permanentlyDelete
    self.restoreItems = restoreItems
    self.permanentlyDeleteItems = permanentlyDeleteItems
    self.restoreAll = restoreAll
    self.batchSize = max(1, batchSize)
    self.empty = empty
    self.refreshStorage = refreshStorage
    self.isStorageStale = isStorageStale
  }
}

public struct PutioTrashErrorPresentation: Equatable, Sendable {
  public let title: String
  public let message: String

  init(title: String, message: String) {
    self.title = title
    self.message = message
  }

  public static let staleStorage = PutioTrashErrorPresentation(
    title: "Storage totals are out of date",
    message: "Account storage could not be updated after the last deletion."
  )

  init?(title: String, error: Error) {
    self.title = title
    switch error as? PutioRuntimeError {
    case .authenticationRequired, .sessionExpired:
      return nil
    case .notFound:
      message = "The item is no longer in Trash. Refresh and try again."
    case .rateLimited:
      message = "put.io is receiving too many requests. Try again shortly."
    case .transient:
      message = "Check your connection and try again."
    case .invalidResponse:
      message = "put.io returned an invalid response. Try again."
    case .unknown, nil:
      message = "put.io could not complete the request. Try again."
    }
  }
}

public enum PutioTrashLoadState: Equatable, Sendable {
  case loading
  case loaded(PutioTrashPage)
  case failed(PutioTrashErrorPresentation)
}

public enum PutioTrashMutation: Equatable, Sendable {
  case restore(PutioTrashItem)
  case permanentlyDelete(PutioTrashItem)
  case restoreItems([PutioTrashItem])
  case permanentlyDeleteItems([PutioTrashItem])
  case restoreAll
  case empty
}

/// A batched Trash mutation that stopped partway: `mutation` names only the
/// rows still in Trash.
private struct PutioTrashBatchFailure: Error {
  let mutation: PutioTrashMutation
  let cause: Error
}

public enum PutioTrashMutationOutcome: Equatable, Sendable {
  case restored(PutioTrashItem)
  /// `storageRefreshed` is false when the deletion committed but the account
  /// storage totals could not be reloaded; the next Trash refresh retries them.
  case permanentlyDeleted(PutioTrashItem, storageRefreshed: Bool = true)
  case restoredItems([PutioTrashItem])
  case permanentlyDeletedItems([PutioTrashItem], storageRefreshed: Bool = true)
  /// The server restores the whole Trash in the background.
  case restoredAll
  case emptied(storageRefreshed: Bool = true)
  case failed(PutioTrashMutation, PutioTrashErrorPresentation)
}

@MainActor
@Observable
public final class PutioTrashModel {
  public private(set) var state: PutioTrashLoadState = .loading
  public private(set) var activeMutation: PutioTrashMutation?
  public private(set) var mutationOutcome: PutioTrashMutationOutcome?
  public private(set) var isRefreshing = false
  private(set) var isLoadingMore = false
  public private(set) var paginationFailure: PutioTrashErrorPresentation?
  public private(set) var refreshFailure: PutioTrashErrorPresentation?
  public private(set) var isRefreshingStorage = false

  /// Mirrors the session's stale-storage state; the retry only reloads
  /// account storage.
  var isStorageStale: Bool { actions.isStorageStale() }

  public var storageFailure: PutioTrashErrorPresentation? {
    guard isStorageStale else { return nil }
    return PutioTrashErrorPresentation.staleStorage
  }

  @ObservationIgnored private let actions: PutioTrashActions
  @ObservationIgnored private let onRestored: PutioTrashDidRestore
  @ObservationIgnored private var hasLoaded = false
  // Another screen's mutation invalidated this page's continuation; reload
  // from the first page as soon as the model is idle.
  @ObservationIgnored private var repairRequested = false
  // Set by appearance, cleared by disappearance. Listings opened while the
  // screen is gone are abandoned at once; see openListing.
  @ObservationIgnored private var isVisible = true
  // Supersedes an initial load that is still unwinding after cancellation so
  // re-entering the screen cannot strand it on the loading state.
  @ObservationIgnored private var loadGeneration: UInt64 = 0
  // Loads parked behind another load's storage retry.
  @ObservationIgnored private var storageWaiters: [AsyncStream<Never>.Continuation] = []
  @ObservationIgnored private let reconciliation: PutioTrashReconciliation
  // Identifies the listing the current page belongs to, so its
  // continuations reconcile against the same accumulator.
  @ObservationIgnored private var listingID = UUID()

  public init(
    actions: PutioTrashActions,
    reconciliation: PutioTrashReconciliation? = nil,
    onRestored: @escaping PutioTrashDidRestore = { _ in }
  ) {
    self.actions = actions
    self.reconciliation = reconciliation ?? PutioTrashReconciliation()
    self.onRestored = onRestored
  }

  public convenience init(
    runtime: PutioRuntime,
    reconciliation: PutioTrashReconciliation,
    onRestored: @escaping PutioTrashDidRestore = { _ in }
  ) {
    self.init(
      actions: PutioTrashActions(runtime: runtime),
      reconciliation: reconciliation,
      onRestored: onRestored
    )
  }

  public var page: PutioTrashPage? {
    guard case .loaded(let page) = state else { return nil }
    return page
  }

  public var canMutate: Bool {
    activeMutation == nil && !isRefreshing && !isLoadingMore && !isRefreshingStorage
  }

  public var hasContents: Bool {
    guard let page else { return false }
    return !page.items.isEmpty || page.nextCursor != nil
  }

  /// Changes whenever another Trash screen commits a mutation.
  public var reconciliationVersion: UInt64 { reconciliation.version }

  /// Drops rows another screen has since removed or emptied. A screen that
  /// was popped mid-mutation and reopened loads the pre-mutation rows; the
  /// original model updates only itself when the mutation commits.
  public func applyReconciliation() async {
    guard let currentPage = page else { return }
    let pruned = reconciliation.prune(currentPage)
    if pruned != currentPage { state = .loaded(pruned) }
    // A continuation cursor obtained before another screen's mutation is
    // opaque and may skip rows. The repair reloads from the first page; a
    // busy model runs it once its mutation, refresh, or continuation settles.
    if currentPage.nextCursor != nil { repairRequested = true }
    await repairIfRequested()
  }

  /// Runs the first-page reload another screen's mutation made necessary.
  /// The stale cursor and any retry bound to it go first, so a failed reload
  /// cannot hand the cursor back to Load More.
  private func repairIfRequested() async {
    guard repairRequested, canMutate, !Task.isCancelled else { return }
    repairRequested = false
    guard let currentPage = page else { return }
    if currentPage.nextCursor != nil {
      reconciliation.abandonListing(listingID)
      state = .loaded(
        PutioTrashPage(
          items: currentPage.items,
          nextCursor: nil,
          totalCount: currentPage.totalCount,
          sizeBytes: currentPage.sizeBytes
        ))
      paginationFailure = nil
    }
    await load(initial: false, supersedesRefresh: false)
  }

  /// One first-page response with what the caller needs to apply it. A
  /// response requested before another screen's mutation (any removal or
  /// emptying bumps `version`) is still filtered, but it proves nothing about
  /// what the server knows after that mutation: it never opens a listing that
  /// could release tombstones or settle the emptying cutoff, and if it carries
  /// a cursor that cursor predates the mutation, so a repair is due.
  private struct FirstPage {
    let page: PutioTrashPage
    let crossedMutation: Bool
  }

  private func fetchFirstPage() async throws -> FirstPage {
    let version = reconciliation.version
    let page = try await actions.load(nil)
    return FirstPage(page: page, crossedMutation: version != reconciliation.version)
  }

  private func show(_ first: FirstPage) {
    state = .loaded(openListing(first.page, startsListing: !first.crossedMutation))
    // A fresh first page is the repair; only a cursor obtained across a
    // mutation still needs one.
    repairRequested = first.crossedMutation && page?.nextCursor != nil
  }

  func loadIfNeeded() async {
    guard !hasLoaded else { return }
    await load(initial: true)
  }

  /// The screen is leaving; a partially walked listing will not complete.
  public func abandonListing() {
    isVisible = false
    reconciliation.abandonListing(listingID)
  }

  /// A request that outlives the screen (a mutation repair, a late refresh)
  /// must not leave a listing open that nothing will ever walk or abandon.
  private func openListing(_ page: PutioTrashPage, startsListing: Bool) -> PutioTrashPage {
    reconciliation.abandonListing(listingID)
    listingID = UUID()
    let reconciled = reconciliation.reconcile(
      page, listingID: listingID, startsListing: startsListing)
    if !isVisible { reconciliation.abandonListing(listingID) }
    return reconciled
  }

  /// Called on every appearance. The Account stack keeps this screen alive
  /// across tab switches, and Files may have trashed more items meanwhile.
  public func refreshOnAppear() async {
    isVisible = true
    if hasLoaded {
      // Appearance may follow a tab switch that cancelled the previous
      // refresh; supersede it instead of being refused by its flag. A
      // mutation or continuation still running refuses the reload; Files may
      // have trashed more items meanwhile, so it runs once that work settles.
      if activeMutation != nil || isLoadingMore { repairRequested = true }
      await load(initial: false, supersedesRefresh: true)
    } else {
      await loadIfNeeded()
    }
  }

  public func refresh() async {
    await load(initial: false, supersedesRefresh: false)
  }

  /// Retries only the account storage snapshot after a committed deletion
  /// could not reload it.
  public func retryStorageRefresh() async {
    guard canMutate else { return }
    await reloadStaleStorage()
    await repairIfRequested()
  }

  public func loadMore() async {
    await loadNextPage()
    await repairIfRequested()
  }

  private func loadNextPage() async {
    guard
      !isLoadingMore,
      !isRefreshing,
      activeMutation == nil,
      let currentPage = page,
      let cursor = currentPage.nextCursor
    else { return }

    isLoadingMore = true
    let previousPaginationFailure = paginationFailure
    paginationFailure = nil
    defer { isLoadingMore = false }
    let version = reconciliation.version
    do {
      let nextPage = try await actions.load(cursor)
      if reconciliation.version != version {
        // Another screen committed a mutation while this continuation was in
        // flight. The cursor predates it and may have skipped rows; discard
        // the response and repair from the first page once this call settles.
        repairRequested = true
        return
      }
      let shownPage = page ?? currentPage
      let existingIDs = Set(shownPage.items.map(\.id))
      let fresh = reconciliation.reconcile(nextPage, listingID: listingID, startsListing: false)
      let newItems = fresh.items.filter { !existingIDs.contains($0.id) }
      state = .loaded(
        reconciliation.prune(
          PutioTrashPage(
            items: shownPage.items + newItems,
            nextCursor: fresh.nextCursor,
            totalCount: fresh.totalCount ?? shownPage.totalCount,
            sizeBytes: fresh.sizeBytes
          )))
    } catch is CancellationError {
      paginationFailure = previousPaginationFailure
      return
    } catch {
      paginationFailure = PutioTrashErrorPresentation(
        title: "Could not load more Trash items",
        error: error
      )
    }
  }

  public func restore(_ item: PutioTrashItem) async {
    await mutate(.restore(item)) {
      // Any result means the restore committed; a throw means it did not.
      let result = try await actions.restore(item.id)
      // Tell the browser first: the pagination repair below is best effort
      // and must not delay the restored file appearing in Files.
      switch result {
      case .restored(let destinationID):
        onRestored(destinationID)
      case .restoredDestinationUnknown, .restoredLookupCancelled:
        onRestored(nil)
      }
      await remove(item)
      mutationOutcome = .restored(item)
    }
  }

  public func permanentlyDelete(_ item: PutioTrashItem) async {
    await mutate(.permanentlyDelete(item)) {
      let result = try await actions.permanentlyDelete(item.id)
      await remove(item)
      mutationOutcome = .permanentlyDeleted(item, storageRefreshed: result.storageRefreshed)
    }
  }

  /// Restores the selected rows in batches. A failed batch stops the run; its
  /// rows and those never sent stay listed, and the failure names only them.
  public func restore(_ items: [PutioTrashItem]) async {
    guard !items.isEmpty else { return }
    await mutate(.restoreItems(items)) {
      let sent = await sendInBatches(items) { try await actions.restoreItems($0) }
      if !sent.committed.isEmpty {
        onRestored(nil)
        await remove(sent.committed)
      }
      if let failure = sent.failure {
        throw PutioTrashBatchFailure(
          mutation: .restoreItems(sent.remaining), cause: failure)
      }
      mutationOutcome = .restoredItems(items)
    }
  }

  /// Permanently deletes the selected rows in batches, like `restore(_:)`.
  public func permanentlyDelete(_ items: [PutioTrashItem]) async {
    guard !items.isEmpty else { return }
    await mutate(.permanentlyDeleteItems(items)) {
      var storageRefreshed = true
      let sent = await sendInBatches(items) {
        storageRefreshed = try await actions.permanentlyDeleteItems($0).storageRefreshed
      }
      if !sent.committed.isEmpty { await remove(sent.committed) }
      if let failure = sent.failure {
        throw PutioTrashBatchFailure(
          mutation: .permanentlyDeleteItems(sent.remaining), cause: failure)
      }
      mutationOutcome = .permanentlyDeletedItems(items, storageRefreshed: storageRefreshed)
    }
  }

  private func sendInBatches(
    _ items: [PutioTrashItem],
    _ send: ([PutioFileID]) async throws -> Void
  ) async -> (committed: [PutioTrashItem], remaining: [PutioTrashItem], failure: Error?) {
    var committed: [PutioTrashItem] = []
    for start in stride(from: 0, to: items.count, by: actions.batchSize) {
      let batch = Array(items[start..<min(start + actions.batchSize, items.count)])
      do {
        try await send(batch.map(\.id))
        committed += batch
      } catch {
        return (committed, Array(items[start...]), error)
      }
    }
    return (committed, [], nil)
  }

  /// Restores every item in Trash, including pages never loaded.
  public func restoreAll() async {
    guard hasContents, let currentPage = page else { return }
    await mutate(.restoreAll) {
      let cursor = currentPage.nextCursor
      try await actions.restoreAll(cursor, currentPage.items.map(\.id))
      onRestored(nil)
      if cursor == nil {
        // The loaded rows were the whole Trash.
        await remove(currentPage.items)
      } else {
        // Rows on pages never loaded are restored too; a lagging listing
        // must not bring any of them back.
        reconciliation.recordEmptied()
        state = .loaded(
          PutioTrashPage(items: [], nextCursor: nil, totalCount: 0, sizeBytes: 0))
        refreshFailure = nil
        paginationFailure = nil
      }
      mutationOutcome = .restoredAll
    }
  }

  public func empty() async {
    guard hasContents else { return }
    await mutate(.empty) {
      let result = try await actions.empty()
      // Everything is gone, including rows never loaded; a lagging listing
      // must not bring any of it back.
      reconciliation.recordEmptied()
      state = .loaded(
        PutioTrashPage(items: [], nextCursor: nil, totalCount: 0, sizeBytes: 0)
      )
      refreshFailure = nil
      paginationFailure = nil
      mutationOutcome = .emptied(storageRefreshed: result.storageRefreshed)
    }
  }

  private func reloadStaleStorage() async {
    guard isStorageStale, !isRefreshingStorage else { return }
    isRefreshingStorage = true
    defer {
      isRefreshingStorage = false
      releaseStorageWaiters()
    }
    _ = await actions.refreshStorage()
  }

  /// Runs the storage retry for the current load. A superseded load skips
  /// the listing afterwards, but a still-current one proceeds even if an
  /// older load holds the storage flag.
  private func reloadStaleStorageForLoad() async {
    guard isStorageStale else { return }
    if isRefreshingStorage {
      // Another load owns the retry. Wait until it settles, a newer load
      // supersedes this one, or the caller is cancelled; cancellation ends
      // the stream's iteration.
      let (released, release) = AsyncStream<Never>.makeStream()
      storageWaiters.append(release)
      for await _ in released {}
      return
    }
    await reloadStaleStorage()
  }

  private func releaseStorageWaiters() {
    let waiters = storageWaiters
    storageWaiters = []
    for waiter in waiters { waiter.finish() }
  }

  public func clearMutationOutcome() {
    mutationOutcome = nil
  }

  private func load(initial: Bool, supersedesRefresh: Bool = false) async {
    await performLoad(initial: initial, supersedesRefresh: supersedesRefresh)
    await repairIfRequested()
  }

  private func performLoad(initial: Bool, supersedesRefresh: Bool) async {
    if initial {
      // An initial load may supersede one still unwinding after cancellation.
      guard page == nil else { return }
    } else {
      guard activeMutation == nil, !isLoadingMore else { return }
      // A superseding appearance may interrupt a prior refresh at any point,
      // including while it waits on the storage retry.
      guard supersedesRefresh || (!isRefreshing && !isRefreshingStorage) else { return }
    }
    loadGeneration &+= 1
    let generation = loadGeneration
    releaseStorageWaiters()
    isRefreshing = true
    defer {
      if generation == loadGeneration { isRefreshing = false }
    }
    let previousPage = page
    let previousState = state
    let previousRefreshFailure = refreshFailure
    let previousPaginationFailure = paginationFailure
    if previousPage == nil { state = .loading }
    paginationFailure = nil
    refreshFailure = nil
    do {
      await reloadStaleStorageForLoad()
      guard generation == loadGeneration else { return }
      let first = try await fetchFirstPage()
      guard generation == loadGeneration else { return }
      show(first)
      hasLoaded = true
    } catch is CancellationError {
      guard generation == loadGeneration else { return }
      // A cancelled retry must not hide the failure the user was retrying,
      // nor strand a failed screen on the loading spinner.
      if !hasLoaded, case .failed = previousState { state = previousState }
      refreshFailure = previousRefreshFailure
      paginationFailure = previousPaginationFailure
      return
    } catch {
      guard generation == loadGeneration else { return }
      if let shownPage = page ?? previousPage {
        // The shown page may already reflect another screen's mutation.
        state = .loaded(reconciliation.prune(shownPage))
        refreshFailure = PutioTrashErrorPresentation(title: "Could not refresh Trash", error: error)
      } else if let failure = PutioTrashErrorPresentation(
        title: "Could not load Trash",
        error: error
      ) {
        state = .failed(failure)
      }
    }
  }

  private func mutate(
    _ mutation: PutioTrashMutation,
    operation: () async throws -> Void
  ) async {
    guard canMutate, page != nil else { return }
    activeMutation = mutation
    mutationOutcome = nil
    do {
      try await operation()
    } catch is CancellationError {
      // Unreachable in practice: mutations run in unstructured tasks nobody
      // cancels. Kept so the state machine stays total.
    } catch {
      let batch = error as? PutioTrashBatchFailure
      let failedMutation = batch?.mutation ?? mutation
      if let failure = PutioTrashErrorPresentation(
        title: failureTitle(for: failedMutation),
        error: batch?.cause ?? error
      ) {
        mutationOutcome = .failed(failedMutation, failure)
      }
    }
    activeMutation = nil
    // A repair another screen requested while this mutation ran.
    await repairIfRequested()
  }

  // Removes the rows locally, then replaces the page when a continuation was
  // pending: the pre-mutation cursor is opaque and may skip or resurrect rows.
  private func remove(_ item: PutioTrashItem) async {
    await remove([item])
  }

  private func remove(_ removedItems: [PutioTrashItem]) async {
    guard let currentPage = page else { return }
    let ids = Set(removedItems.map(\.id))
    for item in removedItems { reconciliation.recordRemoval(of: item) }
    let removed = currentPage.items.filter { ids.contains($0.id) }
    let removedSize = removed.reduce(Int64(0)) { $0 + $1.sizeBytes }
    let items = currentPage.items.filter { !ids.contains($0.id) }
    state = .loaded(
      PutioTrashPage(
        items: items,
        nextCursor: currentPage.nextCursor,
        totalCount: currentPage.totalCount.map { max(0, $0 - removed.count) },
        sizeBytes: max(0, currentPage.sizeBytes - removedSize)
      )
    )
    guard currentPage.nextCursor != nil else { return }
    do {
      show(try await fetchFirstPage())
      // The fresh listing supersedes any earlier list failure.
      refreshFailure = nil
      paginationFailure = nil
    } catch {
      // The mutation is committed; keep the shown page (already pruned of
      // these rows and of anything another screen removed meanwhile) and drop
      // the stale cursor so Load More cannot replay it. Pull to refresh
      // recovers.
      let shownPage = page ?? currentPage
      state = .loaded(
        reconciliation.prune(
          PutioTrashPage(
            items: shownPage.items.filter { !ids.contains($0.id) },
            nextCursor: nil,
            totalCount: shownPage.totalCount,
            sizeBytes: shownPage.sizeBytes
          )))
      // Load More has nothing left to retry once the cursor is gone.
      paginationFailure = nil
      if !(error is CancellationError) {
        refreshFailure = PutioTrashErrorPresentation(
          title: "Could not refresh Trash", error: error)
      }
    }
  }

  private func failureTitle(for mutation: PutioTrashMutation) -> String {
    switch mutation {
    case .restore: "Could not restore item"
    case .permanentlyDelete: "Could not permanently delete item"
    case .restoreItems: "Could not restore items"
    case .permanentlyDeleteItems: "Could not permanently delete items"
    case .restoreAll: "Could not restore Trash"
    case .empty: "Could not empty Trash"
    }
  }
}

/// Maps a Trash restore back onto the Files browser: a known destination
/// refreshes that folder; an unknown one refreshes every loaded folder.
public enum PutioRestoredFileReconciliation {
  @MainActor
  public static func apply(destinationID: PutioFileID?, to requests: PutioFolderRefreshRequests) {
    if let destinationID {
      requests.request(folderID: destinationID)
    } else {
      requests.requestAllLoadedFolders()
    }
  }
}
