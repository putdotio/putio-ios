import Foundation
import PutioCore
import SwiftUI

typealias PutioFileSelection = @MainActor @Sendable (PutioFileRoute) -> Void

@MainActor
struct FilesBrowserView: View {
  private let load: PutioFolderLoad
  private let onFileSelected: PutioFileSelection

  init(
    runtime: PutioRuntime,
    onFileSelected: @escaping PutioFileSelection
  ) {
    load = { folderID in
      try await runtime.listFiles(parentID: folderID)
    }
    self.onFileSelected = onFileSelected
  }

  init(
    load: @escaping PutioFolderLoad,
    onFileSelected: @escaping PutioFileSelection
  ) {
    self.load = load
    self.onFileSelected = onFileSelected
  }

  var body: some View {
    NavigationStack {
      PutioFolderScreen(
        route: .root,
        load: load,
        onFileSelected: onFileSelected
      )
      .navigationDestination(for: PutioFolderRoute.self) { route in
        PutioFolderScreen(
          route: route,
          load: load,
          onFileSelected: onFileSelected
        )
      }
    }
  }
}

@MainActor
struct PutioFolderScreen: View {
  let route: PutioFolderRoute

  @State private var model: PutioFolderModel
  private let relativeDateReference: Date?
  private let locale: Locale
  private let onFileSelected: PutioFileSelection

  init(
    route: PutioFolderRoute,
    load: @escaping PutioFolderLoad,
    initialContents: PutioFolderContents? = nil,
    relativeTo relativeDateReference: Date? = nil,
    locale: Locale = .current,
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
          Task { await model.retry() }
        }
      }
    }
    .navigationTitle(route.title)
    .putioContentBackground()
    .accessibilityIdentifier("files.screen.\(route.id.rawValue)")
    .task(id: route.id) {
      await model.loadIfNeeded()
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
      Button {
        onFileSelected(fileRoute)
      } label: {
        PutioFileRow(presentation.row)
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("files.item.\(presentation.id.rawValue)")
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
        Task { await model.refresh() }
      }
      .buttonStyle(.borderless)
    }
    .accessibilityIdentifier("files.refresh-error.\(route.id.rawValue)")
  }
}
