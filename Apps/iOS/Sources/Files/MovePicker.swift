import Foundation
import PutioCore
import SwiftUI

@MainActor
struct PutioMovePicker: View {
  let items: [PutioFileItem]
  let load: PutioFolderLoad
  let continueLoad: PutioFolderContinue?
  let actions: PutioFileActions?
  let refreshRequests: PutioFolderRefreshRequests
  let onMove: @MainActor (PutioFolderRoute) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var path: [PutioFolderRoute] = []

  var body: some View {
    NavigationStack(path: $path) {
      destination(.root)
        .navigationDestination(for: PutioFolderRoute.self) { route in
          destination(route)
        }
    }
    .accessibilityIdentifier("files.move-picker")
  }

  private func destination(_ route: PutioFolderRoute) -> some View {
    PutioMoveDestinationScreen(
      route: route, items: items, load: load, continueLoad: continueLoad, actions: actions,
      refreshRequests: refreshRequests, onMove: onMove
    )
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel", role: .cancel) {
          dismiss()
        }
        .accessibilityIdentifier("files.move-cancel")
      }
    }
  }
}

@MainActor
private struct PutioMoveDestinationScreen: View {
  let route: PutioFolderRoute
  let items: [PutioFileItem]
  let onMove: @MainActor (PutioFolderRoute) -> Void

  @State private var model: PutioFolderModel
  private let refreshRequests: PutioFolderRefreshRequests
  @State private var toast: PutioToast?
  @State private var newFolderName = ""
  @State private var newFolderPresented = false

  init(
    route: PutioFolderRoute,
    items: [PutioFileItem],
    load: @escaping PutioFolderLoad,
    continueLoad: PutioFolderContinue?,
    actions: PutioFileActions? = nil,
    refreshRequests: PutioFolderRefreshRequests,
    onMove: @escaping @MainActor (PutioFolderRoute) -> Void
  ) {
    self.route = route
    self.items = items
    self.onMove = onMove
    self.refreshRequests = refreshRequests
    _model = State(
      initialValue: PutioFolderModel(
        folderID: route.id, load: load, continueLoad: continueLoad, actions: actions))
  }

  var body: some View {
    Group {
      switch model.state {
      case .loading:
        PutioLoadingStateView(title: "Loading folders")
      case .failed(let failure):
        PutioErrorStateView(
          title: failure.title,
          message: failure.message,
          retryTitle: "Try again"
        ) {
          Task { await model.retry() }
        }
      case .loaded(let contents):
        VStack(spacing: PutioTheme.Spacing.space3) {
          if let failure = model.refreshFailure {
            VStack(spacing: PutioTheme.Spacing.space2) {
              Text("Could not refresh")
                .putioFont(PutioTheme.Typography.subheading)
              Text(failure.message)
                .putioFont(PutioTheme.Typography.caption)
                .foregroundStyle(PutioTheme.Colors.textSecondary)
              Button("Try again") {
                Task { await model.refresh() }
              }
            }
            .padding(PutioTheme.Spacing.space4)
          }
          destinationList(contents)
        }
      }
    }
    .accessibilityIdentifier("files.move-screen.\(route.id.rawValue)")
    .navigationTitle(route.title)
    .navigationBarTitleDisplayMode(.inline)
    .putioContentBackground()
    .toolbar {
      if model.supportsActions {
        ToolbarItem(placement: .primaryAction) {
          Menu {
            Button {
              newFolderPresented = true
            } label: {
              Label("New Folder", systemImage: "folder.badge.plus")
            }
            .disabled(!model.canStartAction)
            .accessibilityIdentifier("files.move-new-folder")
            Section {
              PutioFolderSortRows(current: model.sort, isDisabled: !model.canStartAction) {
                sort in
                Task {
                  await model.setSort(sort)
                  presentActionOutcome()
                }
              }
            }
          } label: {
            Label("More", systemImage: "ellipsis.circle")
          }
          .accessibilityIdentifier("files.move-menu")
          .accessibilityLabel(PutioFolderSortRows.menuLabel(for: model.sort))
        }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("Move") {
          onMove(route)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canMoveHere)
        .accessibilityIdentifier("files.move-here.\(route.id.rawValue)")
      }
    }
    .safeAreaInset(edge: .bottom) {
      moveSummary
    }
    .alert("New Folder", isPresented: $newFolderPresented) {
      TextField("Name", text: $newFolderName)
      Button("Create") {
        let name = newFolderName
        Task {
          await model.createFolder(name: name)
          presentActionOutcome()
        }
      }
      .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      Button("Cancel", role: .cancel) {}
    }
    .task(id: route.id) {
      await model.loadIfNeeded()
    }
    .putioToast($toast)
    .task(id: toast) {
      guard let presentedToast = toast else { return }
      try? await Task.sleep(for: .seconds(3))
      guard !Task.isCancelled, toast == presentedToast else { return }
      toast = nil
    }
    .navigationBarBackButtonHidden(model.activeAction != nil)
    .interactiveDismissDisabled(model.activeAction != nil)
  }

  private var moveSummary: some View {
    HStack(spacing: PutioTheme.Spacing.space3) {
      if let first = items.first {
        PutioIconView(
          first.kind == .folder ? .folderFill : .file,
          size: PutioTheme.ScaledMetrics.buttonIconSize
        )
        .foregroundStyle(PutioTheme.Components.FileRow.icon)
      }
      VStack(alignment: .leading, spacing: PutioTheme.Spacing.space1) {
        Text("Move")
          .putioFont(PutioTheme.Typography.caption)
          .foregroundStyle(PutioTheme.Colors.textSecondary)
        Text(items.count == 1 ? items[0].name : "\(items.count) items")
          .putioFont(PutioTheme.Typography.body)
          .foregroundStyle(PutioTheme.Colors.textPrimary)
          .lineLimit(1)
      }
      Spacer()
    }
    .padding(PutioTheme.Spacing.space4)
    .background(PutioTheme.Colors.surface, in: .rect(cornerRadius: PutioTheme.Radius.large))
    .padding(.horizontal, PutioTheme.Spacing.space4)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("files.move-summary")
  }

  @ViewBuilder
  private func destinationList(_ contents: PutioFolderContents) -> some View {
    let folders = policy.folders(in: contents)
    if folders.isEmpty, !contents.hasMore {
      PutioEmptyStateView(
        icon: .folderFill,
        title: "No folders here",
        message: canMoveHere ? emptyDestinationMessage : "Choose another folder."
      )
    } else {
      List {
        ForEach(folders) { folder in
          NavigationLink(value: PutioFolderRoute(id: folder.id, title: folder.name)) {
            PutioFileRow(
              PutioBrowserItemPresentation(item: folder).row
            )
          }
          .disabled(model.activeAction != nil)
          .accessibilityIdentifier("files.move-folder.\(folder.id.rawValue)")
          .listRowBackground(PutioTheme.Colors.background)
        }
        if contents.hasMore {
          loadMoreRow
            .listRowBackground(PutioTheme.Colors.background)
        }
      }
      .listStyle(.plain)
    }
  }

  // The picker hides files, so a page can add no rows; the row then stays
  // visible and its task chains into the next page.
  @ViewBuilder
  private var loadMoreRow: some View {
    if let failure = model.loadMoreFailure {
      VStack(alignment: .leading, spacing: PutioTheme.Spacing.space2) {
        Text("Could not load more folders")
          .putioFont(PutioTheme.Typography.subheading)
          .foregroundStyle(PutioTheme.Colors.textPrimary)
        Text(failure.message)
          .putioFont(PutioTheme.Typography.body)
          .foregroundStyle(PutioTheme.Colors.textSecondary)
        Button("Try again") {
          Task { await model.loadMore() }
        }
        .buttonStyle(.borderless)
      }
      .accessibilityIdentifier("files.move-more-error.\(route.id.rawValue)")
    } else {
      HStack {
        Spacer()
        if model.isLoadingMore {
          ProgressView()
        } else {
          Text("Loading more folders")
            .putioFont(PutioTheme.Typography.caption)
            .foregroundStyle(PutioTheme.Colors.textSecondary)
        }
        Spacer()
      }
      .accessibilityIdentifier("files.move-more.\(route.id.rawValue)")
      .task(id: model.continuationKey) {
        await model.loadMore()
      }
    }
  }

  private func presentActionOutcome() {
    guard let outcome = model.actionOutcome else { return }
    refreshRequests.request(folderID: route.id)
    switch outcome {
    case .succeeded(let action):
      if case .createFolder = action { newFolderName = "" }
    case .failed(_, let failure):
      toast = PutioToast(variant: .danger, title: failure.title, message: failure.message)
    }
    model.clearActionOutcome()
  }

  private var emptyDestinationMessage: String {
    items.count == 1
      ? "Move this item here or go back."
      : "Move the selected items here or go back."
  }

  private var canMoveHere: Bool {
    model.isLoaded && model.activeAction == nil && policy.canMove(to: route)
  }

  private var policy: PutioMovePickerPolicy {
    PutioMovePickerPolicy(items: items)
  }
}
