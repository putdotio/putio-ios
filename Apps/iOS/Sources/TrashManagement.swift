import Observation
import PutioCore
import SwiftUI

typealias PutioTrashLoad = @MainActor @Sendable (String?) async throws -> PutioTrashPage
typealias PutioTrashRestore =
  @MainActor @Sendable (PutioFileID) async throws -> PutioTrashRestoreResult
typealias PutioTrashItemMutation =
  @MainActor @Sendable (PutioFileID) async throws -> PutioTrashMutationResult
typealias PutioTrashEmpty = @MainActor @Sendable () async throws -> PutioTrashMutationResult
typealias PutioTrashStorageRefresh = @MainActor @Sendable () async -> Bool
typealias PutioTrashStorageIsStale = @MainActor @Sendable () -> Bool
typealias PutioTrashDidRestore = @MainActor @Sendable (PutioFileID?) -> Void

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
final class PutioTrashReconciliation {
  /// One trashed generation of a file: the same file re-trashed later has a
  /// newer `deletedAt` and is a different generation.
  struct Removal: Hashable, Sendable {
    let id: PutioFileID
    let deletedAt: Date
  }

  static let consistentListingsBeforeTrust = 2

  /// Complete listings in which each removal has still appeared.
  @ObservationIgnored private(set) var removals: [Removal: Int] = [:]
  /// Set after emptying: every item trashed at or before this instant is
  /// treated as gone. Bounded by the rows loaded at the time (server
  /// `deletedAt` values, never the device clock).
  @ObservationIgnored private(set) var emptiedThrough: Date?
  @ObservationIgnored private var emptiedListings = 0
  @ObservationIgnored private var seenSinceFirstPage: Set<Removal> = []
  @ObservationIgnored private var sawEmptiedItemSinceFirstPage = false

  init() {}

  func recordRemoval(of item: PutioTrashItem) {
    removals[Removal(id: item.id, deletedAt: item.deletedAt)] = 0
  }

  /// `loaded` are the rows known at emptying; rows on unloaded pages are
  /// covered only when their deletion is not newer than the newest loaded
  /// one. The bound above heals any gap after a couple of refreshes.
  func recordEmptied(loaded: [PutioTrashItem]) {
    guard let newest = loaded.map(\.deletedAt).max() else { return }
    emptiedThrough = max(emptiedThrough ?? .distantPast, newest)
    emptiedListings = 0
  }

  func isRemoved(_ item: PutioTrashItem) -> Bool {
    if removals[Removal(id: item.id, deletedAt: item.deletedAt)] != nil { return true }
    guard let emptiedThrough else { return false }
    return item.deletedAt <= emptiedThrough
  }

  /// Filters a listing page. On the final page of a complete listing it
  /// releases every tombstone the server omitted, and every tombstone the
  /// server has now reported `consistentListingsBeforeTrust` times.
  func reconcile(_ listing: PutioTrashPage, startsListing: Bool) -> PutioTrashPage {
    if startsListing {
      seenSinceFirstPage.removeAll()
      sawEmptiedItemSinceFirstPage = false
    }
    seenSinceFirstPage.formUnion(listing.items.map { Removal(id: $0.id, deletedAt: $0.deletedAt) })
    let survivors = listing.items.filter { !isRemoved($0) }
    if let emptiedThrough, listing.items.contains(where: { $0.deletedAt <= emptiedThrough }) {
      sawEmptiedItemSinceFirstPage = true
    }
    if listing.nextCursor == nil { settleCompleteListing() }
    guard survivors.count != listing.items.count else { return listing }
    // totalCount and sizeBytes are server aggregates, not row sums.
    return PutioTrashPage(
      items: survivors,
      nextCursor: listing.nextCursor,
      totalCount: listing.totalCount,
      sizeBytes: listing.sizeBytes
    )
  }

  private func settleCompleteListing() {
    for (removal, listings) in removals {
      guard seenSinceFirstPage.contains(removal) else {
        removals[removal] = nil
        continue
      }
      let reported = listings + 1
      removals[removal] = reported < Self.consistentListingsBeforeTrust ? reported : nil
    }
    guard emptiedThrough != nil else { return }
    if !sawEmptiedItemSinceFirstPage {
      emptiedThrough = nil
    } else {
      emptiedListings += 1
      if emptiedListings >= Self.consistentListingsBeforeTrust { emptiedThrough = nil }
    }
  }
}

struct PutioTrashActions: Sendable {
  let load: PutioTrashLoad
  let restore: PutioTrashRestore
  let permanentlyDelete: PutioTrashItemMutation
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
    empty = { try await runtime.emptyTrash() }
    refreshStorage = { await runtime.refreshAccountStorage() }
    isStorageStale = { runtime.session.isAccountStorageStale }
  }

  init(
    load: @escaping PutioTrashLoad,
    restore: @escaping PutioTrashRestore,
    permanentlyDelete: @escaping PutioTrashItemMutation,
    empty: @escaping PutioTrashEmpty,
    refreshStorage: @escaping PutioTrashStorageRefresh = { true },
    isStorageStale: @escaping PutioTrashStorageIsStale = { false }
  ) {
    self.load = load
    self.restore = restore
    self.permanentlyDelete = permanentlyDelete
    self.empty = empty
    self.refreshStorage = refreshStorage
    self.isStorageStale = isStorageStale
  }
}

struct PutioTrashErrorPresentation: Equatable, Sendable {
  let title: String
  let message: String

  init(title: String, message: String) {
    self.title = title
    self.message = message
  }

  static let staleStorage = PutioTrashErrorPresentation(
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

enum PutioTrashLoadState: Equatable, Sendable {
  case loading
  case loaded(PutioTrashPage)
  case failed(PutioTrashErrorPresentation)
}

enum PutioTrashMutation: Equatable, Sendable {
  case restore(PutioTrashItem)
  case permanentlyDelete(PutioTrashItem)
  case empty
}

enum PutioTrashMutationOutcome: Equatable, Sendable {
  case restored(PutioTrashItem)
  /// `storageRefreshed` is false when the deletion committed but the account
  /// storage totals could not be reloaded; the next Trash refresh retries them.
  case permanentlyDeleted(PutioTrashItem, storageRefreshed: Bool = true)
  case emptied(storageRefreshed: Bool = true)
  case failed(PutioTrashMutation, PutioTrashErrorPresentation)
}

@MainActor
@Observable
final class PutioTrashModel {
  private(set) var state: PutioTrashLoadState = .loading
  private(set) var activeMutation: PutioTrashMutation?
  private(set) var mutationOutcome: PutioTrashMutationOutcome?
  private(set) var isRefreshing = false
  private(set) var isLoadingMore = false
  private(set) var paginationFailure: PutioTrashErrorPresentation?
  private(set) var refreshFailure: PutioTrashErrorPresentation?
  private(set) var isRefreshingStorage = false

  /// Mirrors the session's stale-storage state; the retry only reloads
  /// account storage.
  var isStorageStale: Bool { actions.isStorageStale() }

  var storageFailure: PutioTrashErrorPresentation? {
    guard isStorageStale else { return nil }
    return PutioTrashErrorPresentation.staleStorage
  }

  @ObservationIgnored private let actions: PutioTrashActions
  @ObservationIgnored private let onRestored: PutioTrashDidRestore
  @ObservationIgnored private var hasLoaded = false
  // Supersedes an initial load that is still unwinding after cancellation so
  // re-entering the screen cannot strand it on the loading state.
  @ObservationIgnored private var loadGeneration: UInt64 = 0
  @ObservationIgnored private let reconciliation: PutioTrashReconciliation

  init(
    actions: PutioTrashActions,
    reconciliation: PutioTrashReconciliation? = nil,
    onRestored: @escaping PutioTrashDidRestore = { _ in }
  ) {
    self.actions = actions
    self.reconciliation = reconciliation ?? PutioTrashReconciliation()
    self.onRestored = onRestored
  }

  convenience init(
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

  var page: PutioTrashPage? {
    guard case .loaded(let page) = state else { return nil }
    return page
  }

  var canMutate: Bool {
    activeMutation == nil && !isRefreshing && !isLoadingMore && !isRefreshingStorage
  }

  func loadIfNeeded() async {
    guard !hasLoaded else { return }
    await load(initial: true)
  }

  /// Called on every appearance. The Account stack keeps this screen alive
  /// across tab switches, and Files may have trashed more items meanwhile.
  func refreshOnAppear() async {
    if hasLoaded {
      await refresh()
    } else {
      await loadIfNeeded()
    }
  }

  func refresh() async {
    await load(initial: false)
  }

  /// Retries only the account storage snapshot after a committed deletion
  /// could not reload it.
  func retryStorageRefresh() async {
    guard canMutate else { return }
    await reloadStaleStorage()
  }

  func loadMore() async {
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
    do {
      let nextPage = try await actions.load(cursor)
      let existingIDs = Set(currentPage.items.map(\.id))
      let fresh = reconciliation.reconcile(nextPage, startsListing: false)
      let newItems = fresh.items.filter { !existingIDs.contains($0.id) }
      state = .loaded(
        PutioTrashPage(
          items: currentPage.items + newItems,
          nextCursor: fresh.nextCursor,
          totalCount: fresh.totalCount ?? currentPage.totalCount,
          sizeBytes: fresh.sizeBytes
        )
      )
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

  func restore(_ item: PutioTrashItem) async {
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

  func permanentlyDelete(_ item: PutioTrashItem) async {
    await mutate(.permanentlyDelete(item)) {
      let result = try await actions.permanentlyDelete(item.id)
      await remove(item)
      mutationOutcome = .permanentlyDeleted(item, storageRefreshed: result.storageRefreshed)
    }
  }

  func empty() async {
    await mutate(.empty) {
      let result = try await actions.empty()
      // Everything trashed up to now is gone; a lagging refresh must not
      // bring the loaded rows back. The bound in the reconciliation heals
      // anything this cutoff misjudges.
      reconciliation.recordEmptied(loaded: page?.items ?? [])
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
    defer { isRefreshingStorage = false }
    _ = await actions.refreshStorage()
  }

  func clearMutationOutcome() {
    mutationOutcome = nil
  }

  private func load(initial: Bool) async {
    if initial {
      // An initial load may supersede one still unwinding after cancellation.
      guard page == nil else { return }
    } else {
      guard activeMutation == nil, !isRefreshing, !isLoadingMore, !isRefreshingStorage else {
        return
      }
    }
    loadGeneration &+= 1
    let generation = loadGeneration
    isRefreshing = true
    defer {
      if generation == loadGeneration { isRefreshing = false }
    }
    let previousPage = page
    let previousRefreshFailure = refreshFailure
    let previousPaginationFailure = paginationFailure
    if previousPage == nil { state = .loading }
    paginationFailure = nil
    refreshFailure = nil
    do {
      await reloadStaleStorage()
      let loadedPage = try await actions.load(nil)
      guard generation == loadGeneration else { return }
      state = .loaded(reconciliation.reconcile(loadedPage, startsListing: true))
      hasLoaded = true
    } catch is CancellationError {
      guard generation == loadGeneration else { return }
      // A cancelled retry must not hide the failure the user was retrying.
      refreshFailure = previousRefreshFailure
      paginationFailure = previousPaginationFailure
      return
    } catch {
      guard generation == loadGeneration else { return }
      if let previousPage {
        state = .loaded(previousPage)
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
    defer { activeMutation = nil }
    do {
      try await operation()
    } catch is CancellationError {
      return
    } catch {
      guard
        let failure = PutioTrashErrorPresentation(
          title: failureTitle(for: mutation),
          error: error
        )
      else { return }
      mutationOutcome = .failed(mutation, failure)
    }
  }

  // Removes the row locally, then replaces the page when a continuation was
  // pending: the pre-mutation cursor is opaque and may skip or resurrect rows.
  private func remove(_ item: PutioTrashItem) async {
    guard let currentPage = page else { return }
    let id = item.id
    reconciliation.recordRemoval(of: item)
    let removedSize = item.sizeBytes
    let items = currentPage.items.filter { $0.id != id }
    state = .loaded(
      PutioTrashPage(
        items: items,
        nextCursor: currentPage.nextCursor,
        totalCount: currentPage.totalCount.map { max(0, $0 - 1) },
        sizeBytes: max(0, currentPage.sizeBytes - removedSize)
      )
    )
    guard currentPage.nextCursor != nil else { return }
    do {
      state = .loaded(reconciliation.reconcile(try await actions.load(nil), startsListing: true))
    } catch {
      // The mutation is committed; keep the local page and drop the stale
      // cursor so Load More cannot replay it. Pull to refresh recovers.
      state = .loaded(
        PutioTrashPage(
          items: items,
          nextCursor: nil,
          totalCount: currentPage.totalCount.map { max(0, $0 - 1) },
          sizeBytes: max(0, currentPage.sizeBytes - removedSize)
        )
      )
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
    case .empty: "Could not empty Trash"
    }
  }
}

struct TrashManagementView: View {
  @State private var model: PutioTrashModel
  @State private var pendingDeletion: PutioTrashItem?
  @State private var emptyConfirmationPresented = false
  @State private var toast: PutioToast?

  init(
    runtime: PutioRuntime,
    reconciliation: PutioTrashReconciliation,
    onRestored: @escaping PutioTrashDidRestore
  ) {
    _model = State(
      initialValue: PutioTrashModel(
        runtime: runtime, reconciliation: reconciliation, onRestored: onRestored))
  }

  init(
    actions: PutioTrashActions,
    onRestored: @escaping PutioTrashDidRestore = { _ in }
  ) {
    _model = State(initialValue: PutioTrashModel(actions: actions, onRestored: onRestored))
  }

  var body: some View {
    Group {
      switch model.state {
      case .loading:
        PutioLoadingStateView(title: "Loading Trash")
      case .failed(let failure):
        PutioErrorStateView(
          title: failure.title,
          message: failure.message,
          retryTitle: "Try again"
        ) {
          Task { await model.refresh() }
        }
      case .loaded(let page):
        loadedContent(page)
      }
    }
    .navigationTitle("Trash")
    .putioContentBackground()
    .toolbar {
      if let page = model.page, !page.items.isEmpty || page.nextCursor != nil {
        ToolbarItem(placement: .primaryAction) {
          Button("Empty Trash", role: .destructive) {
            emptyConfirmationPresented = true
          }
          .disabled(!model.canMutate)
          .accessibilityIdentifier("trash.empty")
        }
      }
    }
    .confirmationDialog(
      deletionConfirmationTitle,
      isPresented: deletionConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button("Delete Permanently", role: .destructive) {
        guard let item = pendingDeletion else { return }
        pendingDeletion = nil
        Task { await model.permanentlyDelete(item) }
      }
      .accessibilityIdentifier("trash.delete-confirm")
      Button("Cancel", role: .cancel) { pendingDeletion = nil }
    } message: {
      Text("This item cannot be restored.")
    }
    .confirmationDialog(
      "Empty Trash permanently?",
      isPresented: $emptyConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button("Empty Trash", role: .destructive) {
        Task { await model.empty() }
      }
      .accessibilityIdentifier("trash.empty-confirm")
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Every item in Trash will be deleted and cannot be restored.")
    }
    .putioToast($toast)
    .overlay {
      if model.activeMutation != nil {
        ProgressView("Updating Trash…")
          .controlSize(.large)
          .padding(PutioTheme.Spacing.space4)
          .glassEffect()
          .accessibilityElement(children: .combine)
          .accessibilityLabel("Updating Trash")
          .accessibilityIdentifier("trash.progress")
      }
    }
    .task { await model.refreshOnAppear() }
    .onChange(of: model.mutationOutcome) { _, outcome in
      present(outcome)
    }
    .task(id: toast) {
      guard let presentedToast = toast else { return }
      try? await Task.sleep(for: .seconds(3))
      guard !Task.isCancelled, toast == presentedToast else { return }
      toast = nil
    }
  }

  @ViewBuilder
  private func loadedContent(_ page: PutioTrashPage) -> some View {
    if page.items.isEmpty && page.nextCursor == nil && model.refreshFailure == nil
      && model.storageFailure == nil
    {
      ScrollView {
        PutioEmptyStateView(
          icon: .trash,
          title: "Trash is empty",
          message: "Items you move to Trash appear here until they expire."
        )
        .containerRelativeFrame([.horizontal, .vertical])
      }
      .refreshable { await model.refresh() }
    } else {
      List {
        if let failure = model.refreshFailure {
          Section {
            PutioErrorStateView(
              title: failure.title,
              message: failure.message,
              retryTitle: "Try again"
            ) {
              Task { await model.refresh() }
            }
          }
        }
        storageFailureSection
        ForEach(page.items) { item in
          HStack {
            PutioFileRow(rowModel(for: item), showsFolderDisclosure: false)
            Menu {
              Button("Restore") {
                Task { await model.restore(item) }
              }
              .accessibilityIdentifier("trash.restore.\(item.id.rawValue)")
              Button("Delete Permanently", role: .destructive) {
                pendingDeletion = item
              }
              .accessibilityIdentifier("trash.delete.\(item.id.rawValue)")
            } label: {
              Image(putioIcon: .dotsThreeCircle)
                .foregroundStyle(PutioTheme.Colors.accent)
            }
            .disabled(!model.canMutate)
            .accessibilityLabel("More actions for \(item.name)")
            .accessibilityIdentifier("trash.item.\(item.id.rawValue).actions")
          }
          .listRowBackground(PutioTheme.Colors.surface)
          .swipeActions(edge: .leading) {
            Button("Restore") {
              Task { await model.restore(item) }
            }
            .disabled(!model.canMutate)
            .tint(PutioTheme.Colors.success)
          }
          .swipeActions(edge: .trailing) {
            Button("Delete", role: .destructive) { pendingDeletion = item }
              .disabled(!model.canMutate)
          }
        }
        if page.nextCursor != nil {
          Section {
            Button(model.isLoadingMore ? "Loading…" : "Load More") {
              Task { await model.loadMore() }
            }
            .disabled(model.isLoadingMore || !model.canMutate)
            .accessibilityIdentifier("trash.load-more")
          }
        }
        if let failure = model.paginationFailure {
          Section {
            PutioErrorStateView(
              title: failure.title,
              message: failure.message,
              retryTitle: "Try again"
            ) {
              Task { await model.loadMore() }
            }
          }
        }
      }
      .refreshable { await model.refresh() }
      .accessibilityIdentifier("trash.list")
    }
  }

  private var deletionConfirmationPresented: Binding<Bool> {
    Binding(
      get: { pendingDeletion != nil },
      set: { if !$0 { pendingDeletion = nil } }
    )
  }

  private var deletionConfirmationTitle: String {
    guard let pendingDeletion else { return "Delete permanently?" }
    return "Delete “\(pendingDeletion.name)” permanently?"
  }

  @ViewBuilder
  private var storageFailureSection: some View {
    if let failure = model.storageFailure {
      Section {
        PutioErrorStateView(
          title: failure.title,
          message: failure.message,
          retryTitle: model.isRefreshingStorage ? "Updating…" : "Update storage"
        ) {
          Task { await model.retryStorageRefresh() }
        }
        .disabled(model.isRefreshingStorage)
        .accessibilityIdentifier("trash.storage-retry")
      }
    }
  }

  private func rowModel(for item: PutioTrashItem) -> PutioFileRowModel {
    PutioFileRowModel(
      name: item.name,
      kind: rowKind(for: item.kind),
      sizeText: PutioFileRowModel.sizeText(bytes: item.sizeBytes)
    )
  }

  private func rowKind(for kind: PutioFileKind) -> PutioFileRowModel.Kind {
    switch kind {
    case .folder: .folder
    case .video: .video
    case .audio: .audio
    case .image: .image
    case .pdf, .other: .file
    }
  }

  private static let staleStorageMessage =
    "Storage totals could not be updated. Use Update storage to retry."

  private func present(_ outcome: PutioTrashMutationOutcome?) {
    guard let outcome else { return }
    switch outcome {
    case .restored(let item):
      toast = PutioToast(variant: .success, title: "Item restored", message: item.name)
    case .permanentlyDeleted(let item, let storageRefreshed):
      toast = PutioToast(
        variant: storageRefreshed ? .success : .info,
        title: "Item deleted",
        message: storageRefreshed ? item.name : Self.staleStorageMessage
      )
    case .emptied(let storageRefreshed):
      toast = PutioToast(
        variant: storageRefreshed ? .success : .info,
        title: "Trash emptied",
        message: storageRefreshed ? nil : Self.staleStorageMessage
      )
    case .failed(_, let failure):
      toast = PutioToast(variant: .danger, title: failure.title, message: failure.message)
    }
    model.clearMutationOutcome()
  }
}
