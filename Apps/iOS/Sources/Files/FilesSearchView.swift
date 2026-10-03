import Foundation
import Observation
import PutioCore
import SwiftUI

@MainActor
struct FilesSearchView: View {
  let runtime: PutioRuntime
  let trashEnabled: Bool
  let refreshRequests: PutioFolderRefreshRequests
  let onFileSelected: PutioFileSelection

  @State private var query = ""
  @State private var model: PutioFileSearchModel
  @State private var itemActions: PutioFileItemActionModel
  @State private var itemAction: PutioFileItemActionRequest?

  init(
    runtime: PutioRuntime,
    trashEnabled: Bool,
    refreshRequests: PutioFolderRefreshRequests,
    onFileSelected: @escaping PutioFileSelection
  ) {
    self.runtime = runtime
    self.trashEnabled = trashEnabled
    self.refreshRequests = refreshRequests
    self.onFileSelected = onFileSelected
    _model = State(
      initialValue: PutioFileSearchModel(
        search: { try await runtime.searchFiles(query: $0) },
        continueSearch: { try await runtime.continueFileSearch(cursor: $0) }
      ))
    _itemActions = State(
      initialValue: PutioFileItemActionModel(
        actions: PutioFileActions(runtime: runtime), refreshRequests: refreshRequests))
  }

  var body: some View {
    NavigationStack {
      results
        .navigationTitle("Search")
        .putioContentBackground()
        .searchable(text: $query, prompt: "Search in Files")
        .task(id: Request(query: query, revision: refreshRequests.revision)) {
          await model.apply(query: query, revision: refreshRequests.revision)
        }
        .navigationDestination(for: PutioFolderRoute.self) { route in
          PutioFolderScreen(
            route: route,
            load: { try await runtime.listFiles(parentID: $0) },
            continueLoad: { try await runtime.continueFiles(cursor: $0) },
            actions: PutioFileActions(runtime: runtime),
            trashEnabled: trashEnabled,
            refreshRequests: refreshRequests,
            onFileSelected: onFileSelected
          )
        }
        .modifier(
          PutioFileItemActionsHost(
            request: $itemAction,
            model: itemActions,
            actions: PutioFileActions(runtime: runtime),
            load: { try await runtime.listFiles(parentID: $0) },
            continueLoad: { try await runtime.continueFiles(cursor: $0) },
            trashEnabled: trashEnabled,
            refreshRequests: refreshRequests
          )
        )
        .onChange(of: model.state) { itemActions.revealHiddenItems() }
    }
  }

  @ViewBuilder
  private var results: some View {
    switch model.state {
    case .idle:
      PutioEmptyStateView(
        icon: .file, title: "Search your files", message: "Find files by their stored name.")
    case .loading:
      PutioLoadingStateView(title: "Searching files")
    case .failed(let failure):
      PutioErrorStateView(
        title: "Could not search files", message: failure.message,
        retryTitle: "Try again",
        retryIdentifier: "files.search-retry"
      ) {
        Task { await model.refresh(query: query, revision: refreshRequests.revision) }
      }
    case .loaded(let page):
      if page.items.isEmpty, page.nextCursor == nil, model.refreshFailure == nil {
        GeometryReader { geometry in
          ScrollView {
            PutioEmptyStateView(
              icon: .file, title: "No results", message: "Try a different file name."
            )
            .frame(minHeight: geometry.size.height)
          }
          .scrollBounceBehavior(.always)
          .refreshable { await model.refresh(query: query, revision: refreshRequests.revision) }
        }
      } else {
        List {
          if let failure = model.refreshFailure {
            VStack(spacing: PutioTheme.Spacing.space2) {
              Text(failure.message)
                .putioFont(PutioTheme.Typography.caption)
              Button("Try again") {
                Task { await model.refresh(query: query, revision: refreshRequests.revision) }
              }
              .accessibilityIdentifier("files.search-retry")
            }
            .listRowBackground(PutioTheme.Colors.background)
          }
          ForEach(page.items.filter { !itemActions.hiddenIDs.contains($0.id) }) { item in
            resultRow(PutioBrowserItemPresentation(item: item))
              .listRowBackground(PutioTheme.Colors.background)
          }
          if let cursor = page.nextCursor, model.refreshFailure == nil {
            Group {
              if let failure = model.loadMoreFailure {
                VStack(spacing: PutioTheme.Spacing.space2) {
                  Text(failure.message)
                    .putioFont(PutioTheme.Typography.caption)
                  Button("Try again") { Task { await model.loadMore() } }
                    .accessibilityIdentifier("files.search-more-retry")
                }
              } else {
                ProgressView("Loading more results")
                  .task(
                    id: PageRequest(
                      cursor: cursor, generation: model.generation, isSearching: model.isSearching,
                      epoch: model.paginationEpoch)
                  ) {
                    await model.loadMore()
                  }
              }
            }
            .listRowBackground(PutioTheme.Colors.background)
          }
        }
        .listStyle(.plain)
        .refreshable { await model.refresh(query: query, revision: refreshRequests.revision) }
      }
    }
  }

  @ViewBuilder
  private func resultRow(_ presentation: PutioBrowserItemPresentation) -> some View {
    Group {
      if let route = presentation.folderRoute {
        NavigationLink(value: route) { PutioFileRow(presentation.row) }
      } else if let route = presentation.fileRoute {
        Button {
          onFileSelected(route)
        } label: {
          PutioFileRow(presentation.row)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
    .accessibilityIdentifier("files.search-item.\(presentation.id.rawValue)")
    .contextMenu { itemActionButtons(for: presentation.item) }
    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
      itemActionButtons(for: presentation.item).deleteButton
        .tint(PutioTheme.Colors.destructive)
    }
    .swipeActions(edge: .leading, allowsFullSwipe: false) {
      itemActionButtons(for: presentation.item).moveButton
        .tint(PutioTheme.Colors.accent)
    }
  }

  private func itemActionButtons(for item: PutioFileItem) -> PutioFileItemActionButtons {
    PutioFileItemActionButtons(
      item: item,
      trashEnabled: trashEnabled,
      isDisabled: !itemActions.canStartAction || itemAction != nil,
      canDelete: itemActions.canDelete
    ) { request in
      if trashEnabled, case .delete(let item) = request { itemActions.hideForTrash(item) }
      itemAction = request
    }
  }

  private struct Request: Equatable {
    let query: String
    let revision: UInt64
  }

  private struct PageRequest: Equatable {
    let cursor: String
    let generation: UInt64
    let isSearching: Bool
    let epoch: UInt64
  }
}
