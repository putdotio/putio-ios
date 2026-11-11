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
      }
    }

    // List- and Form-backed pages have no intrinsic height, so snapshots
    // render them at a fixed viewport instead of the fitted size.
    var viewportHeight: CGFloat? {
      switch self {
      case .files: GalleryLayout.filesViewportHeight
      case .forms: GalleryLayout.formsViewportHeight
      case .buttons, .transfers, .states, .feedback: nil
      }
    }
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
      GalleryPageView(page: page)
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

  var body: some View {
    Group {
      switch page {
      case .files:
        FilesGallery()
      case .forms:
        FormsGallery()
      case .buttons, .transfers, .states, .feedback:
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
    case .files, .forms: EmptyView()
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
    GallerySection(caption: "Sheet scaffold") {
      PutioSheetScaffold(title: "Move 3 files") {
        Text("Pick a destination folder.")
          .putioFont(GalleryLayout.bodyFont)
          .foregroundStyle(PutioTheme.Colors.textSecondary)
      }
      .background(GalleryLayout.sheetPreviewBackground)
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
    PutioToast(variant: .neutral, title: "Copied link"),
    PutioToast(variant: .success, title: "Download finished", message: "So What.flac is offline."),
    PutioToast(variant: .danger, title: "Delete failed", message: "The file is already gone."),
    PutioToast(variant: .info, title: "Converting to MP4", message: "This can take a few minutes."),
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
    static let sheetPreviewBackground = Color.clear
  #else
    static let titleFont = PutioTheme.Typography.heading
    static let captionFont = PutioTheme.Typography.caption
    static let bodyFont = PutioTheme.Typography.body
    static let sectionGap = PutioTheme.Spacing.space4
    static let itemGap = PutioTheme.Spacing.space3
    static let pagePadding = PutioTheme.Spacing.space3
    static let stateTileHeight = PutioTheme.Spacing.space5 * 5
    static let containerViewportHeight = PutioTheme.Spacing.space6 * 7
    static let filesViewportHeight = PutioTheme.Spacing.space6 * 14
    static let formsViewportHeight = PutioTheme.Spacing.space6 * 14
    // The scaffold previews inside a scroll page rather than a real sheet,
    // so give it the surface a system sheet would provide.
    static let sheetPreviewBackground = PutioTheme.Colors.surface
  #endif
}
