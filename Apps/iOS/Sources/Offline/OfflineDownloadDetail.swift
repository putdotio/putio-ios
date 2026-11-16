import Foundation
import PutioCore
import SwiftUI

struct PutioOfflineDownloadsScreen: View {
  let queue: PutioOfflineQueue
  let loadDetails: PutioVideoDetailsLoad?
  let onOpen: @MainActor (PutioOfflineItem) -> Void

  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @State private var isLandscape: Bool?
  @State private var selection: PutioFileID?

  var body: some View {
    Group {
      if let isLandscape {
        if horizontalSizeClass == .regular && isLandscape {
          columns
        } else {
          NavigationStack {
            PutioOfflineDownloadsView(queue: queue, onOpen: onOpen)
          }
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
    .onChange(of: selectionIsGone) { _, gone in
      if gone { selection = nil }
    }
  }

  private var selectionIsGone: Bool {
    guard let selection else { return false }
    return queue.item(for: selection) == nil
  }

  private var columns: some View {
    PutioListDetail(
      selection: $selection,
      emptyTitle: String(localized: "No download selected"),
      emptyMessage: String(localized: "Tap a download to see it here.")
    ) { _ in
      PutioOfflineDownloadsView(
        queue: queue, onOpen: onOpen, onSelect: { selection = $0.id })
    } detail: { id in
      if let item = queue.item(for: id) {
        PutioOfflineDownloadDetailView(
          queue: queue, item: item, loadDetails: loadDetails, onOpen: onOpen,
          onRemoved: { selection = nil })
      }
    }
  }
}

enum PutioOfflineDetailAction: Equatable {
  case play
  case pause
  case resume
  case retry
  case downloadAgain
  case cancel
  case remove
}

struct PutioOfflineDetailFacts: Equatable {
  struct Status: Equatable {
    let text: String
    let numeric: String?
    let isFailure: Bool
  }

  let actions: [PutioOfflineDetailAction]
  let resumeSeconds: Int?
  let size: String
  let downloaded: String?
  let status: Status?
  let audio: String?
  let subtitles: String?

  init(
    _ item: PutioOfflineItem, queuePosition: Int?, isWaitingForSlot: Bool,
    remoteSubtitles: [String]?, locale: Locale, now: Date = .now
  ) {
    let state = item.downloadState(queuePosition: queuePosition)
    let total = PutioFileRowModel.sizeText(bytes: item.estimatedBytes, locale: locale)
    let position = item.pendingPositionSeconds ?? item.resumePositionSeconds
    resumeSeconds = item.stage == .completed && position > 0 ? position : nil
    switch item.stage {
    case .completed:
      actions = item.isPlayable ? [.play, .remove] : [.remove]
      size = PutioFileRowModel.sizeText(bytes: item.storedBytes, locale: locale)
      downloaded = PutioBrowserItemPresentation.relativeDateText(
        for: item.completedAt ?? item.createdAt, relativeTo: now, locale: locale)
      status = nil
      audio = Self.names(item.storedAudioTracks.map(\.displayName), locale: locale)
      subtitles = Self.names(item.storedSubtitleTracks.map(\.displayName), locale: locale)
      return
    case .failed(let failure):
      actions = failure.canRetry ? [.retry, .remove] : [.remove]
    case .missing:
      actions = [.downloadAgain, .remove]
    case .paused where !isWaitingForSlot:
      actions = [.resume, .cancel]
    case .queued, .waitingToConvert, .converting, .downloading, .waitingForNetwork,
      .waitingForStorage, .paused:
      actions = [.pause, .cancel]
    }
    downloaded = nil
    let presentation = PutioDownloadPresentation(state, locale: locale)
    switch state {
    case .downloading(let received, let totalBytes):
      size = PutioDownloadPresentation.bytesText(received, of: totalBytes, locale: locale)
      let fraction = totalBytes > 0 ? Double(received) / Double(totalBytes) : 0
      status = Status(
        text: String(localized: "Downloading"),
        numeric: PutioDownloadPresentation.percentText(min(max(fraction, 0), 1), locale: locale),
        isFailure: false)
    case .paused(let received, let totalBytes):
      size = PutioDownloadPresentation.bytesText(received, of: totalBytes, locale: locale)
      status = presentation.statusLine.first.map {
        Status(text: $0.text, numeric: nil, isFailure: false)
      }
    case .waiting(_, let received, let totalBytes) where received > 0:
      size = PutioDownloadPresentation.bytesText(received, of: totalBytes, locale: locale)
      status = presentation.statusLine.first.map {
        Status(text: $0.text, numeric: nil, isFailure: false)
      }
    default:
      size = total
      let line = presentation.statusLine
      status = line.first.map {
        Status(
          text: $0.text, numeric: line.count > 1 ? line[1].text : nil,
          isFailure: presentation.tone == .destructive)
      }
    }
    audio = nil
    if case .failed = item.stage {
      subtitles = nil
    } else {
      subtitles = item.kind == .video ? Self.names(remoteSubtitles ?? [], locale: locale) : nil
    }
  }

  private static func names(_ names: [String], locale: Locale) -> String? {
    var seen = Set<String>()
    let unique = names.filter { !$0.isEmpty && seen.insert($0).inserted }
    return unique.isEmpty ? nil : unique.formatted(.list(type: .and, width: .narrow).locale(locale))
  }
}

struct PutioOfflineDownloadDetailView: View {
  let queue: PutioOfflineQueue
  let item: PutioOfflineItem
  let loadDetails: PutioVideoDetailsLoad?
  let onOpen: @MainActor (PutioOfflineItem) -> Void
  let onRemoved: @MainActor () -> Void

  @Environment(\.locale) private var locale
  @State private var localLength: Int?
  @State private var remote: PutioVideoDetails?
  @State private var pendingRemoval: [PutioOfflineItem]?

  private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

  private var facts: PutioOfflineDetailFacts {
    let sections = PutioOfflineSections(
      queue.items, waitingForSlot: queue.slotWaiters, removing: queue.removing)
    return PutioOfflineDetailFacts(
      item, queuePosition: sections.queuePositions[item.id],
      isWaitingForSlot: queue.isWaitingForSlot(item.id), remoteSubtitles: remote?.subtitles,
      locale: locale)
  }

  private var lengthSeconds: Int? { localLength ?? remote?.durationSeconds }

  var body: some View {
    let facts = facts
    ScrollView {
      VStack(alignment: .leading, spacing: PutioOfflineDetailLayout.sectionGap) {
        preview(facts)
        Text(PutioFileDetailText.wrappableName(item.name))
          .putioFont(PutioOfflineDetailLayout.title)
          .foregroundStyle(PutioTheme.Colors.textPrimary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityLabel(Text(verbatim: item.name))
          .accessibilityAddTraits(.isHeader)
          .accessibilityIdentifier("downloads.detail.title")
        actionRow(facts)
        factGrid(facts)
      }
      .frame(maxWidth: PutioOfflineDetailLayout.readableWidth, alignment: .leading)
      .padding(PutioTheme.Spacing.space4)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .putioContentBackground()
    .toolbar(.hidden, for: .navigationBar)
    .toolbar(removing: .sidebarToggle)
    .putioOfflineRemovalAlert($pendingRemoval, queue: queue, isPad: isPad) { onRemoved() }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("downloads.detail.\(item.id.rawValue)")
    .task(id: queue.localSource(for: item.id)?.url) {
      guard let url = queue.localSource(for: item.id)?.url,
        let seconds = await PutioVideoLength.seconds(of: url), !Task.isCancelled
      else { return }
      localLength = Int(seconds.rounded())
    }
    .task(id: item.id) {
      guard let loadDetails, let details = try? await loadDetails(item.id), !Task.isCancelled
      else { return }
      remote = details
    }
  }

  @ViewBuilder
  private func preview(_ facts: PutioOfflineDetailFacts) -> some View {
    RoundedRectangle(cornerRadius: PutioOfflineDetailLayout.previewRadius)
      .fill(PutioTheme.Colors.surface)
      .aspectRatio(PutioOfflineDetailLayout.previewAspectRatio, contentMode: .fit)
      .overlay {
        if facts.actions.contains(.play) {
          Button {
            onOpen(item)
          } label: {
            PutioIconView(.playFill, size: PutioOfflineDetailLayout.playGlyph)
              .foregroundStyle(PutioTheme.Colors.textPrimary)
              .frame(
                width: PutioOfflineDetailLayout.playControl,
                height: PutioOfflineDetailLayout.playControl
              )
              .background(PutioTheme.Colors.surfaceActive, in: Circle())
              .contentShape(Circle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel(Text("Play"))
          .accessibilityIdentifier("downloads.detail.preview-play")
        } else {
          PutioIconView(
            item.kind == .video ? .fileVideoFill : .fileAudioFill,
            size: PutioOfflineDetailLayout.kindGlyph
          )
          .foregroundStyle(PutioTheme.Colors.accent)
          .accessibilityHidden(true)
        }
      }
      .overlay(alignment: .bottom) {
        if let resume = facts.resumeSeconds, let length = lengthSeconds, length > 0 {
          ProgressView(value: min(Double(resume) / Double(length), 1))
            .tint(PutioTheme.Colors.accent)
            .padding(PutioTheme.Spacing.space3)
            .accessibilityHidden(true)
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: PutioOfflineDetailLayout.previewRadius))
  }

  private func actionRow(_ facts: PutioOfflineDetailFacts) -> some View {
    HStack(spacing: PutioTheme.Spacing.space2) {
      ForEach(facts.actions, id: \.self) { action in
        button(action, facts: facts)
      }
    }
    .fixedSize(horizontal: true, vertical: false)
  }

  @ViewBuilder
  private func button(_ action: PutioOfflineDetailAction, facts: PutioOfflineDetailFacts)
    -> some View
  {
    switch action {
    case .play:
      PutioOfflineDetailButton(
        playTitle(facts), systemImage: "play.fill", id: "play", prominent: true
      ) { onOpen(item) }
    case .pause:
      PutioOfflineDetailButton(String(localized: "Pause"), systemImage: "pause.fill", id: "pause") {
        queue.pause(fileID: item.id)
      }
    case .resume:
      PutioOfflineDetailButton(String(localized: "Resume"), systemImage: "play.fill", id: "resume")
      {
        queue.resume(fileID: item.id)
      }
    case .retry:
      PutioOfflineDetailButton(
        String(localized: "Try again"), systemImage: "arrow.counterclockwise", id: "retry"
      ) { queue.retry(fileID: item.id) }
    case .downloadAgain:
      PutioOfflineDetailButton(
        String(localized: "Download again"), systemImage: "arrow.down.circle", id: "retry"
      ) { queue.retry(fileID: item.id) }
    case .cancel:
      PutioOfflineDetailButton(
        String(localized: "Cancel download"), systemImage: "xmark.circle", id: "cancel",
        role: .destructive
      ) { queue.remove(fileIDs: [item.id]) }
    case .remove:
      PutioOfflineDetailButton(
        String(localized: "Remove"), systemImage: "minus.circle", id: "remove", role: .destructive
      ) { pendingRemoval = [item] }
    }
  }

  private func playTitle(_ facts: PutioOfflineDetailFacts) -> String {
    guard let resume = facts.resumeSeconds else { return String(localized: "Play") }
    let time = PutioFileDetailText.clock(seconds: resume)
    return String(localized: "Resume from \(time)")
  }

  private func factGrid(_ facts: PutioOfflineDetailFacts) -> some View {
    Grid(
      alignment: .leading,
      horizontalSpacing: PutioTheme.Spacing.space3,
      verticalSpacing: PutioTheme.Spacing.space2
    ) {
      fact("size", label: String(localized: "Size"), Text(verbatim: facts.size), numeric: true)
        .accessibilityValue(Text(verbatim: facts.size))
      if let downloaded = facts.downloaded {
        fact("downloaded", label: String(localized: "Downloaded"), Text(verbatim: downloaded))
          .accessibilityValue(Text(verbatim: downloaded))
      }
      if let status = facts.status {
        let value = [status.text, status.numeric].compactMap { $0 }.joined(separator: " · ")
        fact(
          "status", label: String(localized: "Status"), statusText(status),
          isFailure: status.isFailure
        )
        .accessibilityValue(Text(verbatim: value))
      }
      if let lengthSeconds {
        let length = PutioFileDetailText.clock(seconds: lengthSeconds)
        fact("length", label: String(localized: "Length"), Text(verbatim: length), numeric: true)
          .accessibilityValue(Text(verbatim: length))
      }
      if let audio = facts.audio {
        fact("audio", label: String(localized: "Audio"), Text(verbatim: audio))
          .accessibilityValue(Text(verbatim: audio))
      }
      if let subtitles = facts.subtitles {
        fact("subtitles", label: String(localized: "Subtitles"), Text(verbatim: subtitles))
          .accessibilityValue(Text(verbatim: subtitles))
      }
    }
  }

  private func statusText(_ status: PutioOfflineDetailFacts.Status) -> Text {
    let lead = Text(verbatim: status.text)
    guard let numeric = status.numeric else { return lead }
    return lead + Text(verbatim: " · ")
      + Text(verbatim: numeric).font(PutioTheme.Typography.mono.font)
  }

  private func fact(
    _ id: String, label: String, _ value: Text, numeric: Bool = false, isFailure: Bool = false
  ) -> some View {
    GridRow(alignment: .firstTextBaseline) {
      Text(label)
        .putioFont(PutioTheme.Typography.body)
        .foregroundStyle(PutioTheme.Colors.textSecondary)
        .frame(minWidth: PutioOfflineDetailLayout.factLabelWidth, alignment: .leading)
      Group {
        if numeric {
          value.putioFont(PutioTheme.Typography.numeric)
        } else {
          value.putioFont(PutioTheme.Typography.body)
        }
      }
      .foregroundStyle(isFailure ? PutioTheme.Colors.destructive : PutioTheme.Colors.textPrimary)
      .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(verbatim: label))
    .accessibilityIdentifier("downloads.detail.\(id)")
  }
}

private struct PutioOfflineDetailButton: View {
  let title: String
  let systemImage: String
  let id: String
  let prominent: Bool
  let role: ButtonRole?
  let action: () -> Void

  init(
    _ title: String, systemImage: String, id: String, prominent: Bool = false,
    role: ButtonRole? = nil, action: @escaping () -> Void
  ) {
    self.title = title
    self.systemImage = systemImage
    self.id = id
    self.prominent = prominent
    self.role = role
    self.action = action
  }

  var body: some View {
    Group {
      if prominent {
        Button(role: role, action: action) {
          label.foregroundStyle(PutioTheme.Components.Button.primaryForeground)
        }
        .buttonStyle(.borderedProminent)
        .tint(PutioTheme.Colors.accent)
      } else {
        Button(role: role, action: action) { label }
          .buttonStyle(.bordered)
          .tint(
            role == .destructive ? PutioTheme.Colors.destructive : PutioTheme.Colors.textPrimary)
      }
    }
    .controlSize(.regular)
    .lineLimit(1)
    .accessibilityIdentifier("downloads.detail.\(id)")
  }

  private var label: some View {
    Label(title, systemImage: systemImage)
      .putioFont(PutioTheme.Components.Button.label)
  }
}

private enum PutioOfflineDetailLayout {
  static let readableWidth = PutioTheme.Spacing.space8 + PutioTheme.Spacing.space6
  static let sectionGap = PutioTheme.Spacing.space3
  static let previewAspectRatio: CGFloat = 16 / 9
  static let previewRadius = PutioTheme.Radius.large
  static let playControl = PutioTheme.Spacing.space5
  static let playGlyph = PutioMetricRole(
    value: PutioTheme.Spacing.space3 + PutioTheme.Spacing.space2, relativeTo: .title)
  static let kindGlyph = PutioMetricRole(value: PutioTheme.Spacing.space5, relativeTo: .largeTitle)
  static let factLabelWidth =
    PutioTheme.Spacing.space6 - PutioTheme.Spacing.space3 + PutioTheme.Spacing.space1
  static let title = PutioFontRole(
    fontName: PutioTheme.Typography.subheading.fontName,
    size: PutioTheme.Typography.sizeLg - PutioTheme.Spacing.space1 / 2,
    lineHeight: PutioTheme.Typography.subheading.lineHeight,
    textStyle: .title2
  )
}
