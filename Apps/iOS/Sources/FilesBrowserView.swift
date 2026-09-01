import Foundation
import PutioCore
import SwiftUI

typealias PutioFileSelection = @MainActor @Sendable (PutioFileRoute) -> Void
typealias PutioRootLoaded = @MainActor @Sendable () -> Void

@MainActor
struct FilesBrowserView: View {
  private let load: PutioFolderLoad
  private let onFileSelected: PutioFileSelection
  private let onRootLoaded: PutioRootLoaded
  private let onReturnToRoot: @MainActor @Sendable () -> Void
  private let refreshRequests: PutioFolderRefreshRequests
  @State private var path: [PutioFolderRoute] = []

  init(
    runtime: PutioRuntime,
    onFileSelected: @escaping PutioFileSelection,
    onRootLoaded: @escaping PutioRootLoaded = {},
    onReturnToRoot: @escaping @MainActor @Sendable () -> Void = {},
    refreshRequests: PutioFolderRefreshRequests = PutioFolderRefreshRequests()
  ) {
    load = { folderID in
      try await runtime.listFiles(parentID: folderID)
    }
    self.onFileSelected = onFileSelected
    self.onRootLoaded = onRootLoaded
    self.onReturnToRoot = onReturnToRoot
    self.refreshRequests = refreshRequests
  }

  init(
    load: @escaping PutioFolderLoad,
    onFileSelected: @escaping PutioFileSelection,
    onRootLoaded: @escaping PutioRootLoaded = {},
    onReturnToRoot: @escaping @MainActor @Sendable () -> Void = {},
    refreshRequests: PutioFolderRefreshRequests = PutioFolderRefreshRequests()
  ) {
    self.load = load
    self.onFileSelected = onFileSelected
    self.onRootLoaded = onRootLoaded
    self.onReturnToRoot = onReturnToRoot
    self.refreshRequests = refreshRequests
  }

  var body: some View {
    NavigationStack(path: $path) {
      PutioFolderScreen(
        route: .root,
        load: load,
        onLoaded: onRootLoaded,
        refreshRequests: refreshRequests,
        onFileSelected: onFileSelected
      )
      .navigationDestination(for: PutioFolderRoute.self) { route in
        PutioFolderScreen(
          route: route,
          load: load,
          refreshRequests: refreshRequests,
          onFileSelected: onFileSelected
        )
      }
    }
    .onChange(of: path) { oldPath, newPath in
      if !oldPath.isEmpty, newPath.isEmpty {
        onReturnToRoot()
      }
    }
  }
}

@MainActor
struct PutioFolderScreen: View {
  let route: PutioFolderRoute

  @State private var model: PutioFolderModel
  @State private var retryRequest: RetryRequest?
  @State private var retrySequence: UInt64 = 0
  @State private var reportedLoaded = false
  private let relativeDateReference: Date?
  private let locale: Locale
  private let onLoaded: @MainActor @Sendable () -> Void
  private let onFileSelected: PutioFileSelection
  private let refreshRequests: PutioFolderRefreshRequests

  init(
    route: PutioFolderRoute,
    load: @escaping PutioFolderLoad,
    initialContents: PutioFolderContents? = nil,
    relativeTo relativeDateReference: Date? = nil,
    locale: Locale = .current,
    onLoaded: @escaping @MainActor @Sendable () -> Void = {},
    refreshRequests: PutioFolderRefreshRequests = PutioFolderRefreshRequests(),
    onFileSelected: @escaping PutioFileSelection
  ) {
    self.route = route
    _model = State(
      initialValue: PutioFolderModel(
        folderID: route.id,
        load: load,
        initialContents: initialContents
      )
    )
    self.relativeDateReference = relativeDateReference
    self.locale = locale
    self.onLoaded = onLoaded
    self.refreshRequests = refreshRequests
    self.onFileSelected = onFileSelected
  }

  var body: some View {
    Group {
      switch model.state {
      case .loading:
        PutioLoadingStateView(title: "Loading files")
      case .loaded(let contents):
        loadedContent(contents)
      case .failed(let failure):
        PutioErrorStateView(
          title: failure.title,
          message: failure.message,
          retryTitle: "Try again"
        ) {
          requestRetry(.load)
        }
      }
    }
    .navigationTitle(route.title)
    .putioContentBackground()
    .accessibilityIdentifier("files.screen.\(route.id.rawValue)")
    .task(id: route.id) {
      await model.loadIfNeeded()
    }
    .task(id: retryRequest) {
      await runRetryRequest()
    }
    .task(id: refreshRequests.sequence(for: route.id)) {
      guard refreshRequests.sequence(for: route.id) != nil else { return }
      await model.refresh()
    }
    .onChange(of: model.state, initial: true) { _, state in
      guard !reportedLoaded, case .loaded = state else { return }
      reportedLoaded = true
      onLoaded()
    }
  }

  @ViewBuilder
  private func loadedContent(_ contents: PutioFolderContents) -> some View {
    if contents.items.isEmpty {
      ScrollView {
        VStack(spacing: PutioTheme.Spacing.space4) {
          PutioEmptyStateView(
            icon: .folderFill,
            title: "This folder is empty",
            message: "Files added here appear in this list."
          )
          if let refreshFailure = model.refreshFailure {
            refreshFailureRow(refreshFailure)
          }
        }
        .containerRelativeFrame([.horizontal, .vertical])
        .padding(PutioTheme.Spacing.space4)
      }
      .refreshable {
        await model.refresh()
      }
    } else {
      List {
        ForEach(
          contents.items.map {
            PutioBrowserItemPresentation(
              item: $0,
              relativeTo: relativeDateReference ?? .now,
              locale: locale
            )
          }
        ) { item in
          row(item)
            .listRowBackground(PutioTheme.Colors.background)
        }

        if contents.hasMore {
          Section {
          } footer: {
            Text("More files are available in this folder.")
              .putioFont(PutioTheme.Typography.caption)
              .foregroundStyle(PutioTheme.Colors.textSecondary)
              .accessibilityIdentifier("files.more.\(route.id.rawValue)")
          }
        }

        if let refreshFailure = model.refreshFailure {
          Section {
            refreshFailureRow(refreshFailure)
          }
        }
      }
      .listStyle(.plain)
      .refreshable {
        await model.refresh()
      }
    }
  }

  @ViewBuilder
  private func row(_ presentation: PutioBrowserItemPresentation) -> some View {
    if let folderRoute = presentation.folderRoute {
      NavigationLink(value: folderRoute) {
        PutioFileRow(presentation.row, showsFolderDisclosure: false)
      }
      .accessibilityIdentifier("files.item.\(presentation.id.rawValue)")
    } else if let fileRoute = presentation.fileRoute {
      if fileRoute.videoPlaybackRoute != nil {
        Button {
          onFileSelected(fileRoute)
        } label: {
          PutioFileRow(presentation.row)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("files.item.\(presentation.id.rawValue)")
        .accessibilityValue(Text(videoAccessibilityValue(for: presentation.item)))
      } else {
        PutioFileRow(presentation.row)
          .accessibilityIdentifier("files.item.\(presentation.id.rawValue)")
      }
    }
  }

  private func refreshFailureRow(_ failure: PutioBrowserErrorPresentation) -> some View {
    VStack(alignment: .leading, spacing: PutioTheme.Spacing.space2) {
      Text("Could not refresh")
        .putioFont(PutioTheme.Typography.subheading)
        .foregroundStyle(PutioTheme.Colors.textPrimary)
      Text(failure.message)
        .putioFont(PutioTheme.Typography.body)
        .foregroundStyle(PutioTheme.Colors.textSecondary)
      Button("Try again") {
        requestRetry(.refresh)
      }
      .buttonStyle(.borderless)
    }
    .accessibilityIdentifier("files.refresh-error.\(route.id.rawValue)")
  }

  private func videoAccessibilityValue(for item: PutioFileItem) -> String {
    guard item.isWatched else { return "Not watched" }
    return "Watched, resume position \(item.resumePositionSeconds) seconds"
  }

  private func requestRetry(_ kind: RetryKind) {
    retrySequence &+= 1
    retryRequest = RetryRequest(id: retrySequence, kind: kind)
  }

  private func runRetryRequest() async {
    guard let request = retryRequest else { return }
    // `.task(id:)` re-runs on every appearance, so a request that outlived
    // its screen visit must not re-fire once the model no longer needs it.
    switch request.kind {
    case .load:
      guard case .failed = model.state else {
        retryRequest = nil
        return
      }
      await model.retry()
    case .refresh:
      guard model.refreshFailure != nil else {
        retryRequest = nil
        return
      }
      await model.refresh()
    }
    guard retryRequest == request else { return }
    retryRequest = nil
  }

  private enum RetryKind: Equatable {
    case load
    case refresh
  }

  private struct RetryRequest: Equatable {
    let id: UInt64
    let kind: RetryKind
  }
}
