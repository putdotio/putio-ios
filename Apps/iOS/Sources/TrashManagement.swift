import Observation
import PutioCore
import SwiftUI

typealias PutioTrashLoad = @MainActor @Sendable (String?) async throws -> PutioTrashPage
typealias PutioTrashRestore =
  @MainActor @Sendable (PutioFileID) async throws -> PutioFileItem
typealias PutioTrashItemMutation = @MainActor @Sendable (PutioFileID) async throws -> Void
typealias PutioTrashEmpty = @MainActor @Sendable () async throws -> Void

struct PutioTrashActions: Sendable {
  let load: PutioTrashLoad
  let restore: PutioTrashRestore
  let permanentlyDelete: PutioTrashItemMutation
  let empty: PutioTrashEmpty

  init(runtime: PutioRuntime) {
    load = { cursor in try await runtime.listTrash(cursor: cursor) }
    restore = { fileID in try await runtime.restoreTrashItem(fileID: fileID) }
    permanentlyDelete = { fileID in
      try await runtime.permanentlyDeleteTrashItem(fileID: fileID)
    }
    empty = { try await runtime.emptyTrash() }
  }

  init(
    load: @escaping PutioTrashLoad,
    restore: @escaping PutioTrashRestore,
    permanentlyDelete: @escaping PutioTrashItemMutation,
    empty: @escaping PutioTrashEmpty
  ) {
    self.load = load
    self.restore = restore
    self.permanentlyDelete = permanentlyDelete
    self.empty = empty
  }
}

struct PutioTrashErrorPresentation: Equatable, Sendable {
  let title: String
  let message: String

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
  case restored(PutioTrashItem, destinationID: PutioFileID)
  case permanentlyDeleted(PutioTrashItem)
  case emptied
  case failed(PutioTrashMutation, PutioTrashErrorPresentation)
}

@MainActor
@Observable
final class PutioTrashModel {
  private(set) var state: PutioTrashLoadState = .loading
  private(set) var activeMutation: PutioTrashMutation?
  private(set) var mutationOutcome: PutioTrashMutationOutcome?
  private(set) var isLoadingMore = false
  private(set) var paginationFailure: PutioTrashErrorPresentation?

  @ObservationIgnored private let actions: PutioTrashActions
  @ObservationIgnored private var hasLoaded = false

  init(actions: PutioTrashActions) {
    self.actions = actions
  }

  convenience init(runtime: PutioRuntime) {
    self.init(actions: PutioTrashActions(runtime: runtime))
  }

  var page: PutioTrashPage? {
    guard case .loaded(let page) = state else { return nil }
    return page
  }

  var canMutate: Bool {
    activeMutation == nil && !isLoadingMore
  }

  func loadIfNeeded() async {
    guard !hasLoaded else { return }
    await load()
  }

  func refresh() async {
    await load()
  }

  func loadMore() async {
    guard
      !isLoadingMore,
      activeMutation == nil,
      let currentPage = page,
      let cursor = currentPage.nextCursor
    else { return }

    isLoadingMore = true
    paginationFailure = nil
    defer { isLoadingMore = false }
    do {
      let nextPage = try await actions.load(cursor)
      let existingIDs = Set(currentPage.items.map(\.id))
      let newItems = nextPage.items.filter { !existingIDs.contains($0.id) }
      state = .loaded(
        PutioTrashPage(
          items: currentPage.items + newItems,
          nextCursor: nextPage.nextCursor,
          totalCount: nextPage.totalCount ?? currentPage.totalCount,
          sizeBytes: nextPage.sizeBytes
        )
      )
    } catch is CancellationError {
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
      let restoredItem = try await actions.restore(item.id)
      remove(item.id)
      mutationOutcome = .restored(item, destinationID: restoredItem.parentID)
    }
  }

  func permanentlyDelete(_ item: PutioTrashItem) async {
    await mutate(.permanentlyDelete(item)) {
      try await actions.permanentlyDelete(item.id)
      remove(item.id)
      mutationOutcome = .permanentlyDeleted(item)
    }
  }

  func empty() async {
    await mutate(.empty) {
      try await actions.empty()
      guard let currentPage = page else { return }
      state = .loaded(
        PutioTrashPage(items: [], nextCursor: nil, totalCount: 0, sizeBytes: 0)
      )
      if !currentPage.items.isEmpty {
        mutationOutcome = .emptied
      }
    }
  }

  func clearMutationOutcome() {
    mutationOutcome = nil
  }

  private func load() async {
    guard activeMutation == nil else { return }
    let previousPage = page
    if previousPage == nil { state = .loading }
    paginationFailure = nil
    do {
      let loadedPage = try await actions.load(nil)
      state = .loaded(loadedPage)
      hasLoaded = true
    } catch is CancellationError {
      return
    } catch {
      if let previousPage {
        state = .loaded(previousPage)
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

  private func remove(_ id: PutioFileID) {
    guard let currentPage = page else { return }
    let removedSize = currentPage.items.first { $0.id == id }?.sizeBytes ?? 0
    let items = currentPage.items.filter { $0.id != id }
    state = .loaded(
      PutioTrashPage(
        items: items,
        nextCursor: currentPage.nextCursor,
        totalCount: currentPage.totalCount.map { max(0, $0 - 1) },
        sizeBytes: max(0, currentPage.sizeBytes - removedSize)
      )
    )
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

  private let onRestored: @MainActor @Sendable (PutioFileID) -> Void

  init(
    runtime: PutioRuntime,
    onRestored: @escaping @MainActor @Sendable (PutioFileID) -> Void
  ) {
    _model = State(initialValue: PutioTrashModel(runtime: runtime))
    self.onRestored = onRestored
  }

  init(
    actions: PutioTrashActions,
    onRestored: @escaping @MainActor @Sendable (PutioFileID) -> Void = { _ in }
  ) {
    _model = State(initialValue: PutioTrashModel(actions: actions))
    self.onRestored = onRestored
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
      if let page = model.page, !page.items.isEmpty {
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
          .accessibilityIdentifier("trash.progress")
      }
    }
    .task { await model.loadIfNeeded() }
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
    if page.items.isEmpty {
      PutioEmptyStateView(
        icon: .trash,
        title: "Trash is empty",
        message: "Items you move to Trash appear here until they expire."
      )
    } else {
      List {
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
            .tint(PutioTheme.Colors.success)
          }
          .swipeActions(edge: .trailing) {
            Button("Delete", role: .destructive) { pendingDeletion = item }
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

  private func present(_ outcome: PutioTrashMutationOutcome?) {
    guard let outcome else { return }
    switch outcome {
    case .restored(let item, let destinationID):
      onRestored(destinationID)
      toast = PutioToast(variant: .success, title: "Item restored", message: item.name)
    case .permanentlyDeleted(let item):
      toast = PutioToast(variant: .success, title: "Item deleted", message: item.name)
    case .emptied:
      toast = PutioToast(variant: .success, title: "Trash emptied")
    case .failed(_, let failure):
      toast = PutioToast(variant: .danger, title: failure.title, message: failure.message)
    }
    model.clearMutationOutcome()
  }
}
