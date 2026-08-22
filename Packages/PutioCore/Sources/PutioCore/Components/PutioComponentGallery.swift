import SwiftUI

// The component-kit showcase behind the harness `gallery` scenario. Snapshot
// tests render each page; capture runs cycle through all of them.
public struct PutioComponentGallery: View {
  public enum Page: String, CaseIterable, Sendable {
    case buttons
    case files
    case states
    case feedback
    case forms

    public var title: String {
      switch self {
      case .buttons: "Buttons"
      case .files: "File rows"
      case .states: "Screen states"
      case .feedback: "Feedback"
      case .forms: "Forms"
      }
    }
  }

  private let page: Page
  private let autoAdvanceInterval: TimeInterval?

  public init(page: Page) {
    self.page = page
    self.autoAdvanceInterval = nil
  }

  public init(autoAdvanceEvery interval: TimeInterval) {
    self.page = .buttons
    self.autoAdvanceInterval = interval
  }

  public var body: some View {
    if let autoAdvanceInterval {
      AutoAdvancingGallery(interval: autoAdvanceInterval, initialPage: page)
    } else {
      GalleryPageView(page: page)
    }
  }

  // Snapshot tests render the unscrolled page so the full component set is
  // asserted regardless of viewport height.
  public static func snapshotContent(page: Page) -> some View {
    GalleryPageContent(page: page)
      .background(PutioTheme.Colors.background)
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

private struct GalleryPageView: View {
  let page: PutioComponentGallery.Page

  var body: some View {
    ScrollView {
      GalleryPageContent(page: page)
    }
    .background(PutioTheme.Colors.background)
    .preferredColorScheme(.dark)
  }
}

struct GalleryPageContent: View {
  let page: PutioComponentGallery.Page

  var body: some View {
    VStack(alignment: .leading, spacing: GalleryLayout.sectionGap) {
      Text(page.title)
        .putioFont(GalleryLayout.titleFont)
        .foregroundStyle(PutioTheme.Colors.textPrimary)
      pageContent
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(GalleryLayout.pagePadding)
  }

  @ViewBuilder private var pageContent: some View {
    switch page {
    case .buttons: ButtonsPage()
    case .files: FilesPage()
    case .states: StatesPage()
    case .feedback: FeedbackPage()
    case .forms: FormsPage()
    }
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
      PutioButton("Ghost", tier: .ghost) {}.disabled(true)
    }
  }
}

private struct FilesPage: View {
  var body: some View {
    GallerySection(caption: "File rows") {
      VStack(spacing: 0) {
        ForEach(Array(GalleryFixtures.fileRows.enumerated()), id: \.offset) { _, model in
          PutioFileRow(model)
        }
      }
    }
    GallerySection(caption: "As button") {
      Button {
      } label: {
        PutioFileRow(GalleryFixtures.folderRow)
      }
      .buttonStyle(PutioListRowButtonStyle())
    }
  }
}

private struct StatesPage: View {
  var body: some View {
    GallerySection(caption: "Loading") {
      PutioLoadingStateView(title: "Loading your files")
        .frame(height: GalleryLayout.stateTileHeight)
        .clipShape(GalleryLayout.tileShape)
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
      .clipShape(GalleryLayout.tileShape)
    }
    GallerySection(caption: "Error") {
      PutioErrorStateView(
        title: "Could not load files",
        message: "The request timed out.",
        retryTitle: "Retry",
        retry: {}
      )
      .frame(height: GalleryLayout.stateTileHeight)
      .clipShape(GalleryLayout.tileShape)
    }
  }
}

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
    }
  }
}

private struct FormsPage: View {
  @State private var name = "incoming"
  @State private var invalid = ""
  @State private var usesTrash = true
  @State private var route = "Frankfurt"

  var body: some View {
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
}

enum GalleryFixtures {
  static let fileRows = [
    PutioFileRowModel(name: "Incoming", kind: .folder),
    PutioFileRowModel(
      name: "The.Wire.S03E04.Back.Burners.1080p.BluRay.x264-DEMAND.mkv",
      kind: .video,
      sizeText: "4.36 GB",
      isWatched: true
    ),
    PutioFileRowModel(
      name: "Kind of Blue — 01 So What.flac",
      kind: .audio,
      sizeText: "48.2 MB"
    ),
    PutioFileRowModel(name: "IMG_2041.HEIC", kind: .image, sizeText: "3.1 MB"),
    PutioFileRowModel(name: "putio-ios-harness.notes.txt", kind: .file, sizeText: "1 KB"),
  ]

  static let folderRow = PutioFileRowModel(name: "Séries télé 🎬", kind: .folder)

  static let toasts = [
    PutioToast(variant: .neutral, title: "Copied link"),
    PutioToast(variant: .success, title: "Download finished", message: "So What.flac is offline."),
    PutioToast(variant: .danger, title: "Delete failed", message: "The file is already gone."),
    PutioToast(variant: .info, title: "Converting to MP4", message: "This can take a few minutes."),
  ]

  static let routes = ["Frankfurt", "Amsterdam", "New York"]

  static func tierLabel(_ tier: PutioButtonTier) -> String {
    switch tier {
    case .primary: "Primary"
    case .secondary: "Secondary"
    case .ghost: "Ghost"
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
    static let tileShape = RoundedRectangle(cornerRadius: PutioTheme.TV.radius)
  #else
    static let titleFont = PutioTheme.Typography.heading
    static let captionFont = PutioTheme.Typography.caption
    static let bodyFont = PutioTheme.Typography.body
    static let sectionGap = PutioTheme.Spacing.space4
    static let itemGap = PutioTheme.Spacing.space2
    static let pagePadding = PutioTheme.Spacing.space3
    static let stateTileHeight = PutioTheme.Spacing.space6 * 2
    static let tileShape = RoundedRectangle(cornerRadius: PutioTheme.Radius.large)
  #endif
}
