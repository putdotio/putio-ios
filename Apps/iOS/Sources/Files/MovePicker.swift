import Foundation
import PutioCore
import SwiftUI

enum PutioMoveSheetResult: Equatable {
  case closed
  case nameTaken(String)
}

enum PutioMoveLevelStatus: Equatable {
  case loading
  case ready
  case busy
}

extension PutioFileActionOutcome {
  func isNameTaken(movingFileID id: PutioFileID) -> Bool {
    guard case .failed(.move(let fileID, _, _, _, _), let failure) = self else { return false }
    return fileID == id && failure.isNameTaken
  }
}

enum PutioMoveCopy {
  static func moved(_ count: Int) -> String {
    String(localized: "\(count) items are in the selected folder.")
  }
}

enum PutioSharedFileCopyMessage {
  static func text(for result: PutioSharedFileCopyResult) -> String {
    let name = result.name
    let folder = result.destination.title
    return switch result.outcome {
    case .copied: String(localized: "Copied “\(name)” to \(folder).")
    case .failed: String(localized: "Couldn’t copy “\(name)” to \(folder).")
    case .unconfirmed:
      String(
        localized: "Couldn’t confirm the copy of “\(name)”. It may still show up in \(folder).")
    case .concurrentLimit:
      String(
        localized:
          "You’re already copying as much as put.io allows at once. Try again when that copy finishes."
      )
    case .tooManyFiles: String(localized: "That’s too many files to copy at once.")
    }
  }
}

enum PutioFolderPickerPurpose: Equatable {
  case move
  case copy
}

@MainActor
struct PutioMovePicker: View {
  var purpose = PutioFolderPickerPurpose.move
  let items: [PutioFileItem]
  let load: PutioFolderLoad
  let continueLoad: PutioFolderContinue?
  let actions: PutioFileActions?
  let refreshRequests: PutioFolderRefreshRequests
  let onMove: @MainActor (PutioFolderRoute) async -> PutioMoveSheetResult

  @Environment(\.dismiss) private var dismiss
  @State private var path: [PutioFolderRoute] = []
  @State private var levelStatus: [PutioFileID: PutioMoveLevelStatus] = [:]
  @State private var takenName: String?
  @State private var isMoving = false

  var body: some View {
    PutioSheetScaffold(
      title: title,
      primaryButton: PutioSheetPrimaryButton(
        primaryTitle,
        isBusy: isMoving || levelStatus.values.contains(.busy),
        isEnabled: canMove,
        failure: failure,
        action: move
      ),
      path: navigationPath
    ) {
      level(.root, trail: [])
        .navigationDestination(for: PutioFolderRoute.self) { route in
          level(route, trail: trail(to: route))
            .navigationTitle(route.title)
        }
    }
    .onChange(of: path) { takenName = nil }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("files.move-picker")
  }

  private var title: String {
    switch purpose {
    case .move: String(localized: "Move \(items.count) items")
    case .copy: String(localized: "Copy \(items.count) items")
    }
  }

  private var primaryTitle: String {
    switch purpose {
    case .move: String(localized: "Move to \(destination.title)")
    case .copy: String(localized: "Copy to \(destination.title)")
    }
  }

  private func level(_ route: PutioFolderRoute, trail: [PutioFolderRoute]) -> some View {
    PutioMoveLevel(
      route: route,
      trail: [.root] + trail,
      load: load,
      continueLoad: continueLoad,
      actions: actions,
      refreshRequests: refreshRequests,
      isMoving: isMoving,
      onOpen: { next in
        levelStatus[next.id] = nil
        path.append(next)
      },
      onStatusChange: { levelStatus[route.id] = $0 }
    )
  }

  private var navigationPath: Binding<NavigationPath> {
    Binding(
      get: { NavigationPath(path) },
      set: { newPath in
        guard newPath.count < path.count else { return }
        for popped in path[newPath.count...] { levelStatus[popped.id] = nil }
        path.removeLast(path.count - newPath.count)
      }
    )
  }

  private func trail(to route: PutioFolderRoute) -> [PutioFolderRoute] {
    guard let index = path.firstIndex(of: route) else { return [route] }
    return Array(path[...index])
  }

  private var destination: PutioFolderRoute { path.last ?? .root }

  private var policy: PutioMovePickerPolicy { PutioMovePickerPolicy(items: items) }

  private var destinationState: PutioMoveDestinationState { policy.state(along: path) }

  private var canMove: Bool {
    destinationState == .available && levelStatus[destination.id] == .ready
  }

  private var failure: String? {
    switch destinationState {
    case .intoItself:
      return String(localized: "A folder can’t be moved into itself or a folder inside it.")
    case .currentFolder:
      return nil
    case .available:
      guard let takenName else { return nil }
      return String(
        localized:
          "A file or folder named “\(takenName)” already exists there. Choose another folder."
      )
    }
  }

  private func move() {
    let destination = destination
    takenName = nil
    isMoving = true
    Task {
      let result = await onMove(destination)
      isMoving = false
      switch result {
      case .closed:
        dismiss()
      case .nameTaken(let name):
        takenName = name
      }
    }
  }
}

@MainActor
private struct PutioMoveLevel: View {
  let route: PutioFolderRoute
  let trail: [PutioFolderRoute]
  let isMoving: Bool
  let onOpen: @MainActor (PutioFolderRoute) -> Void
  let onStatusChange: @MainActor (PutioMoveLevelStatus) -> Void

  @State private var model: PutioFolderModel
  @State private var newFolderAlert: PutioTextAlert?
  private let refreshRequests: PutioFolderRefreshRequests

  init(
    route: PutioFolderRoute,
    trail: [PutioFolderRoute],
    load: @escaping PutioFolderLoad,
    continueLoad: PutioFolderContinue?,
    actions: PutioFileActions?,
    refreshRequests: PutioFolderRefreshRequests,
    isMoving: Bool,
    onOpen: @escaping @MainActor (PutioFolderRoute) -> Void,
    onStatusChange: @escaping @MainActor (PutioMoveLevelStatus) -> Void
  ) {
    self.route = route
    self.trail = trail
    self.refreshRequests = refreshRequests
    self.isMoving = isMoving
    self.onOpen = onOpen
    self.onStatusChange = onStatusChange
    _model = State(
      initialValue: PutioFolderModel(
        folderID: route.id, load: load, continueLoad: continueLoad, actions: actions))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(trail.map(\.title).joined(separator: " / "))
        .putioFont(PutioTheme.Typography.caption)
        .foregroundStyle(PutioTheme.Colors.textSecondary)
        .lineLimit(1)
        .truncationMode(.head)
        .padding(.horizontal, PutioTheme.Spacing.space3)
        .padding(.vertical, PutioTheme.Spacing.space2)
        .accessibilityIdentifier("files.move-path")
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("files.move-screen.\(route.id.rawValue)")
    .scrollContentBackground(.hidden)
    .background(PutioTheme.Components.Sheet.background)
    .navigationBarTitleDisplayMode(.inline)
    .navigationBarBackButtonHidden(isMoving || model.activeAction != nil)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          newFolderAlert = makeNewFolderAlert()
        } label: {
          Label {
            Text("New folder")
          } icon: {
            Image(putioIcon: .folderSimplePlus)
          }
        }
        .labelStyle(.iconOnly)
        .tint(PutioTheme.Colors.textPrimary)
        .disabled(!model.supportsActions || !model.canStartAction || !model.isLoaded || isMoving)
        .accessibilityIdentifier("files.move-new-folder")
      }
    }
    .putioTextAlert($newFolderAlert)
    .task(id: route.id) {
      await model.loadIfNeeded()
    }
    .onChange(of: status, initial: true) { _, status in
      onStatusChange(status)
    }
  }

  private var status: PutioMoveLevelStatus {
    if model.activeAction != nil { return .busy }
    return model.isLoaded ? .ready : .loading
  }

  @ViewBuilder
  private var content: some View {
    switch model.state {
    case .loading:
      PutioLoadingStateView(title: String(localized: "Loading folders…"))
    case .failed(let failure):
      PutioErrorStateView(
        title: failure.title,
        message: failure.message,
        retryTitle: String(localized: "Try again")
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
        folderList(contents)
      }
    }
  }

  @ViewBuilder
  private func folderList(_ contents: PutioFolderContents) -> some View {
    let folders = PutioMovePickerPolicy.folders(in: contents)
    if folders.isEmpty, !contents.hasMore {
      Text("No folders here.")
        .putioFont(PutioTheme.Typography.body)
        .foregroundStyle(PutioTheme.Colors.textSecondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("files.move-empty.\(route.id.rawValue)")
    } else {
      List {
        ForEach(folders) { folder in
          Button {
            onOpen(PutioFolderRoute(id: folder.id, title: folder.name))
          } label: {
            HStack(spacing: PutioTheme.Spacing.space2) {
              PutioFileRow(PutioBrowserItemPresentation(item: folder).row)
              Image(putioIcon: .caretRight)
                .resizable()
                .scaledToFit()
                .frame(width: PutioTheme.Spacing.space3, height: PutioTheme.Spacing.space3)
                .foregroundStyle(PutioTheme.Colors.textSecondary)
                .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .disabled(model.activeAction != nil || isMoving)
          .accessibilityIdentifier("files.move-folder.\(folder.id.rawValue)")
          .listSectionSeparator(.hidden, edges: .top)
          .listRowBackground(Color.clear)
        }
        if contents.hasMore {
          loadMoreRow
            .listRowBackground(Color.clear)
        }
      }
      .listStyle(.plain)
    }
  }

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

  private func makeNewFolderAlert() -> PutioTextAlert {
    let model = model
    let refreshRequests = refreshRequests
    let folderID = route.id
    return PutioTextAlert(
      title: String(localized: "New folder"),
      message: String(localized: "In \(route.title)"),
      initialText: "",
      submitTitle: String(localized: "Create"),
      failureText: String(localized: "Couldn’t create folder.")
    ) { name in
      await model.createFolder(name: name)
      guard let outcome = model.actionOutcome, case .createFolder = outcome.action else {
        throw PutioMoveFolderCreationFailure()
      }
      model.clearActionOutcome()
      refreshRequests.request(folderID: folderID)
      if case .failed = outcome { throw PutioMoveFolderCreationFailure() }
    }
  }
}

private struct PutioMoveFolderCreationFailure: Error {}
