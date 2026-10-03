import Foundation
import PutioCore
import SwiftUI

extension EnvironmentValues {
  /// The account's default folder sort, which folders without their own
  /// sort inherit.
  @Entry var putioDefaultFolderSort: PutioFolderSort? = nil
}

typealias PutioFileSelection = @MainActor @Sendable (PutioFileRoute) -> Void
typealias PutioRootLoaded = @MainActor @Sendable () -> Void

@MainActor
struct FilesBrowserView: View {
  private let load: PutioFolderLoad
  private let continueLoad: PutioFolderContinue
  private let actions: PutioFileActions?
  private let trashEnabled: Bool
  private let onFileSelected: PutioFileSelection
  private let onExternalPlayback: PutioFileSelection?
  private let onDownload: PutioFileSelection?
  private let onCast: PutioFileSelection?
  private let castButton: AnyView?
  private let onRootLoaded: PutioRootLoaded
  private let onReturnToRoot: @MainActor @Sendable () -> Void
  private let refreshRequests: PutioFolderRefreshRequests
  private let accountID: Int?
  private let navigationRestoration = PutioFilesNavigationRestoration()
  private let navigationRequest: PutioFilesNavigationRequest?
  @State private var appliedNavigationRequest: UUID?
  @State private var path: [PutioFolderRoute] = []
  @State private var didRestoreNavigation = false

  init(
    runtime: PutioRuntime,
    trashEnabled: Bool,
    accountID: Int,
    onFileSelected: @escaping PutioFileSelection,
    onExternalPlayback: PutioFileSelection? = nil,
    onDownload: PutioFileSelection? = nil,
    onCast: PutioFileSelection? = nil,
    onRootLoaded: @escaping PutioRootLoaded = {},
    onReturnToRoot: @escaping @MainActor @Sendable () -> Void = {},
    refreshRequests: PutioFolderRefreshRequests = PutioFolderRefreshRequests(),
    navigationRequest: PutioFilesNavigationRequest? = nil,
    castButton: (() -> AnyView)? = nil
  ) {
    self.onCast = onCast
    self.castButton = castButton?()
    load = { folderID in
      try await runtime.listFiles(parentID: folderID)
    }
    continueLoad = { cursor in
      try await runtime.continueFiles(cursor: cursor)
    }
    actions = PutioFileActions(runtime: runtime)
    self.accountID = accountID
    self.trashEnabled = trashEnabled
    self.onFileSelected = onFileSelected
    self.onExternalPlayback = onExternalPlayback
    self.onDownload = onDownload
    self.onRootLoaded = onRootLoaded
    self.onReturnToRoot = onReturnToRoot
    self.refreshRequests = refreshRequests
    self.navigationRequest = navigationRequest
  }

  init(
    load: @escaping PutioFolderLoad,
    continueLoad: @escaping PutioFolderContinue = { _ in throw PutioRuntimeError.unknown },
    actions: PutioFileActions? = nil,
    trashEnabled: Bool = true,
    onFileSelected: @escaping PutioFileSelection,
    onExternalPlayback: PutioFileSelection? = nil,
    onDownload: PutioFileSelection? = nil,
    onCast: PutioFileSelection? = nil,
    onRootLoaded: @escaping PutioRootLoaded = {},
    onReturnToRoot: @escaping @MainActor @Sendable () -> Void = {},
    refreshRequests: PutioFolderRefreshRequests = PutioFolderRefreshRequests(),
    navigationRequest: PutioFilesNavigationRequest? = nil
  ) {
    self.onCast = onCast
    self.castButton = nil
    self.load = load
    self.accountID = nil
    self.continueLoad = continueLoad
    self.actions = actions
    self.trashEnabled = trashEnabled
    self.onFileSelected = onFileSelected
    self.onExternalPlayback = onExternalPlayback
    self.onDownload = onDownload
    self.onRootLoaded = onRootLoaded
    self.onReturnToRoot = onReturnToRoot
    self.refreshRequests = refreshRequests
    self.navigationRequest = navigationRequest
  }

  var body: some View {
    NavigationStack(path: $path) {
      PutioFolderScreen(
        route: .root,
        load: load,
        continueLoad: continueLoad,
        actions: actions,
        trashEnabled: trashEnabled,
        onLoaded: onRootLoaded,
        refreshRequests: refreshRequests,
        onFileSelected: onFileSelected,
        onExternalPlayback: onExternalPlayback,
        onDownload: onDownload,
        onCast: onCast,
        castButton: castButton
      )
      .navigationDestination(for: PutioFolderRoute.self) { route in
        PutioFolderScreen(
          route: route,
          load: load,
          continueLoad: continueLoad,
          actions: actions,
          trashEnabled: trashEnabled,
          refreshRequests: refreshRequests,
          onFileSelected: onFileSelected,
          onExternalPlayback: onExternalPlayback,
          onDownload: onDownload,
          onCast: onCast,
          castButton: castButton
        )
      }
    }
    .onChange(of: path) { oldPath, newPath in
      if didRestoreNavigation, let accountID {
        navigationRestoration.save(path: newPath, for: accountID)
      }
      if !oldPath.isEmpty, newPath.isEmpty {
        onReturnToRoot()
      }
    }
    .disabled(!didRestoreNavigation)
    .task(id: navigationRequest?.id) {
      if let navigationRequest, appliedNavigationRequest != navigationRequest.id {
        appliedNavigationRequest = navigationRequest.id
        path = navigationRequest.path
        didRestoreNavigation = true
        if let accountID { navigationRestoration.save(path: path, for: accountID) }
        return
      }
      guard !didRestoreNavigation else { return }
      if let accountID {
        let restored = await navigationRestoration.restore(accountID: accountID, load: load)
        guard !Task.isCancelled else { return }
        path = restored
      }
      didRestoreNavigation = true
    }
  }
}

struct PutioFilesNavigationRequest: Equatable {
  let id = UUID()
  let path: [PutioFolderRoute]
}
