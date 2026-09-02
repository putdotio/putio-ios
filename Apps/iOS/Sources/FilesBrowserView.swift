import Foundation
import PutioCore
import SwiftUI

typealias PutioFileSelection = @MainActor @Sendable (PutioFileRoute) -> Void
typealias PutioRootLoaded = @MainActor @Sendable () -> Void

@MainActor
struct FilesBrowserView: View {
  private let load: PutioFolderLoad
  private let actions: PutioFileActions?
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
    actions = PutioFileActions(runtime: runtime)
    self.onFileSelected = onFileSelected
    self.onRootLoaded = onRootLoaded
    self.onReturnToRoot = onReturnToRoot
    self.refreshRequests = refreshRequests
  }

  init(
    load: @escaping PutioFolderLoad,
    actions: PutioFileActions? = nil,
    onFileSelected: @escaping PutioFileSelection,
    onRootLoaded: @escaping PutioRootLoaded = {},
    onReturnToRoot: @escaping @MainActor @Sendable () -> Void = {},
    refreshRequests: PutioFolderRefreshRequests = PutioFolderRefreshRequests()
  ) {
    self.load = load
    self.actions = actions
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
        actions: actions,
        onLoaded: onRootLoaded,
        refreshRequests: refreshRequests,
        onFileSelected: onFileSelected
      )
      .navigationDestination(for: PutioFolderRoute.self) { route in
        PutioFolderScreen(
          route: route,
          load: load,
          actions: actions,
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
  @State private var editor: FileEditor?
  @State private var editorName = ""
  @State private var pendingDeletion: PutioFileItem?
  @State private var actionRequest: FileActionRequest?
  @State private var startedActionRequest: FileActionRequest?
  @State private var toast: PutioToast?
  private let relativeDateReference: Date?
  private let locale: Locale
  private let onLoaded: @MainActor @Sendable () -> Void
  private let onFileSelected: PutioFileSelection
  private let refreshRequests: PutioFolderRefreshRequests

  init(
    route: PutioFolderRoute,
    load: @escaping PutioFolderLoad,
    actions: PutioFileActions? = nil,
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
        actions: actions,
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
    .navigationBarBackButtonHidden(fileActionPending)
    .putioContentBackground()
    .toolbar {
      if model.supportsActions {
        ToolbarItem(placement: .primaryAction) {
          Button("New Folder") {
            editorName = ""
            editor = .createFolder
          }
          .disabled(!model.canStartAction || actionRequest != nil)
          .accessibilityIdentifier("files.new-folder")
        }
      }
    }
    .sheet(isPresented: editorPresented) {
      NavigationStack {
        Form {
          TextField("Name", text: $editorName)
            .accessibilityIdentifier("files.action-name")
        }
        .navigationTitle(editorTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel", role: .cancel) {
              editor = nil
            }
          }
          ToolbarItem(placement: .confirmationAction) {
            Button(editorSubmitTitle) {
              submitEditor()
            }
            .disabled(!editorNameIsValid)
            .accessibilityIdentifier("files.action-submit")
          }
        }
      }
      .presentationDetents([.height(220)])
    }
    .confirmationDialog(
      deleteConfirmationTitle,
      isPresented: deleteConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button(deleteActionTitle, role: .destructive) {
        guard let item = pendingDeletion else { return }
        actionRequest = .delete(item)
        pendingDeletion = nil
      }
      .accessibilityIdentifier("files.delete-confirm")
      Button("Cancel", role: .cancel) {
        pendingDeletion = nil
      }
    } message: {
      Text(deleteConfirmationMessage)
    }
    .putioToast($toast)
    .accessibilityIdentifier("files.screen.\(route.id.rawValue)")
    .task(id: route.id) {
      await model.loadIfNeeded()
    }
    .task(id: retryRequest) {
      await runRetryRequest()
    }
    .task(id: actionRequest) {
      await runActionRequest()
    }
    .task(id: toast) {
      guard let presentedToast = toast else { return }
      try? await Task.sleep(for: .seconds(3))
      guard !Task.isCancelled, toast == presentedToast else { return }
      toast = nil
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
      fileActions(
        for: presentation.item,
        content: NavigationLink(value: folderRoute) {
          PutioFileRow(presentation.row, showsFolderDisclosure: false)
        }
        .disabled(fileActionPending)
        .accessibilityIdentifier("files.item.\(presentation.id.rawValue)")
      )
    } else if let fileRoute = presentation.fileRoute {
      if fileRoute.videoPlaybackRoute != nil {
        fileActions(
          for: presentation.item,
          content: Button {
            onFileSelected(fileRoute)
          } label: {
            PutioFileRow(presentation.row)
          }
          .buttonStyle(.plain)
          .disabled(fileActionPending)
          .accessibilityIdentifier("files.item.\(presentation.id.rawValue)")
          .accessibilityValue(Text(videoAccessibilityValue(for: presentation.item)))
        )
      } else {
        fileActions(
          for: presentation.item,
          content: PutioFileRow(presentation.row)
            .accessibilityIdentifier("files.item.\(presentation.id.rawValue)")
        )
      }
    }
  }

  private func fileActions<Content: View>(
    for item: PutioFileItem,
    content: Content
  ) -> some View {
    content
      .contextMenu {
        actionButtons(for: item)
      }
      .swipeActions(edge: .trailing, allowsFullSwipe: false) {
        actionButtons(for: item)
      }
  }

  @ViewBuilder
  private func actionButtons(for item: PutioFileItem) -> some View {
    if model.supportsActions {
      Button("Rename") {
        editorName = item.name
        editor = .rename(item)
      }
      .disabled(!model.canStartAction || actionRequest != nil)
      .accessibilityIdentifier("files.rename.\(item.id.rawValue)")
      Button(deleteActionTitle, role: .destructive) {
        pendingDeletion = item
      }
      .disabled(!model.canStartAction || actionRequest != nil)
      .accessibilityIdentifier("files.delete.\(item.id.rawValue)")
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

  private var editorPresented: Binding<Bool> {
    Binding(
      get: { editor != nil },
      set: { isPresented in
        if !isPresented { editor = nil }
      }
    )
  }

  private var deleteConfirmationPresented: Binding<Bool> {
    Binding(
      get: { pendingDeletion != nil },
      set: { isPresented in
        if !isPresented { pendingDeletion = nil }
      }
    )
  }

  private var editorTitle: String {
    switch editor {
    case .createFolder: "New Folder"
    case .rename: "Rename Item"
    case nil: "Edit Item"
    }
  }

  private var editorSubmitTitle: String {
    switch editor {
    case .createFolder: "Create"
    case .rename: "Rename"
    case nil: "Save"
    }
  }

  private var editorNameIsValid: Bool {
    let name = editorName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return false }
    guard case .rename(let item) = editor else { return true }
    return name != item.name
  }

  private var deleteActionTitle: String {
    "Remove"
  }

  private var deleteConfirmationTitle: String {
    guard let item = pendingDeletion else { return deleteActionTitle }
    return "\(deleteActionTitle) “\(item.name)”?"
  }

  private var deleteConfirmationMessage: String {
    "put.io will apply your current Trash setting."
  }

  private var fileActionPending: Bool {
    actionRequest != nil || model.activeAction != nil
  }

  private func submitEditor() {
    guard editorNameIsValid, let editor else { return }
    switch editor {
    case .createFolder:
      actionRequest = .createFolder(editorName)
    case .rename(let item):
      actionRequest = .rename(item, editorName)
    }
    self.editor = nil
  }

  private func runActionRequest() async {
    guard let request = actionRequest else { return }
    // `.task(id:)` re-runs when the screen reappears mid-mutation; rejoin
    // the model-owned mutation instead of starting a duplicate.
    if startedActionRequest == request {
      await model.waitForActiveAction()
    } else {
      startedActionRequest = request
      switch request {
      case .createFolder(let name):
        await model.createFolder(name: name)
      case .rename(let item, let name):
        await model.rename(item, to: name)
      case .delete(let item):
        await model.delete(item)
      }
    }
    guard actionRequest == request else { return }
    actionRequest = nil
    startedActionRequest = nil
    presentActionOutcome()
  }

  private func presentActionOutcome() {
    guard let outcome = model.actionOutcome else { return }
    switch outcome {
    case .succeeded(let action):
      toast = successToast(for: action)
    case .failed(_, let failure):
      toast = PutioToast(variant: .danger, title: failure.title, message: failure.message)
    }
    model.clearActionOutcome()
  }

  private func successToast(for action: PutioFileAction) -> PutioToast {
    switch action {
    case .createFolder(let name):
      PutioToast(variant: .success, title: "Folder created", message: name)
    case .rename(_, _, let newName):
      PutioToast(variant: .success, title: "Item renamed", message: newName)
    case .delete(_, let name):
      PutioToast(
        variant: .success,
        title: "Item removed",
        message: name
      )
    }
  }

  private enum RetryKind: Equatable {
    case load
    case refresh
  }

  private struct RetryRequest: Equatable {
    let id: UInt64
    let kind: RetryKind
  }

  private enum FileEditor: Equatable {
    case createFolder
    case rename(PutioFileItem)
  }

  private enum FileActionRequest: Equatable {
    case createFolder(String)
    case rename(PutioFileItem, String)
    case delete(PutioFileItem)
  }
}
