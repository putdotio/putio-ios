import Foundation
import PutioCore
import SwiftUI
import UIKit

typealias PutioVideoDetailsLoad =
  @MainActor @Sendable (PutioFileID) async throws -> PutioVideoDetails
typealias PutioFolderNameLoad = @MainActor @Sendable (PutioFileID) async throws -> String

struct PutioFileDetailView: View {
  let route: PutioFileRoute
  let folderTitles: [String]?
  let previewSource: PutioPreviewSource?
  let menu: (@MainActor () -> PutioItemMenu)?
  let offlineStatus: PutioOfflineFileStatus
  let reloadKey: UInt64
  let loadDetails: PutioVideoDetailsLoad
  let loadFolderName: PutioFolderNameLoad
  var showsNavigationBar = false
  let onOpen: PutioFileSelection
  let onDownload: PutioFileSelection?
  let onExternalPlayback: PutioFileSelection?

  @Environment(\.locale) private var locale
  @Environment(\.putioFileShare) private var fileShare
  @Environment(\.putioPinnedFiles) private var pinned
  @Environment(\.putioPreviewOpen) private var previewOpen
  @State private var details: PutioVideoDetails?
  @State private var previewImage: PreviewImage?
  @State private var loadedFolder: String?
  @State private var share = PutioFileShareModel()
  @State private var toast: PutioToast?
  @State private var preparingToast: PutioToast.ID?

  private var item: PutioFileItem { route.item }
  private var isVideo: Bool { route.videoPlaybackRoute != nil }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: PutioFileDetailLayout.sectionGap) {
        preview
        Text(PutioFileDetailText.wrappableName(item.name))
          .putioFont(PutioTheme.Typography.subheading)
          .foregroundStyle(PutioTheme.Colors.textPrimary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityLabel(Text(verbatim: item.name))
          .accessibilityIdentifier("files.detail.title")
        actionRow
        facts
      }
      .frame(maxWidth: PutioFileDetailLayout.readableWidth, alignment: .leading)
      .padding(PutioTheme.Spacing.space4)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .putioContentBackground()
    .toolbar(showsNavigationBar ? .visible : .hidden, for: .navigationBar)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar(removing: .sidebarToggle)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("files.detail.\(item.id.rawValue)")
    .putioToast($toast)
    .task(id: LoadKey(id: item.id, parentID: item.parentID, reload: reloadKey)) { await load() }
    .task(id: item.id) { await loadPreviewImage() }
    .onChange(of: share.state) { _, state in
      if case .fetching = state { return }
      if toast?.id == preparingToast { toast = nil }
      preparingToast = nil
    }
    .onDisappear { share.leave() }
  }

  @ViewBuilder
  private var preview: some View {
    if isVideo {
      videoPreview
    } else {
      filePreview
    }
  }

  private var filePreview: some View {
    let image = previewImage?.id == item.id ? previewImage?.image : nil
    return RoundedRectangle(cornerRadius: PutioFileDetailLayout.previewRadius)
      .fill(PutioTheme.Colors.surface)
      .aspectRatio(PutioFileDetailLayout.previewAspectRatio, contentMode: .fit)
      .overlay {
        if let image {
          Image(uiImage: image)
            .resizable()
            .scaledToFill()
        } else {
          PutioIconView(
            PutioBrowserItemPresentation.rowKind(for: item.kind).icon,
            size: PutioFileDetailLayout.kindGlyph
          )
          .foregroundStyle(PutioTheme.Components.FileRow.icon)
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: PutioFileDetailLayout.previewRadius))
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(Text(verbatim: item.name))
      .accessibilityAddTraits(image == nil ? [] : .isImage)
      .accessibilityIdentifier(
        image == nil ? "files.detail.preview-glyph" : "files.detail.preview-image")
  }

  private var videoPreview: some View {
    RoundedRectangle(cornerRadius: PutioFileDetailLayout.previewRadius)
      .fill(PutioTheme.Colors.surface)
      .aspectRatio(PutioFileDetailLayout.previewAspectRatio, contentMode: .fit)
      .overlay {
        Button {
          onOpen(route)
        } label: {
          PutioIconView(.playFill, size: PutioFileDetailLayout.playGlyph)
            .foregroundStyle(PutioTheme.Colors.textPrimary)
            .frame(
              width: PutioFileDetailLayout.playControl, height: PutioFileDetailLayout.playControl
            )
            .background(PutioTheme.Colors.surfaceActive, in: Circle())
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Play"))
        .accessibilityIdentifier("files.detail.preview-play")
      }
  }

  private var actionRow: some View {
    HStack(spacing: PutioTheme.Spacing.space2) {
      if isVideo {
        PutioButton(primaryTitle, icon: .playFill, tier: .primary, size: .medium) {
          onOpen(route)
        }
        .lineLimit(1)
        .accessibilityIdentifier("files.detail.play")
      } else {
        PutioButton(String(localized: "Open"), icon: .arrowSquareOut, tier: .primary, size: .medium)
        {
          open()
        }
        .lineLimit(1)
        .accessibilityIdentifier("files.detail.open")
      }
      if offlineStatus == .onDevice {
        iconButton(.arrowCircleDownFill, label: String(localized: "Downloaded"), dimmed: true) {}
          .disabled(true)
          .accessibilityIdentifier("files.detail.on-device")
      } else if let onDownload, route.supportsOfflineDownload {
        iconButton(.arrowCircleDown, label: String(localized: "Download")) {
          onDownload(route)
        }
        .disabled(offlineStatus == .queued)
        .accessibilityIdentifier("files.detail.download")
      }
      if fileShare != nil {
        iconButton(.export, label: String(localized: "Share")) { startShare() }
          .disabled(shareSource == nil || isFetchingShare)
          .accessibilityIdentifier("files.detail.share")
          .background {
            if let file = share.presented(for: item.id) {
              PutioShareSheetAnchor(file: file, name: item.name, model: share)
            }
          }
      }
      if let more = moreMenu {
        Menu {
          PutioItemMenuContent(more)
        } label: {
          PutioFileDetailIconLabel(icon: .dotsThree)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("More"))
        .accessibilityIdentifier("files.detail.more")
      }
    }
    .fixedSize(horizontal: true, vertical: false)
  }

  private var primaryTitle: String {
    let position = details?.resumePositionSeconds ?? item.resumePositionSeconds
    guard position > 0 else { return String(localized: "Play") }
    let time = PutioFileDetailText.clock(seconds: position)
    return String(localized: "Resume from \(time)")
  }

  private func iconButton(
    _ icon: PutioIcon, label: String, dimmed: Bool = false, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) { PutioFileDetailIconLabel(icon: icon, dimmed: dimmed) }
      .buttonStyle(.plain)
      .accessibilityLabel(Text(label))
  }

  private var moreMenu: PutioItemMenu? {
    let more = menu?() ?? PutioItemMenu([moreActions])
    return more.sections.isEmpty ? nil : more
  }

  private func open() {
    if let previewOpen, let previewSource, route.previewKind != nil {
      previewOpen(route, in: previewSource)
    } else {
      onOpen(route)
    }
  }

  private var moreActions: [PutioItemAction] {
    var actions: [PutioItemAction] = []
    if let onExternalPlayback, route.supportsExternalPlayback {
      actions.append(
        PutioItemAction(
          id: "open-in-vlc", title: String(localized: "Open in VLC"), icon: .trafficCone
        ) { onExternalPlayback(route) })
    }
    if let pins = pinned?.model, !item.isShared || pins.isPinned(item.id) {
      let item = item
      let location = folderTitles?.last ?? loadedFolder
      actions.append(
        pins.isPinned(item.id)
          ? PutioItemAction(id: "unpin", title: String(localized: "Unpin"), icon: .pushPinSlash) {
            Task { await pins.unpin(item) }
          }
          : PutioItemAction(id: "pin", title: String(localized: "Pin"), icon: .pushPin) {
            Task { await pins.pin(item, in: location) }
          })
    }
    return actions
  }

  private var facts: some View {
    Grid(
      alignment: .leading,
      horizontalSpacing: PutioTheme.Spacing.space3,
      verticalSpacing: PutioTheme.Spacing.space2
    ) {
      fact(
        "size", label: String(localized: "Size"),
        value: PutioFileRowModel.sizeText(bytes: item.sizeBytes, locale: locale), numeric: true)
      fact(
        "added", label: String(localized: "Added"),
        value: item.createdAt.formatted(
          .dateTime.month(.abbreviated).day().year().locale(locale)))
      if isVideo, let seconds = details?.durationSeconds {
        fact(
          "length", label: String(localized: "Length"),
          value: PutioFileDetailText.clock(seconds: seconds), numeric: true)
      }
      if isVideo, let subtitles = details?.subtitles, !subtitles.isEmpty {
        fact(
          "subtitles", label: String(localized: "Subtitles"),
          value: subtitles.formatted(.list(type: .and, width: .narrow).locale(locale)))
      }
      if let folder = folderText {
        fact("folder", label: String(localized: "Folder"), value: folder)
      }
    }
  }

  @ViewBuilder
  private func fact(_ id: String, label: String, value: String, numeric: Bool = false)
    -> some View
  {
    GridRow(alignment: .firstTextBaseline) {
      Text(label)
        .putioFont(PutioTheme.Typography.body)
        .foregroundStyle(PutioTheme.Colors.textSecondary)
        .frame(minWidth: PutioFileDetailLayout.factLabelWidth, alignment: .leading)
        .accessibilityLabel(Text(verbatim: "\(label), \(value)"))
        .accessibilityIdentifier("files.detail.fact.\(id)")
      Group {
        if numeric {
          Text(value).putioFont(PutioTheme.Typography.numeric)
        } else {
          Text(value).putioFont(PutioTheme.Typography.body)
        }
      }
      .foregroundStyle(PutioTheme.Colors.textPrimary)
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityHidden(true)
    }
  }

  private var folderText: String? {
    if let folderTitles { return PutioFileDetailText.folderPath(folderTitles) }
    return loadedFolder
  }

  private func load() async {
    let id = item.id
    let loadsDetails = isVideo
    async let videoDetails: PutioVideoDetails? = loadsDetails ? try? loadDetails(id) : nil
    if folderTitles == nil {
      let name = try? await loadFolderName(item.parentID)
      if !Task.isCancelled { loadedFolder = name }
    }
    let loaded = await videoDetails
    guard !Task.isCancelled, let loaded else { return }
    details = loaded
  }

  private func loadPreviewImage() async {
    let id = item.id
    guard let fileShare, case .preview(let preview)? = PutioViewerRoute(opening: route.openAction),
      preview.kind == .image
    else { return }
    guard let data = try? await fileShare.fetch(preview, .preview),
      let image = try? await PutioPreviewModel.decodeImage(
        data, maximumPixels: PutioFileDetailLayout.previewPixels),
      !Task.isCancelled
    else { return }
    previewImage = PreviewImage(id: id, image: image)
  }

  private struct PreviewImage {
    let id: PutioFileID
    let image: UIImage
  }

  private struct LoadKey: Equatable {
    let id: PutioFileID
    let parentID: PutioFileID
    let reload: UInt64
  }

  private var shareSource: PutioFileShareSource? {
    guard let fileShare else { return nil }
    return PutioFileShareSource(
      item: item, isDownloaded: share.isDownloaded(item, using: fileShare))
  }

  private var isFetchingShare: Bool {
    if case .fetching = share.state { return true }
    return false
  }

  private func startShare() {
    guard let fileShare else { return }
    let item = item
    let fetching = share.share(item, using: fileShare) { failure in
      switch failure {
      case .retryable:
        toast = PutioToast(
          PutioScreenErrorKind.failed.title,
          action: PutioToast.Action(String(localized: "Try again")) { startShare() })
      case .final:
        toast = PutioToast(PutioScreenErrorKind.failed.title)
      }
    }
    guard fetching else { return }
    let preparing = PutioToast(
      String(localized: "Preparing…"),
      action: PutioToast.Action(String(localized: "Cancel")) { share.cancel() },
      staysUntilDismissed: true)
    toast = preparing
    preparingToast = preparing.id
  }
}

private struct PutioFileDetailIconLabel: View {
  let icon: PutioIcon
  var dimmed = false
  @PutioScaledMetric(PutioFileDetailLayout.actionControl) private var diameter

  var body: some View {
    PutioIconView(icon, size: PutioFileDetailLayout.actionGlyph)
      .foregroundStyle(dimmed ? PutioTheme.Colors.textDisabled : PutioTheme.Colors.textPrimary)
      .frame(width: diameter, height: diameter)
      .background(PutioTheme.Colors.surfaceActive, in: Circle())
      .contentShape(Circle())
  }
}

private enum PutioFileDetailLayout {
  static let readableWidth = PutioTheme.Spacing.space8 + PutioTheme.Spacing.space6
  static let sectionGap = PutioTheme.Spacing.space3
  static let previewAspectRatio: CGFloat = 16 / 9
  static let previewRadius = PutioTheme.Radius.large
  static let playControl = PutioTheme.Spacing.space5
  static let playGlyph = PutioMetricRole(
    value: PutioTheme.Spacing.space3 + PutioTheme.Spacing.space2, relativeTo: .title)
  static let actionGlyph = PutioMetricRole(
    value: PutioTheme.Spacing.space3 + PutioTheme.Spacing.space1, relativeTo: .body)
  static let actionControl = PutioMetricRole(
    value: PutioTheme.Spacing.space4 + PutioTheme.Spacing.space1 + PutioTheme.Spacing.space1 / 2,
    relativeTo: .body)
  static let factLabelWidth = PutioTheme.Spacing.space6
  static let kindGlyph = PutioMetricRole(value: PutioTheme.Spacing.space4, relativeTo: .largeTitle)
  static let previewPixels = 2_048
}
