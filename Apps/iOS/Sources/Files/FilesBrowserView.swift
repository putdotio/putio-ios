import Foundation
import PutioCore
import SwiftUI

extension EnvironmentValues {
  /// The account's default folder sort, which folders without their own
  /// sort inherit.
  @Entry var putioDefaultFolderSort: PutioFolderSort? = nil
  @Entry var putioFileDetailSelect: PutioFileSelection? = nil
}

typealias PutioFileSelection = @MainActor @Sendable (PutioFileRoute) -> Void
typealias PutioBulkFileSelection = @MainActor @Sendable ([PutioFileRoute]) -> Void
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
  private let onBulkDownload: PutioBulkFileSelection?
  private let tracksWatched: Bool
  private let castButton: AnyView?
  private let onRootLoaded: PutioRootLoaded
  private let onReturnToRoot: @MainActor @Sendable () -> Void
  private let refreshRequests: PutioFolderRefreshRequests
  private let accountID: Int?
  private let accountNotice: PutioInactiveAccountNotice?
  private let offlineFiles: PutioOfflineFolderFiles?
  private let navigationRestoration = PutioFilesNavigationRestoration()
  private let navigationRequest: PutioFilesNavigationRequest?
  @State private var appliedNavigationRequest: UUID?
  @State private var path: [PutioFolderRoute] = []
  @State private var didRestoreNavigation = false
  private let pins: PutioPinnedFilesModel
  @State private var pinToast: PutioToast?
  private let createLink: PutioPublicLinkCreate
  private let loadVideoDetails: PutioVideoDetailsLoad
  private let loadFolderName: PutioFolderNameLoad
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @State private var isLandscape: Bool?
  @State private var selectedFile: PutioFileDetailSelection?

  init(
    runtime: PutioRuntime,
    trashEnabled: Bool,
    accountID: Int,
    pins: PutioPinnedFilesModel,
    tracksWatched: Bool = false,
    onFileSelected: @escaping PutioFileSelection,
    onExternalPlayback: PutioFileSelection? = nil,
    onDownload: PutioFileSelection? = nil,
    onBulkDownload: PutioBulkFileSelection? = nil,
    onRootLoaded: @escaping PutioRootLoaded = {},
    onReturnToRoot: @escaping @MainActor @Sendable () -> Void = {},
    refreshRequests: PutioFolderRefreshRequests = PutioFolderRefreshRequests(),
    navigationRequest: PutioFilesNavigationRequest? = nil,
    castButton: (() -> AnyView)? = nil,
    accountNotice: PutioInactiveAccountNotice? = nil,
    offlineFiles: PutioOfflineFolderFiles? = nil
  ) {
    self.tracksWatched = tracksWatched
    self.offlineFiles = offlineFiles
    self.accountNotice = accountNotice
    self.castButton = castButton?()
    load = { folderID in
      try await runtime.listFiles(parentID: folderID, perPage: PutioRuntime.folderPageSize)
    }
    continueLoad = { cursor in
      try await runtime.continueFiles(cursor: cursor)
    }
    actions = PutioFileActions(runtime: runtime)
    self.pins = pins
    createLink = { try await runtime.createPublicLink(fileID: $0) }
    loadVideoDetails = { try await runtime.videoDetails(fileID: $0) }
    loadFolderName = { try await runtime.fileName(fileID: $0) }
    self.accountID = accountID
    self.trashEnabled = trashEnabled
    self.onFileSelected = onFileSelected
    self.onExternalPlayback = onExternalPlayback
    self.onDownload = onDownload
    self.onBulkDownload = onBulkDownload
    self.onRootLoaded = onRootLoaded
    self.onReturnToRoot = onReturnToRoot
    self.refreshRequests = refreshRequests
    self.navigationRequest = navigationRequest
  }

  var body: some View {
    Group {
      if let isLandscape {
        if horizontalSizeClass == .regular, isLandscape { columns } else { stack }
      } else {
        Color.clear
      }
    }
    .onGeometryChange(for: Bool.self) { geometry in
      let insets = geometry.safeAreaInsets
      return geometry.size.width + insets.leading + insets.trailing
        > geometry.size.height + insets.top + insets.bottom
    } action: { landscape in
      isLandscape = landscape
    }
    .environment(\.putioExclusiveLink, createLink)
    .environment(
      \.putioPinnedFiles,
      PutioPinnedFilesContext(model: pins) { path.append(.pinnedList) }
    )
    .putioToast($pinToast)
    .task { await pins.load() }
    .onChange(of: pins.editFailure) { _, failure in
      guard failure != nil else { return }
      pins.clearEditFailure()
      pinToast = PutioToast(PutioScreenErrorKind.failed.message)
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

  private var columns: some View {
    PutioListDetail(
      selection: detailSelection,
      emptyTitle: String(localized: "No file selected"),
      emptyMessage: String(localized: "Tap a file to see it here.")
    ) { _ in
      stack
        .environment(\.putioFileDetailSelect, detailSelect)
    } detail: { _ in
      if let selectedFile {
        PutioFileDetailView(
          route: selectedFile.route,
          folderTitles: selectedFile.folderTitles,
          offlineStatus: offlineFiles?.status(selectedFile.route.id) ?? .remote,
          reloadKey: refreshRequests.revision,
          loadDetails: loadVideoDetails,
          loadFolderName: loadFolderName,
          onPlay: onFileSelected,
          onDownload: onDownload,
          onExternalPlayback: onExternalPlayback
        )
      }
    }
  }

  private var detailSelection: Binding<PutioFileID?> {
    let selection = $selectedFile
    return Binding(
      get: { selection.wrappedValue?.route.id },
      set: { id in
        if id == nil { selection.wrappedValue = nil }
      })
  }

  private var detailSelect: PutioFileSelection {
    let selection = $selectedFile
    let path = path
    return { route in
      selection.wrappedValue = PutioFileDetailSelection(
        route: route, folderTitles: PutioFileDetailSelection.folderTitles(of: route.item, in: path))
    }
  }

  private var stack: some View {
    NavigationStack(path: $path) {
      PutioFolderScreen(
        route: .root,
        load: load,
        continueLoad: continueLoad,
        actions: actions,
        trashEnabled: trashEnabled,
        tracksWatched: tracksWatched,
        onLoaded: onRootLoaded,
        refreshRequests: refreshRequests,
        onFileSelected: onFileSelected,
        onExternalPlayback: onExternalPlayback,
        onDownload: onDownload,
        onBulkDownload: onBulkDownload,
        castButton: castButton,
        accountNotice: accountNotice,
        offlineFiles: offlineFiles
      )
      .navigationDestination(for: PutioFolderRoute.self) { route in
        if route == .pinnedList {
          PutioPinnedListScreen(
            model: pins,
            actions: actions,
            load: load,
            continueLoad: continueLoad,
            trashEnabled: trashEnabled,
            refreshRequests: refreshRequests,
            onFileSelected: onFileSelected
          )
        } else {
          folderScreen(route)
        }
      }
    }
  }

  private func folderScreen(_ route: PutioFolderRoute) -> some View {
    PutioFolderScreen(
      route: route,
      load: load,
      continueLoad: continueLoad,
      actions: actions,
      trashEnabled: trashEnabled,
      tracksWatched: tracksWatched,
      refreshRequests: refreshRequests,
      onFileSelected: onFileSelected,
      onExternalPlayback: onExternalPlayback,
      onDownload: onDownload,
      onBulkDownload: onBulkDownload,
      castButton: castButton,
      offlineFiles: offlineFiles
    )
  }
}

struct PutioFileDetailSelection {
  let route: PutioFileRoute
  let folderTitles: [String]?

  static func folderTitles(of item: PutioFileItem, in path: [PutioFolderRoute]) -> [String]? {
    if item.parentID == .root { return [PutioFolderRoute.root.title] }
    guard let index = path.lastIndex(where: { $0.id == item.parentID }) else { return nil }
    return path[...index].filter { $0 != .pinnedList }.map(\.title)
  }
}

struct PutioFilesNavigationRequest: Equatable {
  let id = UUID()
  let path: [PutioFolderRoute]
}
