import Foundation
import PutioCore
import SwiftUI

extension EnvironmentValues {
  /// The account's default folder sort, which folders without their own
  /// sort inherit.
  @Entry var putioDefaultFolderSort: PutioFolderSort? = nil
  @Entry var putioFileDetailSelect: PutioFileSelection? = nil
  @Entry var putioFileDetailClear: PutioFileDetailClear? = nil
  @Entry var putioFileDetailReconcile: PutioFileDetailReconcile? = nil
}

typealias PutioFileSelection = @MainActor @Sendable (PutioFileRoute) -> Void
typealias PutioFileDetailClear = @MainActor @Sendable (Set<PutioFileID>?) -> Void
typealias PutioFileDetailReconcile = @MainActor @Sendable ([PutioFileItem]) -> Void
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
  @State private var scrollAnchors = PutioFolderScrollAnchors()
  @State private var layout = PutioFilesLayout()

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
    loadFolderName = { try await runtime.getFile(fileID: $0).name }
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
        let showsColumns = horizontalSizeClass == .regular && isLandscape
        let _ = layout.show(columns: showsColumns)
        if showsColumns {
          columns
        } else {
          stack(showsDetail: false)
        }
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
    .environment(\.putioFolderScrollAnchors, scrollAnchors)
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
      scrollAnchors.keep(only: Set(newPath.map(\.id)).union([PutioFolderRoute.root.id]))
      if horizontalSizeClass == .compact { selectedFile = nil }
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
      stack(showsDetail: true)
    } detail: { _ in
      if let selectedFile {
        detail(selectedFile, pushed: false)
      }
    }
  }

  private func detail(_ selection: PutioFileDetailSelection, pushed: Bool) -> some View {
    PutioFileDetailView(
      route: selection.route,
      folderTitles: selection.folderTitles,
      offlineStatus: offlineFiles?.status(selection.route.id) ?? .remote,
      reloadKey: refreshRequests.revision,
      loadDetails: loadVideoDetails,
      loadFolderName: loadFolderName,
      showsNavigationBar: pushed,
      onPlay: onFileSelected,
      onDownload: onDownload,
      onExternalPlayback: onExternalPlayback
    )
  }

  @ViewBuilder private var pushedDetail: some View {
    if let selectedFile {
      detail(selectedFile, pushed: true)
    }
  }

  private func stackPath(inColumns: Bool) -> Binding<[PutioFolderRoute]> {
    let folders = $path
    let selection = $selectedFile
    let layout = layout
    let pushesSelection = !inColumns && horizontalSizeClass == .compact
    return Binding(
      get: {
        folders.wrappedValue
          + (pushesSelection && selection.wrappedValue != nil ? [.openFile] : [])
      },
      set: { routes in
        guard layout.accepts(routes, from: inColumns, replacing: folders.wrappedValue) else {
          return
        }
        folders.wrappedValue = routes.filter { $0 != .openFile }
        if pushesSelection, !routes.contains(.openFile) { selection.wrappedValue = nil }
      })
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
      selection.wrappedValue = PutioFileDetailSelection(route: route, in: path)
    }
  }

  private var detailClear: PutioFileDetailClear {
    let selection = $selectedFile
    return { ids in
      guard let open = selection.wrappedValue else { return }
      if let ids, ids.isDisjoint(with: open.ancestorIDs.union([open.route.id])) { return }
      selection.wrappedValue = nil
    }
  }

  private var detailReconcile: PutioFileDetailReconcile {
    let selection = $selectedFile
    return { items in
      guard let open = selection.wrappedValue,
        let item = items.first(where: { $0.id == open.route.id }), item != open.route.item
      else { return }
      selection.wrappedValue =
        item.parentID == open.route.item.parentID
        ? PutioFileDetailSelection(
          route: PutioFileRoute(item: item), folderTitles: open.folderTitles,
          ancestorIDs: open.ancestorIDs)
        : PutioFileDetailSelection(
          route: PutioFileRoute(item: item), folderTitles: nil, ancestorIDs: [item.parentID])
    }
  }

  private func stack(showsDetail: Bool) -> some View {
    NavigationStack(path: stackPath(inColumns: showsDetail)) {
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
      .modifier(
        PutioFileDetailColumn(
          selection: showsDetail ? selectedFile : nil, select: showsDetail ? detailSelect : nil,
          clear: detailClear,
          reconcile: detailReconcile)
      )
      .navigationDestination(for: PutioFolderRoute.self) { route in
        if route == .openFile {
          pushedDetail
        } else {
          destination(route)
            .modifier(
              PutioFileDetailColumn(
                selection: showsDetail ? selectedFile : nil,
                select: showsDetail ? detailSelect : nil,
                clear: detailClear,
                reconcile: detailReconcile)
            )
        }
      }
    }
  }

  @ViewBuilder
  private func destination(_ route: PutioFolderRoute) -> some View {
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

private struct PutioFileDetailColumn: ViewModifier {
  let selection: PutioFileDetailSelection?
  let select: PutioFileSelection?
  let clear: PutioFileDetailClear
  let reconcile: PutioFileDetailReconcile

  @ViewBuilder func body(content: Content) -> some View {
    let invalidating =
      content
      .environment(\.putioFileDetailClear, clear)
      .environment(\.putioFileDetailReconcile, reconcile)
    if let select {
      invalidating
        .environment(\.horizontalSizeClass, .regular)
        .toolbar(removing: .sidebarToggle)
        .environment(\.putioFileDetailSelect, select)
        .putioListDetailOpenRow(selection?.route.id)
    } else {
      invalidating
    }
  }
}

struct PutioFileDetailSelection {
  let route: PutioFileRoute
  let folderTitles: [String]?
  let ancestorIDs: Set<PutioFileID>

  init(route: PutioFileRoute, folderTitles: [String]?, ancestorIDs: Set<PutioFileID>) {
    self.route = route
    self.folderTitles = folderTitles
    self.ancestorIDs = ancestorIDs
  }

  init(route: PutioFileRoute, in path: [PutioFolderRoute]) {
    let parentID = route.item.parentID
    let folders = path.lastIndex(where: { $0.id == parentID }).map { index in
      path[...index].filter { $0 != .pinnedList }
    }
    self.route = route
    if parentID == .root {
      folderTitles = [PutioFolderRoute.root.title]
    } else {
      folderTitles = folders?.map(\.title)
    }
    ancestorIDs = Set(folders?.map(\.id) ?? []).union([parentID])
  }
}

@MainActor
private final class PutioFilesLayout {
  private static let settleTime: TimeInterval = 0.5
  private var showsColumns = false
  private var switchedAt = Date.distantPast

  func show(columns: Bool) {
    guard columns != showsColumns else { return }
    showsColumns = columns
    switchedAt = .now
  }

  func accepts(
    _ routes: [PutioFolderRoute], from columns: Bool, replacing path: [PutioFolderRoute]
  ) -> Bool {
    guard columns == showsColumns else { return false }
    let settling = Date.now.timeIntervalSince(switchedAt) < Self.settleTime
    return !(settling && routes.isEmpty && !path.isEmpty)
  }
}

extension PutioFolderRoute {
  fileprivate static let openFile = PutioFolderRoute(id: PutioFileID(rawValue: -2), title: "")
}

struct PutioFilesNavigationRequest: Equatable {
  let id = UUID()
  let path: [PutioFolderRoute]
}
