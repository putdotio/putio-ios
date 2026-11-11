import SwiftUI

// The component-kit showcase behind the harness `gallery` scenario. Snapshot
// tests render each page; capture runs cycle through all of them.
public struct PutioComponentGallery: View {
  public enum Page: String, CaseIterable, Sendable {
    case buttons
    case files
    case transfers
    case states
    case feedback
    case forms
    case sheets
    #if os(iOS)
      case shell
      case menus
      case textAlert = "text-alert"
      case confirmAlert = "confirm-alert"
      case selectionNone = "selection-none"
      case selectionSome = "selection-some"
      case selectionAll = "selection-all"
      case split
    #endif

    public static let launchArgument = "--putio-harness-gallery-page"

    public static func requested(in arguments: [String]) -> Page? {
      guard let flag = arguments.firstIndex(of: launchArgument),
        arguments.indices.contains(flag + 1)
      else { return nil }
      return Page(rawValue: arguments[flag + 1])
    }

    public var title: String {
      switch self {
      case .buttons: "Buttons"
      case .files: "File rows"
      case .transfers: "Transfers"
      case .states: "Screen states"
      case .feedback: "Feedback"
      case .forms: "Forms"
      case .sheets: "Sheets"
      #if os(iOS)
        case .shell: "Shell"
        case .menus: "Menus and swipe actions"
        case .textAlert: "Text alert"
        case .confirmAlert: "Confirm alert"
        case .selectionNone, .selectionSome, .selectionAll: "Selection"
        case .split: "List and detail"
      #endif
      }
    }

    // List- and Form-backed pages have no intrinsic height, so snapshots
    // render them at a fixed viewport instead of the fitted size.
    var viewportHeight: CGFloat? {
      switch self {
      case .files: GalleryLayout.filesViewportHeight
      case .forms: GalleryLayout.formsViewportHeight
      case .buttons, .transfers, .states, .feedback, .sheets: nil
      #if os(iOS)
        case .shell: nil
        case .menus, .textAlert, .confirmAlert: GalleryLayout.actionsViewportHeight
        case .selectionNone, .selectionSome, .selectionAll: GalleryLayout.filesViewportHeight
        case .split: GalleryLayout.containerViewportHeight
      #endif
      }
    }

    #if os(iOS)
      var initialSelection: SelectionGallery.Initial? {
        switch self {
        case .selectionNone: SelectionGallery.Initial.none
        case .selectionSome: .some
        case .selectionAll: .all
        default: nil
        }
      }
    #endif
  }

  private let page: Page
  private let autoAdvanceInterval: TimeInterval?

  public init(autoAdvanceEvery interval: TimeInterval) {
    self.page = .buttons
    self.autoAdvanceInterval = interval
  }

  public init(page: Page) {
    self.page = page
    self.autoAdvanceInterval = nil
  }

  public var body: some View {
    if let autoAdvanceInterval {
      AutoAdvancingGallery(interval: autoAdvanceInterval, initialPage: page)
    } else {
      GalleryPageView(page: page, presentsOnAppear: true)
    }
  }

  public static func snapshotContent(page: Page) -> some View {
    GalleryPageView(page: page)
      .frame(maxHeight: page.viewportHeight)
  }

  public static func snapshotViewportHeight(page: Page) -> CGFloat? {
    page.viewportHeight
  }
}

private struct AutoAdvancingGallery: View {
  let interval: TimeInterval
  @State private var page: PutioComponentGallery.Page

  init(interval: TimeInterval, initialPage: PutioComponentGallery.Page) {
    self.interval = interval
    _page = State(initialValue: initialPage)
  }

  var body: some View {
    GalleryPageView(page: page)
      .task {
        let pages = PutioComponentGallery.Page.allCases
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(interval))
          guard !Task.isCancelled else { return }
          let index = pages.firstIndex(of: page) ?? pages.startIndex
          page = pages[(index + 1) % pages.count]
        }
      }
  }
}

struct GalleryPageView: View {
  let page: PutioComponentGallery.Page
  var presentsOnAppear = false

  var body: some View {
    Group {
      switch page {
      case .files:
        FilesGallery()
      case .forms:
        FormsGallery()
      #if os(iOS)
        case .shell:
          ScrollView {
            VStack(alignment: .leading, spacing: GalleryLayout.sectionGap) {
              GalleryTitle(page: page)
              ShellPage()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(GalleryLayout.pagePadding)
          }
        case .menus:
          MenusGallery()
        case .textAlert:
          TextAlertGallery(presentsOnAppear: presentsOnAppear)
        case .confirmAlert:
          ConfirmAlertGallery(presentsOnAppear: presentsOnAppear)
        case .selectionNone, .selectionSome, .selectionAll:
          SelectionGallery(initial: page.initialSelection ?? .none)
        case .split:
          ListDetailGallery()
      #endif
      case .buttons, .transfers, .states, .feedback, .sheets:
        ScrollView {
          VStack(alignment: .leading, spacing: GalleryLayout.sectionGap) {
            GalleryTitle(page: page)
            stackedContent
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(GalleryLayout.pagePadding)
        }
      }
    }
    .background(PutioTheme.Colors.background)
    .preferredColorScheme(.dark)
    // Mirrors the app roots: the brand tint is set once and stock controls
    // (Toggle, Gauge, ProgressView) pick it up from the environment.
    .tint(PutioTheme.Colors.accent)
  }

  @ViewBuilder private var stackedContent: some View {
    switch page {
    case .buttons: ButtonsPage()
    case .transfers: TransfersPage()
    case .states: StatesPage()
    case .feedback: FeedbackPage()
    case .sheets: SheetsPage()
    case .files, .forms: EmptyView()
    #if os(iOS)
      case .shell, .menus, .textAlert, .confirmAlert, .selectionNone, .selectionSome, .selectionAll,
        .split:
        EmptyView()
    #endif
    }
  }
}

private struct GalleryTitle: View {
  let page: PutioComponentGallery.Page

  var body: some View {
    Text(page.title)
      .putioFont(GalleryLayout.titleFont)
      .foregroundStyle(PutioTheme.Colors.textPrimary)
  }
}

private struct GallerySection<Content: View>: View {
  let caption: String
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: GalleryLayout.itemGap) {
      Text(caption)
        .putioFont(GalleryLayout.captionFont)
        .foregroundStyle(PutioTheme.Colors.textSecondary)
        .textCase(.uppercase)
      content
    }
  }
}

private struct ButtonsPage: View {
  var body: some View {
    GallerySection(caption: "Tiers") {
      ForEach(Array(PutioButtonTier.allCases.enumerated()), id: \.offset) { _, tier in
        PutioButton(GalleryFixtures.tierLabel(tier), tier: tier) {}
      }
    }
    GallerySection(caption: "Sizes") {
      ForEach(Array(PutioButtonSize.allCases.enumerated()), id: \.offset) { _, size in
        PutioButton(GalleryFixtures.sizeLabel(size), tier: .primary, size: size) {}
      }
    }
    GallerySection(caption: "With icon") {
      PutioButton("Retry", icon: .arrowCounterClockwise, tier: .secondary) {}
    }
    GallerySection(caption: "Disabled") {
      PutioButton("Primary", tier: .primary) {}.disabled(true)
      PutioButton("Secondary", tier: .secondary) {}.disabled(true)
    }
  }
}

#if os(iOS)
  private struct ShellPage: View {
    var body: some View {
      GallerySection(caption: "Sidebar storage meter") {
        ForEach(Array(GalleryFixtures.storageStates.enumerated()), id: \.offset) { _, entry in
          VStack(alignment: .leading, spacing: GalleryLayout.itemGap) {
            Text(entry.label)
              .putioFont(GalleryLayout.bodyFont)
              .foregroundStyle(PutioTheme.Colors.textSecondary)
            PutioStorageMeter(storage: entry.storage)
              .frame(maxWidth: GalleryLayout.sidebarWidth, alignment: .leading)
          }
        }
      }
    }
  }
#endif

#if os(iOS)
  @MainActor @Observable
  final class GalleryActionLog {
    var last = "none"
    var sent: [String] = []

    var sentText: String {
      "Sent: " + (sent.isEmpty ? "none" : sent.joined(separator: ", "))
    }
  }

  private struct GalleryActionsHeader<Controls: View>: View {
    let page: PutioComponentGallery.Page
    let reported: String
    @ViewBuilder let controls: Controls

    var body: some View {
      VStack(alignment: .leading, spacing: GalleryLayout.itemGap) {
        GalleryTitle(page: page)
        Text(verbatim: reported)
          .putioFont(GalleryLayout.captionFont)
          .foregroundStyle(PutioTheme.Colors.textSecondary)
          .accessibilityIdentifier("gallery.actions.reported")
        controls
      }
      .textCase(nil)
    }
  }

  private struct MenusGallery: View {
    @State private var log = GalleryActionLog()

    var body: some View {
      NavigationStack {
        List {
          Section {
            ForEach(Array(GalleryFixtures.actionRows.enumerated()), id: \.offset) { index, model in
              PutioFileRow(model)
                .putioItemActions(
                  GalleryFixtures.itemMenu(for: model.name, log: log),
                  leading: [GalleryFixtures.moveAction(for: model.name, log: log)],
                  trailing: GalleryFixtures.trailingSwipe(for: model.name, log: log)
                )
                .accessibilityIdentifier("gallery.menus.row.\(index)")
            }
          } header: {
            GalleryActionsHeader(page: .menus, reported: "Last action: \(log.last)") {
              EmptyView()
            }
          }
          .listRowBackground(PutioTheme.Colors.background)
        }
        .listStyle(.plain)
        .putioContentBackground()
        .toolbar {
          ToolbarItem(placement: .topBarTrailing) {
            Menu {
              PutioItemMenuContent(GalleryFixtures.browseMenu(log: log))
            } label: {
              Label {
                Text(verbatim: "More")
              } icon: {
                Image(putioIcon: .dotsThree)
              }
            }
            .menuOrder(.fixed)
            .accessibilityIdentifier("gallery.menus.more")
          }
        }
      }
    }
  }

  private struct TextAlertGallery: View {
    let presentsOnAppear: Bool
    @State private var log = GalleryActionLog()
    @State private var alert: PutioTextAlert?

    var body: some View {
      NavigationStack {
        List {
          Section {
            ForEach(Array(GalleryFixtures.actionRows.enumerated()), id: \.offset) { _, model in
              PutioFileRow(model)
            }
          } header: {
            GalleryActionsHeader(page: .textAlert, reported: log.sentText) {
              Button {
                alert = GalleryFixtures.renameAlert(log: log)
              } label: {
                Text(verbatim: "Rename")
              }
              .buttonStyle(.bordered)
              .accessibilityIdentifier("gallery.text-alert.open")
            }
          }
          .listRowBackground(PutioTheme.Colors.background)
        }
        .listStyle(.plain)
        .putioContentBackground()
      }
      .putioTextAlert($alert)
      .onAppear {
        if presentsOnAppear {
          alert = GalleryFixtures.renameAlert(log: log)
        }
      }
    }
  }

  private struct ListDetailGallery: View {
    @State private var selection: String?

    var body: some View {
      PutioListDetail(
        selection: $selection,
        emptyTitle: "No file selected",
        emptyMessage: "Tap a file to see it here."
      ) { selection in
        List(selection: selection) {
          Section {
            ForEach(Array(GalleryFixtures.listDetailRows.enumerated()), id: \.offset) {
              index, model in
              PutioFileRow(model)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("gallery.split.row.\(index)")
                .putioListDetailRow(model.name)
            }
          } header: {
            HStack {
              Text(verbatim: "6 items")
              Spacer()
              Text(verbatim: "13.1 GB")
                .putioFont(PutioTheme.Typography.numeric)
            }
            .putioFont(GalleryLayout.captionFont)
            .foregroundStyle(PutioTheme.Colors.textSecondary)
            .textCase(nil)
          }
        }
        .listStyle(.plain)
        .putioContentBackground()
        .navigationTitle(Text(verbatim: "Blue Lights"))
        .navigationBarTitleDisplayMode(.inline)
      } detail: { name in
        GalleryPlaceholderDetail(name: name)
      }
    }
  }

  private struct ConfirmAlertGallery: View {
    let presentsOnAppear: Bool
    @State private var log = GalleryActionLog()
    @State private var alert: PutioConfirmAlert?

    var body: some View {
      NavigationStack {
        List {
          Section {
            ForEach(Array(GalleryFixtures.actionRows.enumerated()), id: \.offset) { _, model in
              PutioFileRow(model)
            }
          } header: {
            GalleryActionsHeader(page: .confirmAlert, reported: "Last action: \(log.last)") {
              HStack(spacing: GalleryLayout.itemGap) {
                Button {
                  alert = GalleryFixtures.deletePermanentlyAlert(log: log)
                } label: {
                  Text(verbatim: "Delete permanently")
                }
                Button {
                  alert = GalleryFixtures.clearHistoryAlert(log: log)
                } label: {
                  Text(verbatim: "Clear history")
                }
              }
              .buttonStyle(.bordered)
            }
          }
          .listRowBackground(PutioTheme.Colors.background)
        }
        .listStyle(.plain)
        .putioContentBackground()
      }
      .putioConfirmAlert($alert)
      .onAppear {
        if presentsOnAppear {
          alert = GalleryFixtures.deletePermanentlyAlert(log: log)
        }
      }
    }
  }

  struct SelectionGallery: View {
    enum Initial {
      case none
      case some
      case all
    }

    private enum GalleryTab: Hashable {
      case files
      case downloads
    }

    @State private var tab = GalleryTab.files
    @State private var selection: PutioSelection<Int>

    init(initial: Initial) {
      let ids = GalleryFixtures.selectionRows.indices
      let selected: Set<Int> =
        switch initial {
        case .none: []
        case .some: GalleryFixtures.selectionSomeSelected
        case .all: Set(ids)
        }
      _selection = State(initialValue: PutioSelection(isActive: true, selectedIDs: selected))
    }

    var body: some View {
      TabView(selection: $tab) {
        Tab(value: GalleryTab.files) {
          NavigationSplitView {
            SelectionGalleryList(selection: $selection)
          } detail: {
            PutioEmptyStateView(title: "No file selected", message: "Tap a file to see it here.")
              .putioContentBackground()
          }
        } label: {
          Label {
            Text(verbatim: "Files")
          } icon: {
            Image(putioIcon: .folderFill)
          }
        }
        Tab(value: GalleryTab.downloads) {
          PutioEmptyStateView(title: "No downloads")
            .putioContentBackground()
        } label: {
          Label {
            Text(verbatim: "Downloads")
          } icon: {
            Image(putioIcon: .arrowCircleDown)
          }
        }
      }
      .tabViewStyle(.sidebarAdaptable)
    }
  }

  private struct SelectionGalleryList: View {
    @Binding var selection: PutioSelection<Int>
    @State private var reportedAction = "none"

    private var ids: [Int] { Array(GalleryFixtures.selectionRows.indices) }

    var body: some View {
      List {
        Section {
          ForEach(Array(GalleryFixtures.selectionRows.enumerated()), id: \.offset) { index, model in
            row(index: index, model: model)
              .accessibilityIdentifier("gallery.selection.row.\(index)")
          }
        } header: {
          Text(verbatim: "Last action: \(reportedAction)")
            .putioFont(GalleryLayout.captionFont)
            .foregroundStyle(PutioTheme.Colors.textSecondary)
            .textCase(nil)
            .accessibilityIdentifier("gallery.selection.reported-action")
        }
      }
      .listStyle(.plain)
      .putioContentBackground()
      .refreshable {}
      .navigationTitle(selection.isActive ? "" : PutioComponentGallery.Page.selectionSome.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        if !selection.isActive {
          ToolbarItem(placement: .topBarTrailing) {
            Button {
              selection.begin()
            } label: {
              Text(verbatim: "Select")
            }
            .accessibilityIdentifier("gallery.selection.select")
          }
        }
      }
      .putioSelectionMode($selection, among: ids, actions: actions)
    }

    @ViewBuilder private func row(index: Int, model: PutioFileRowModel) -> some View {
      if selection.isActive {
        PutioSelectableRow(isSelected: selection.contains(index)) {
          selection.toggle(index)
        } content: {
          PutioFileRow(model)
        }
      } else {
        PutioFileRow(model)
          .listRowBackground(PutioTheme.Colors.background)
          .putioRowActions {
            Button(role: .destructive) {
              reportedAction = "swipe \(model.name)"
            } label: {
              Label {
                Text(verbatim: "Trash")
              } icon: {
                Image(putioIcon: .trash)
              }
            }
          } menu: {
            Button {
              selection.begin()
              selection.toggle(index)
            } label: {
              Text(verbatim: "Select")
            }
          }
      }
    }

    private var actions: [PutioSelectionAction] {
      GalleryFixtures.selectionActions.map { entry in
        PutioSelectionAction(
          id: entry.id, title: entry.title, icon: entry.icon, isDestructive: entry.isDestructive
        ) {
          reportedAction = "\(entry.id) \(selection.count)"
        }
      }
    }
  }

  private struct GalleryPlaceholderDetail: View {
    let name: String

    var body: some View {
      ScrollView {
        VStack(alignment: .leading, spacing: GalleryLayout.itemGap) {
          RoundedRectangle(cornerRadius: GalleryLayout.sheetPreviewRadius)
            .fill(PutioTheme.Colors.surface)
            .aspectRatio(GalleryLayout.posterAspectRatio, contentMode: .fit)
            .accessibilityHidden(true)
          Text(name)
            .putioFont(GalleryLayout.titleFont)
            .foregroundStyle(PutioTheme.Colors.textPrimary)
            .accessibilityIdentifier("gallery.split.detail-title")
          PutioButton("Resume from 18:42", icon: .playFill, tier: .primary) {}
          Grid(
            alignment: .leading,
            horizontalSpacing: GalleryLayout.itemGap,
            verticalSpacing: GalleryLayout.detailRowGap
          ) {
            ForEach(Array(GalleryFixtures.listDetailFacts.enumerated()), id: \.offset) {
              _, entry in
              GridRow {
                Text(entry.label)
                  .foregroundStyle(PutioTheme.Colors.textSecondary)
                Text(entry.value)
                  .foregroundStyle(PutioTheme.Colors.textPrimary)
              }
            }
          }
          .putioFont(GalleryLayout.bodyFont)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(GalleryLayout.pagePadding)
      }
      .putioContentBackground()
      .navigationBarTitleDisplayMode(.inline)
    }
  }
#endif

private struct FilesGallery: View {
  #if !os(tvOS)
    @State private var reportedAction = "none"
  #endif

  var body: some View {
    #if os(tvOS)
      ScrollView {
        VStack(alignment: .leading, spacing: GalleryLayout.sectionGap) {
          GalleryTitle(page: .files)
          GallerySection(caption: "File rows") {
            VStack(spacing: 0) {
              ForEach(Array(GalleryFixtures.fileRows.enumerated()), id: \.offset) { _, model in
                PutioFileRow(model)
              }
            }
          }
          GallerySection(caption: "As button") {
            // A row is content, not an action: the stock card style lifts it
            // on focus instead of painting an accent fill behind fixed brand
            // colors, which is what the TV contract means by native focus.
            Button {
            } label: {
              PutioFileRow(GalleryFixtures.folderRow)
            }
            .buttonStyle(.card)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(GalleryLayout.pagePadding)
      }
    #else
      NavigationStack {
        List {
          Section {
            ForEach(Array(GalleryFixtures.fileRows.enumerated()), id: \.offset) { _, model in
              PutioFileRow(model)
            }
          } header: {
            VStack(alignment: .leading, spacing: GalleryLayout.itemGap) {
              GalleryTitle(page: .files)
              Text(verbatim: "Last action: \(reportedAction)")
                .putioFont(GalleryLayout.captionFont)
                .foregroundStyle(PutioTheme.Colors.textSecondary)
                .textCase(nil)
                .accessibilityIdentifier("gallery.files.reported-action")
            }
          }
          .listRowBackground(PutioTheme.Colors.background)
          Section("Download states") {
            ForEach(Array(GalleryFixtures.downloadRows.enumerated()), id: \.offset) { _, model in
              PutioFileRow(model) { action in
                reportedAction = "\(GalleryFixtures.actionName(action)) \(model.name)"
              }
            }
          }
          .listRowBackground(PutioTheme.Colors.background)
          Section("Native navigation") {
            NavigationLink {
              PutioEmptyStateView(title: "Folder is empty")
                .putioContentBackground()
            } label: {
              PutioFileRow(GalleryFixtures.folderRow)
            }
          }
          .listRowBackground(PutioTheme.Colors.background)
        }
        .listStyle(.plain)
        .putioContentBackground()
      }
    #endif
  }
}

private struct TransfersPage: View {
  var body: some View {
    GallerySection(caption: "Row progress") {
      ProgressView(value: 0.6)
        .tint(PutioTheme.Colors.accent)
    }
  }
}

private struct StatesPage: View {
  var body: some View {
    #if os(tvOS)
      TVStatesPage()
    #else
      GallerySection(caption: "Loading") {
        PutioLoadingStateView.files
          .frame(height: GalleryLayout.stateTileHeight)
      }
      GallerySection(caption: "Next page loading") {
        VStack(spacing: 0) {
          GalleryLoadedRows()
          PutioNextPageLoadingFooter()
        }
      }
      GallerySection(caption: "Next page failed") {
        VStack(spacing: 0) {
          GalleryLoadedRows()
          PutioNextPageFailedFooter.files {}
        }
      }
      GallerySection(caption: "Empty folder") {
        PutioEmptyStateView.folder {}
          .frame(height: GalleryLayout.stateTileHeight)
      }
      GallerySection(caption: "Empty history") {
        PutioEmptyStateView.history
          .frame(height: GalleryLayout.stateTileHeight)
      }
      GallerySection(caption: "Error") {
        PutioErrorStateView(kind: .failed) {}
          .frame(height: GalleryLayout.stateTileHeight)
      }
      GallerySection(caption: "Offline") {
        VStack(spacing: GalleryLayout.itemGap) {
          PutioOfflineBanner()
          PutioFileRow(GalleryFixtures.onDeviceRow)
          PutioErrorStateView(kind: .offline) {}
            .frame(height: GalleryLayout.stateTileHeight)
        }
      }
    #endif
  }
}

#if !os(tvOS)
  private struct GalleryLoadedRows: View {
    var body: some View {
      ForEach(GalleryFixtures.loadedRows, id: \.name) { model in
        PutioFileRow(model)
      }
    }
  }
#endif

#if os(tvOS)
  private struct TVStatesPage: View {
    var body: some View {
      GallerySection(caption: "Loading") {
        PutioLoadingStateView(title: "Loading your files")
          .frame(height: GalleryLayout.stateTileHeight)
      }
      GallerySection(caption: "Empty") {
        PutioEmptyStateView(
          icon: .folderFill,
          title: "No files yet",
          message: "Files you fetch appear here.",
          actionTitle: "Refresh",
          action: {}
        )
        .frame(height: GalleryLayout.stateTileHeight)
      }
      GallerySection(caption: "Error") {
        PutioErrorStateView(
          title: "Could not load files",
          message: "The request timed out.",
          retryTitle: "Retry",
          retry: {}
        )
        .frame(height: GalleryLayout.stateTileHeight)
      }
    }
  }
#endif

private struct FeedbackPage: View {
  var body: some View {
    GallerySection(caption: "Toasts") {
      ForEach(Array(GalleryFixtures.toasts.enumerated()), id: \.offset) { _, toast in
        PutioToastView(toast)
      }
    }
    GallerySection(caption: "Toasts at XX Large") {
      ForEach(Array(GalleryFixtures.largeTextToasts.enumerated()), id: \.offset) { _, toast in
        PutioToastView(toast)
      }
      .dynamicTypeSize(.xxLarge)
    }
  }
}

private struct SheetsPage: View {
  var body: some View {
    GallerySection(caption: "Primary button") {
      GallerySheetFrame { GalleryMoveSheet(isBusy: false) }
    }
    GallerySection(caption: "Primary button busy") {
      GallerySheetFrame { GalleryMoveSheet(isBusy: true) }
    }
    GallerySection(caption: "No primary button") {
      GallerySheetFrame { GalleryDetailSheet() }
    }
  }
}

private struct GallerySheetFrame<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    content
      .frame(maxWidth: GalleryLayout.sheetPreviewMaxWidth)
      .frame(height: GalleryLayout.sheetPreviewHeight)
      .background(PutioTheme.Components.Sheet.background)
      .clipShape(.rect(cornerRadius: GalleryLayout.sheetPreviewRadius))
      .frame(maxWidth: .infinity)
  }
}

private struct GalleryMoveSheet: View {
  let isBusy: Bool

  var body: some View {
    PutioSheetScaffold(
      title: "Move 1 item",
      trailingButton: PutioSheetIconButton(icon: .folderFill, label: "New folder") {},
      primaryButton: PutioSheetPrimaryButton("Move to Files", isBusy: isBusy) {}
    ) {
      #if os(tvOS)
        VStack(spacing: 0) {
          ForEach(Array(GalleryFixtures.sheetFolders.enumerated()), id: \.offset) { _, model in
            PutioFileRow(model)
          }
        }
      #else
        List {
          Section("Files") {
            ForEach(Array(GalleryFixtures.sheetFolders.enumerated()), id: \.offset) { _, model in
              PutioFileRow(model)
            }
          }
          .listRowBackground(PutioTheme.Components.Sheet.background)
        }
        .listStyle(.plain)
      #endif
    }
  }
}

private struct GalleryDetailSheet: View {
  var body: some View {
    PutioSheetScaffold(
      title: "Blue.Lights.S04E01.108…ORGANiC.mkv",
      dismissButton: nil
    ) {
      Grid(
        alignment: .leading,
        horizontalSpacing: GalleryLayout.itemGap,
        verticalSpacing: GalleryLayout.detailRowGap
      ) {
        ForEach(Array(GalleryFixtures.sheetDetails.enumerated()), id: \.offset) { _, entry in
          GridRow {
            Text(entry.label)
              .foregroundStyle(PutioTheme.Colors.textSecondary)
            Text(entry.value)
              .foregroundStyle(PutioTheme.Colors.textPrimary)
          }
        }
      }
      .putioFont(GalleryLayout.bodyFont)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(GalleryLayout.pagePadding)
    }
  }
}

private struct FormsGallery: View {
  // periphery:ignore - read only through `$` bindings, as are the three below
  @State private var name = "incoming"
  // periphery:ignore
  @State private var invalid = ""
  #if os(tvOS)
    // periphery:ignore
    @State private var usesTrash = true
    // periphery:ignore
    @State private var route = "Frankfurt"
  #endif

  var body: some View {
    #if os(tvOS)
      ScrollView {
        VStack(alignment: .leading, spacing: GalleryLayout.sectionGap) {
          GalleryTitle(page: .forms)
          formRows
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(GalleryLayout.pagePadding)
      }
    #else
      SettingsRowsGallery(name: $name, invalid: $invalid)
    #endif
  }

  #if os(tvOS)
    @ViewBuilder private var formRows: some View {
      GallerySection(caption: "Field") {
        PutioFormField(label: "Folder name", placeholder: "Folder name", text: $name)
        PutioFormField(
          label: "Receiver app ID",
          placeholder: "Required",
          text: $invalid,
          errorText: "Enter a receiver app ID."
        )
      }
      GallerySection(caption: "Toggle row") {
        PutioToggleRow(
          title: "Use trash",
          subtitle: "Deleted files stay in trash for a week",
          isOn: $usesTrash
        )
      }
      GallerySection(caption: "Picker row") {
        PutioPickerRow(
          title: "Tunnel route",
          selection: $route,
          options: GalleryFixtures.routes
        ) { $0 }
      }
    }
  #endif
}

#if !os(tvOS)
  private struct SettingsRowsGallery: View {
    @Binding var name: String
    @Binding var invalid: String
    @State private var sortOrder = GalleryFixtures.sortOrders[0]
    @State private var movesToTrash = true
    @State private var playbackMethod = GalleryFixtures.playbackMethods[0]

    var body: some View {
      NavigationStack {
        Form {
          Section {
            PutioFormField(label: "Folder name", placeholder: "Folder name", text: $name)
            PutioFormField(
              label: "Receiver app ID",
              placeholder: "Required",
              text: $invalid,
              errorText: "Enter a receiver app ID."
            )
          } header: {
            GalleryTitle(page: .forms)
              .textCase(nil)
          }
          PutioSettingsSection("Library") {
            PutioNavigationRow(
              "Trash", icon: .trash, value: "10.4 GB", valueStyle: .measurement
            ) {
              GalleryDestination()
            }
            PutioActionRow("Reset all sort settings", icon: .arrowCounterClockwise) {}
          }
          PutioSettingsSection("Files") {
            PutioPickerRow(
              "Default sort order",
              selection: sortOrder,
              options: GalleryFixtures.sortOrders,
              save: { sortOrder = $0 }
            ) { $0 }
            PutioToggleRow("Move deleted files to trash", isOn: movesToTrash) {
              movesToTrash = $0
            }
          }
          PutioSettingsSection("Playback") {
            PutioToggleRow(
              title: "Resume where you left off",
              subtitle: nil,
              icon: nil,
              source: .saved(false, pending: true, { _ in })
            )
            PutioToggleRow("Autoplay next video", isOn: false) { _ in
              throw GalleryFixtures.SaveFailure()
            }
            if GalleryFixtures.showsHiddenRows {
              PutioToggleRow("Rotate to landscape", isOn: true) { _ in }
            }
            PutioNavigationRow("Playback method", value: playbackMethod) {
              GalleryDestination()
            }
            PutioNavigationRow("Proxy", value: "cdn77") {
              GalleryDestination()
            }
          }
          PutioSettingsSection("Choose how this app plays videos.") {
            PutioChoiceList(
              selection: playbackMethod,
              options: GalleryFixtures.playbackMethods,
              save: { playbackMethod = $0 }
            ) { method in
              PutioChoice(method, description: GalleryFixtures.playbackMethodDescription(method))
            }
          }
          PutioSettingsSection("Subtitles") {
            if GalleryFixtures.showsHiddenRows {
              PutioToggleRow("Show subtitles", isOn: true) { _ in }
            }
          }
          PutioSettingsSection {
            PutioDestructiveRow("Sign out") {}
          }
          Section {
            PutioToastView(PutioSettingSaveFailures.failureToast)
          }
          .listRowBackground(Color.clear)
          .listRowInsets(EdgeInsets())
        }
        .scrollContentBackground(.hidden)
        .putioSettingSaveFailures()
      }
    }
  }

  private struct GalleryDestination: View {
    var body: some View {
      PutioEmptyStateView(title: "Folder is empty")
        .putioContentBackground()
    }
  }
#endif

enum GalleryFixtures {
  static let fileRows = [
    PutioFileRowModel(name: "Blue Lights", kind: .folder, sizeText: "13.1 GB", dateText: "Oct 20"),
    PutioFileRowModel(
      name: "Blue.Lights.S04E01.1080p.HDTV.H264-ORGANiC.mkv",
      kind: .video,
      sizeText: "3.2 GB",
      dateText: "Oct 13",
      isOnDevice: true,
      isWatched: true
    ),
    PutioFileRowModel(
      name: "Blue.Lights.S04E02.1080p.HDTV.H264-ORGANiC.mkv",
      kind: .video,
      sizeText: "3.3 GB",
      dateText: "Oct 13",
      isWatched: true
    ),
    PutioFileRowModel(
      name: "Kind of Blue — 01 So What.flac",
      kind: .audio,
      sizeText: "48.2 MB",
      dateText: "Oct 20"
    ),
    PutioFileRowModel(name: "IMG_2041.HEIC", kind: .image, sizeText: "3.1 MB", dateText: "Oct 20"),
    PutioFileRowModel(
      name: "Blue.Lights.S04E01.en.srt", kind: .file, sizeText: "41 kB", dateText: "Oct 13"),
  ]

  private static let downloadStates: [(episode: String, state: PutioDownloadState)] = [
    ("02", .downloading(receivedBytes: 1_400_000_000, totalBytes: 3_300_000_000)),
    ("05", .converting(progress: 0.12)),
    ("03", .paused(receivedBytes: 1_400_000_000, totalBytes: 3_300_000_000)),
    ("06", .waiting(.network, receivedBytes: 1_400_000_000, totalBytes: 3_300_000_000)),
    ("04", .waiting(.storage, receivedBytes: 200_000_000, totalBytes: 3_400_000_000)),
    ("08", .waiting(.network, receivedBytes: 0, totalBytes: 3_300_000_000)),
    ("09", .waiting(.storage, receivedBytes: 0, totalBytes: 3_400_000_000)),
    ("07", .queued(position: 1)),
    ("01", .removing),
    ("10", .missing),
    ("11", .failed(reason: "Connection lost")),
  ]

  static let downloadRows: [PutioFileRowModel] = downloadStates.map { entry in
    PutioFileRowModel(
      name: "Blue.Lights.S04E\(entry.episode).1080p.HDTV.H264-ORGANiC.mkv",
      kind: .video,
      sizeText: "3.3 GB",
      dateText: "Oct 13",
      downloadState: entry.state
    )
  }

  static let folderRow = PutioFileRowModel(
    name: "Séries télé 🎬", kind: .folder, sizeText: "9.4 GB", dateText: "Yesterday")

  static func actionName(_ action: PutioDownloadAction) -> String {
    switch action {
    case .pause: "pause"
    case .resume: "resume"
    case .cancel: "cancel"
    case .retry: "retry"
    case .downloadAgain: "download-again"
    }
  }

  #if !os(tvOS)
    static let onDeviceRow = PutioFileRowModel(
      name: "Big_Buck_Bunny_1080_10s_30MB.mp4",
      kind: .video,
      sizeText: "31 MB",
      isWatched: true
    )

    static let loadedRows = [
      PutioFileRowModel(
        name: "Blue.Lights.S04E01.1080p.HDTV.H264-ORGANiC.mkv",
        kind: .video,
        sizeText: "3.2 GB"
      ),
      PutioFileRowModel(
        name: "Blue.Lights.S04E02.1080p.HDTV.H264-ORGANiC.mkv",
        kind: .video,
        sizeText: "3.3 GB",
        isWatched: true
      ),
      PutioFileRowModel(name: "Blue.Lights.S04E01.en.srt", kind: .file, sizeText: "41 kB"),
    ]
  #endif

  static let toasts = [
    PutioToast("Moved to trash", action: PutioToast.Action("Undo") {}),
    PutioToast("Restore started"),
    PutioToast("1 item is in the selected folder."),
    PutioToast("Copied to clipboard"),
  ]

  static let largeTextToasts = [
    PutioToast("Moved to trash", action: PutioToast.Action("Undo") {}),
    PutioToast("1 item is in the selected folder."),
  ]

  static let routes = ["Frankfurt", "Amsterdam", "New York"]

  static let sortOrders = ["Name, A to Z", "Name, Z to A"]

  static let playbackMethods = ["Standard", "Direct play"]

  static let showsHiddenRows = false

  struct SaveFailure: Error {}

  static func playbackMethodDescription(_ method: String) -> String {
    method == "Standard"
      ? "Works on every device. Converted videos play at up to 1080p, stereo."
      : "Plays the original file, up to 4K and surround, when this iPhone can. Converted otherwise."
  }

  static let sheetFolders = [
    PutioFileRowModel(name: "Movies", kind: .folder, sizeText: "10.2 GB · Oct 28"),
    PutioFileRowModel(name: "Series", kind: .folder, sizeText: "13.1 GB · Nov 2"),
  ]

  static let sheetDetails: [(label: String, value: String)] = [
    ("Size", "3.2 GB"),
    ("Downloaded", "Today"),
    ("Length", "49:49"),
    ("Audio", "English, Turkish"),
    ("Subtitles", "English, English SDH, Turkish"),
  ]

  #if os(iOS)
    static let actionRows = [
      PutioFileRowModel(
        name: "Blue.Lights.S04E01.1080p.HDTV.H264-ORGANiC.mkv",
        kind: .video,
        sizeText: "3.2 GB",
        dateText: "Oct 13",
        isOnDevice: true
      ),
      PutioFileRowModel(
        name: "Blue.Lights.S04E02.1080p.HDTV.H264-ORGANiC.mkv",
        kind: .video,
        sizeText: "3.3 GB",
        dateText: "Oct 13",
        isWatched: true
      ),
      PutioFileRowModel(
        name: "Blue.Lights.S04E03.1080p.HDTV.H264-ORGANiC.mkv",
        kind: .video,
        sizeText: "3.1 GB",
        dateText: "Oct 20"
      ),
      PutioFileRowModel(
        name: "Blue.Lights.S04E04.1080p.HDTV.H264-ORGANiC.mkv",
        kind: .video,
        sizeText: "3.4 GB",
        dateText: "Oct 20"
      ),
      PutioFileRowModel(
        name: "Blue.Lights.S04E01.en.srt", kind: .file, sizeText: "41 kB", dateText: "Oct 13"),
      PutioFileRowModel(
        name: "Blue.Lights.S04E02.en.srt", kind: .file, sizeText: "39 kB", dateText: "Oct 13"),
    ]

    static let listDetailRows: [PutioFileRowModel] = [
      PutioFileRowModel(
        name: "Blue.Lights.S04E01.1080p.HDTV.H264-ORGANiC.mkv", kind: .video, sizeText: "3.2 GB",
        dateText: "Oct 13", isOnDevice: true),
      PutioFileRowModel(
        name: "Blue.Lights.S04E02.1080p.HDTV.H264-ORGANiC.mkv", kind: .video, sizeText: "3.3 GB",
        dateText: "Oct 13", isWatched: true),
      PutioFileRowModel(
        name: "Blue.Lights.S04E03.1080p.HDTV.H264-ORGANiC.mkv", kind: .video, sizeText: "3.1 GB",
        dateText: "Oct 20"),
      PutioFileRowModel(
        name: "Blue.Lights.S04E04.1080p.HDTV.H264-ORGANiC.mkv", kind: .video, sizeText: "3.4 GB",
        dateText: "Oct 20"),
      PutioFileRowModel(
        name: "Blue.Lights.S04E01.en.srt", kind: .file, sizeText: "41 kB", dateText: "Oct 13"),
      PutioFileRowModel(
        name: "Blue.Lights.S04E02.en.srt", kind: .file, sizeText: "39 kB", dateText: "Oct 13"),
    ]

    private static func action(
      _ id: String,
      _ title: String,
      _ icon: PutioIcon,
      role: PutioItemAction.Role = .standard,
      on name: String,
      log: GalleryActionLog
    ) -> PutioItemAction {
      PutioItemAction(id: id, title: title, icon: icon, role: role) { [log] in
        log.last = "\(title) \(name)"
      }
    }

    static func itemMenu(for name: String, log: GalleryActionLog) -> PutioItemMenu {
      PutioItemMenu([
        [
          action("play", "Play", .play, on: name, log: log),
          action("play-direct", "Play with Direct play", .playCircle, on: name, log: log),
          action("download", "Download", .arrowCircleDown, on: name, log: log),
          action(
            "download-direct", "Download with Direct play", .downloadSimple, on: name, log: log),
          action("share", "Share", .export, on: name, log: log),
        ],
        [
          action("select", "Select", .checkCircle, on: name, log: log),
          action("pin", "Pin", .pushPin, on: name, log: log),
          action("unwatched", "Mark as unwatched", .eyeSlash, on: name, log: log),
        ],
        [
          action("rename", "Rename", .pencilSimple, on: name, log: log),
          moveAction(for: name, log: log),
          action("exclusive-link", "Exclusive link", .link, on: name, log: log),
        ],
        [trashAction(for: name, log: log)],
      ])
    }

    static func moveAction(for name: String, log: GalleryActionLog) -> PutioItemAction {
      action("move", "Move", .folderSimpleDashed, on: name, log: log)
    }

    static func trailingSwipe(for name: String, log: GalleryActionLog) -> [PutioItemAction] {
      [
        trashAction(for: name, log: log),
        action("download", "Download", .arrowCircleDown, on: name, log: log),
      ]
    }

    private static func trashAction(for name: String, log: GalleryActionLog) -> PutioItemAction {
      action("trash", "Move to trash", .trash, role: .destructive, on: name, log: log)
    }

    static func browseMenu(log: GalleryActionLog) -> PutioItemMenu {
      PutioItemMenu([
        [
          action("select", "Select", .checkCircle, on: "Files", log: log),
          action("new-folder", "New folder", .folderSimplePlus, on: "Files", log: log),
        ]
      ])
    }

    static func renameAlert(log: GalleryActionLog) -> PutioTextAlert {
      PutioTextAlert(
        title: "Rename",
        initialText: "Blue.Lights.S04E01.en.srt",
        submitTitle: "Rename",
        failureText: "Couldn’t rename."
      ) { [log] name in
        log.sent.append(name)
        throw SaveFailure()
      }
    }

    static func deletePermanentlyAlert(log: GalleryActionLog) -> PutioConfirmAlert {
      PutioConfirmAlert(
        title: "Delete 1 item permanently?",
        message: "Trash is off for this account, so this can’t be undone.",
        confirmTitle: "Delete"
      ) { [log] in
        log.last = "Delete"
      }
    }

    static func clearHistoryAlert(log: GalleryActionLog) -> PutioConfirmAlert {
      PutioConfirmAlert(
        title: "Clear history?",
        message: "This removes all activity from your put.io history.",
        confirmTitle: "Clear"
      ) { [log] in
        log.last = "Clear"
      }
    }
  #endif

  #if os(iOS)
    static let selectionRows = [
      PutioFileRowModel(name: "Movies", kind: .folder, sizeText: "10.2 GB", dateText: "Oct 28"),
      PutioFileRowModel(name: "Series", kind: .folder, sizeText: "13.1 GB", dateText: "Nov 2"),
      PutioFileRowModel(name: "Items shared with you", kind: .folder, dateText: "Sep 14"),
      PutioFileRowModel(
        name: "Big_Buck_Bunny_1080_10s_30MB.mp4",
        kind: .video,
        sizeText: "31 MB",
        dateText: "Aug 25",
        isOnDevice: true,
        isWatched: true
      ),
      PutioFileRowModel(
        name: "Sintel.2010.1080p.mkv", kind: .video, sizeText: "1.1 GB", dateText: "Sep 9",
        downloadState: .downloading(receivedBytes: 400_000_000, totalBytes: 1_100_000_000)),
      PutioFileRowModel(
        name: "FFTT Tree Rings October 23, 2026.mp3", kind: .audio, sizeText: "48 MB",
        dateText: "Oct 23"),
      PutioFileRowModel(name: "IMG_4392.HEIC", kind: .image, sizeText: "2.4 MB", dateText: "May 4"),
      PutioFileRowModel(
        name: "document-scan-march-2026.pdf", kind: .file, sizeText: "1.1 MB", dateText: "Mar 18"),
      PutioFileRowModel(
        name: "ubuntu-24.04.1-desktop-amd64.iso", kind: .file, sizeText: "6.1 GB",
        dateText: "Oct 20"),
    ]

    static let selectionSomeSelected: Set<Int> = [3, 4, 5]

    static let selectionActions:
      [(id: String, title: String, icon: PutioIcon, isDestructive: Bool)] = [
        ("move", "Move", .folderSimpleDashed, false),
        ("download", "Download", .arrowCircleDown, false),
        ("watched", "Watched", .eye, false),
        ("trash", "Trash", .trash, true),
      ]

    static let listDetailFacts: [(label: String, value: String)] = [
      ("Size", "3.2 GB"),
      ("Added", "Oct 13, 2026"),
      ("Length", "49:49"),
      ("Subtitles", "English, English SDH"),
      ("Folder", "Series / Blue Lights"),
    ]

    static let storageStates: [(label: String, storage: PutioAccountSnapshot.Storage)] = [
      ("Empty", storage(usedBytes: 0)),
      ("In use", storage(usedBytes: 30_600_000_000)),
      ("Full", storage(usedBytes: 1_100_000_000_000)),
    ]

    private static func storage(usedBytes: Int64) -> PutioAccountSnapshot.Storage {
      let totalBytes: Int64 = 1_100_000_000_000
      return PutioAccountSnapshot.Storage(
        availableBytes: totalBytes - usedBytes, totalBytes: totalBytes, usedBytes: usedBytes)
    }
  #endif

  static func tierLabel(_ tier: PutioButtonTier) -> String {
    switch tier {
    case .primary: "Primary"
    case .secondary: "Secondary"
    case .success: "Success"
    case .danger: "Danger"
    case .info: "Info"
    }
  }

  static func sizeLabel(_ size: PutioButtonSize) -> String {
    switch size {
    case .regular: "Regular"
    case .medium: "Medium"
    case .small: "Small"
    case .extraSmall: "Extra small"
    }
  }
}

enum GalleryLayout {
  #if os(tvOS)
    static let titleFont = PutioTheme.TV.Typography.heading
    static let captionFont = PutioTheme.TV.Typography.small
    static let bodyFont = PutioTheme.TV.Typography.body
    static let sectionGap = PutioTheme.TV.Spacing.medium
    static let itemGap = PutioTheme.TV.Spacing.small
    static let pagePadding = PutioTheme.TV.Spacing.large
    static let stateTileHeight = PutioTheme.TV.Spacing.xl * 3
    static let containerViewportHeight = PutioTheme.TV.Spacing.xxl * 5
    static let filesViewportHeight = PutioTheme.TV.Spacing.xxl * 8
    static let formsViewportHeight = containerViewportHeight
    static let detailRowGap = PutioTheme.TV.Spacing.xs
    static let sheetPreviewHeight = PutioTheme.TV.Spacing.xxl * 2
    static let sheetPreviewMaxWidth = PutioTheme.TV.Spacing.xxl * 4
    static let sheetPreviewRadius = PutioTheme.TV.radius
  #else
    static let titleFont = PutioTheme.Typography.heading
    static let captionFont = PutioTheme.Typography.caption
    static let bodyFont = PutioTheme.Typography.body
    static let sectionGap = PutioTheme.Spacing.space4
    static let itemGap = PutioTheme.Spacing.space3
    static let pagePadding = PutioTheme.Spacing.space3
    static let sidebarWidth = PutioTheme.Spacing.space6 * 2
    static let actionsViewportHeight = PutioTheme.Spacing.space6 * 6
    static let posterAspectRatio: CGFloat = 16 / 9
    static let stateTileHeight = PutioTheme.Spacing.space5 * 5
    static let containerViewportHeight = PutioTheme.Spacing.space6 * 7
    static let filesViewportHeight = PutioTheme.Spacing.space6 * 14
    static let formsViewportHeight = PutioTheme.Spacing.space6 * 14
    static let detailRowGap = PutioTheme.Spacing.space2
    static let sheetPreviewHeight = PutioTheme.Spacing.space6 * 3
    static let sheetPreviewMaxWidth = PutioTheme.Spacing.space8
    static let sheetPreviewRadius = PutioTheme.Radius.large
  #endif
}
