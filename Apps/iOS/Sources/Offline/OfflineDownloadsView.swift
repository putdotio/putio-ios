import PutioCore
import SwiftUI

struct PutioOfflineDownloadsView: View {
  let queue: PutioOfflineQueue
  let onOpen: @MainActor (PutioOfflineItem) -> Void

  @Environment(\.locale) private var locale
  @Environment(\.scenePhase) private var scenePhase
  @State private var notifications = PutioOfflineNotificationStatus()
  @State private var isEditing = false
  @State private var selectedIDs: Set<PutioFileID> = []
  @State private var pendingRemoval: [PutioOfflineItem]?
  @State private var infoItem: PutioOfflineItem?

  private var removalCopy: PutioOfflineRemovalCopy { PutioOfflineRemovalCopy(isPad: isPad) }

  var body: some View {
    Group {
      if queue.items.isEmpty && queue.removing.isEmpty {
        empty
      } else {
        list
      }
    }
    .putioContentBackground()
    .navigationTitle("Downloads")
    .toolbar { toolbar }
    .environment(\.editMode, .constant(isEditing ? .active : .inactive))
    .environment(\.putioIsSelecting, isEditing)
    .putioAlert(
      removalCopy.title(count: pendingRemoval?.count ?? 1),
      isPresented: Binding(
        get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
      message: pendingRemoval.map { removalCopy.message(names: $0.map(\.name)) },
      actions: removalActions
    )
    .sheet(item: $infoItem) { item in
      PutioOfflineInfoView(
        item: queue.item(for: item.id) ?? item, source: queue.localSource(for: item.id)?.url)
    }
    .task {
      await queue.restore()
      queue.refreshStorage()
    }
    .task(id: scenePhase) {
      guard scenePhase == .active else { return }
      await notifications.refresh()
    }
    .accessibilityIdentifier("downloads.screen")
  }

  private var removalActions: [PutioAlertAction] {
    guard let targets = pendingRemoval else { return [] }
    let fileIDs = targets.map(\.id)
    return [
      PutioAlertAction(String(localized: "Cancel"), tier: .cancel, id: "downloads.remove-cancel"),
      PutioAlertAction(
        String(localized: "Remove"), tier: .destructive, id: "downloads.remove-confirm"
      ) {
        queue.remove(fileIDs: fileIDs)
        finishSelection()
      },
    ]
  }

  private func finishSelection() {
    selectedIDs = []
    isEditing = false
  }

  private var isPad: Bool {
    UIDevice.current.userInterfaceIdiom == .pad
  }

  private var storageLine: some View {
    let stored = Text(byteText(queue.storedBytes)).font(PutioTheme.Typography.mono.font)
    return HStack(alignment: .firstTextBaseline, spacing: PutioTheme.Spacing.space3) {
      if isPad {
        Text("\(stored) on this iPad")
      } else {
        Text("\(stored) on this iPhone")
      }
      Spacer(minLength: 0)
      Text("\(byteText(queue.availableBytes)) free")
    }
    .putioFont(PutioTheme.Typography.caption)
    .foregroundStyle(PutioTheme.Colors.textSecondary)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("downloads.storage-used")
  }

  private var empty: some View {
    GeometryReader { geometry in
      ScrollView {
        VStack(spacing: 0) {
          storageLine
            .padding(.horizontal, PutioTheme.Spacing.space3)
          PutioEmptyStateView(
            kaomoji: .shrug, title: String(localized: "Nothing downloaded yet"),
            message: String(localized: "Open a video or audio file’s actions and choose Download.")
          )
          .frame(maxHeight: .infinity)
          .accessibilityIdentifier("downloads.empty")
        }
        .frame(minHeight: geometry.size.height)
      }
    }
  }

  private var list: some View {
    let sections = PutioOfflineSections(
      queue.items, waitingForSlot: queue.slotWaiters, removing: queue.removing)
    return List(selection: isEditing ? $selectedIDs : nil) {
      storageLine
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .selectionDisabled()
      if notifications.showsRow(hasDownloads: !queue.items.isEmpty) {
        PutioOfflineNotificationsOffRow()
          .listRowBackground(Color.clear)
          .listRowSeparator(.hidden)
          .selectionDisabled()
      }
      ForEach(sections.sections) { section in
        Section {
          ForEach(section.items) { item in
            row(item, queuePosition: sections.queuePositions[item.id])
              .tag(item.id)
          }
        } header: {
          Text(title(section.kind))
        }
      }
    }
    .listStyle(.insetGrouped)
    .tint(PutioTheme.Colors.accent)
  }

  private func title(_ kind: PutioOfflineSections.Kind) -> String {
    switch kind {
    case .downloading: String(localized: "Downloading")
    case .attention: String(localized: "Needs attention")
    case .onDevice:
      isPad ? String(localized: "On this iPad") : String(localized: "On this iPhone")
    }
  }

  private func isRemoving(_ item: PutioOfflineItem) -> Bool {
    queue.item(for: item.id) == nil
  }

  private func rowModel(_ item: PutioOfflineItem, queuePosition: Int?) -> PutioFileRowModel {
    let finished = item.stage == .completed
    let removing = isRemoving(item)
    return PutioFileRowModel(
      name: item.name, kind: item.kind == .video ? .video : .audio,
      sizeText: finished && !removing ? item.storedSizeText : nil,
      dateText: finished && !removing
        ? PutioBrowserItemPresentation.relativeDateText(for: item.createdAt, locale: locale) : nil,
      isWatched: finished && !removing && item.isWatched == true,
      showsDisclosure: false,
      downloadState: removing
        ? .removing(on: isPad ? .iPad : .iPhone)
        : item.downloadState(queuePosition: queuePosition))
  }

  @ViewBuilder
  private func row(_ item: PutioOfflineItem, queuePosition: Int?) -> some View {
    let model = rowModel(item, queuePosition: queuePosition)
    if isRemoving(item) {
      PutioFileRow(model)
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(verbatim: "removing"))
        .accessibilityIdentifier("downloads.item.\(item.id.rawValue)")
        .selectionDisabled()
    } else {
      controlledRow(item, model: model)
    }
  }

  @ViewBuilder
  private func controlledRow(_ item: PutioOfflineItem, model: PutioFileRowModel) -> some View {
    Group {
      if isEditing {
        PutioFileRow(model)
          .contentShape(Rectangle())
          .accessibilityElement(children: .combine)
          .accessibilityValue(
            Text(selectedIDs.contains(item.id) ? "Selected" : "Not selected"))
      } else if item.stage == .completed {
        Button {
          if item.isPlayable { onOpen(item) } else { infoItem = item }
        } label: {
          PutioFileRow(model)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(Text(accessibilityValue(item)))
      } else {
        PutioFileRow(model) { action in
          queue.perform(action, fileID: item.id)
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue(Text(accessibilityValue(item)))
      }
    }
    .accessibilityIdentifier("downloads.item.\(item.id.rawValue)")
    .swipeActions(edge: .trailing, allowsFullSwipe: false) { swipeAction(item) }
    .contextMenu {
      if !isEditing { menu(item) }
    }
  }

  private func isInFlight(_ item: PutioOfflineItem) -> Bool {
    switch item.stage {
    case .completed, .failed, .missing: false
    case .queued, .waitingToConvert, .converting, .downloading, .waitingForNetwork,
      .waitingForStorage, .paused:
      true
    }
  }

  @ViewBuilder
  private func swipeAction(_ item: PutioOfflineItem) -> some View {
    if isInFlight(item) {
      Button {
        queue.remove(fileIDs: [item.id])
      } label: {
        Label("Cancel download", systemImage: "xmark.circle")
          .labelStyle(.iconOnly)
      }
      .tint(PutioTheme.Colors.destructive)
      .accessibilityIdentifier("downloads.cancel.\(item.id.rawValue)")
    } else {
      Button {
        pendingRemoval = [item]
      } label: {
        Label(removalCopy.actionTitle, systemImage: "minus.circle")
          .labelStyle(.iconOnly)
      }
      .tint(PutioTheme.Colors.destructive)
      .accessibilityIdentifier("downloads.remove.\(item.id.rawValue)")
    }
  }

  @ViewBuilder
  private func menu(_ item: PutioOfflineItem) -> some View {
    switch item.stage {
    case .completed:
      if item.isPlayable {
        menuButton(String(localized: "Play"), systemImage: "play", id: "play", item) {
          onOpen(item)
        }
      }
      menuButton(String(localized: "Info"), systemImage: "info.circle", id: "info", item) {
        infoItem = item
      }
      selectButton(item)
      Divider()
      removeButton(item)
    case .failed(let failure):
      if failure.canRetry {
        menuButton(
          String(localized: "Try again"), systemImage: "arrow.counterclockwise", id: "retry", item
        ) {
          queue.retry(fileID: item.id)
        }
      }
      selectButton(item)
      Divider()
      removeButton(item)
    case .missing:
      menuButton(
        String(localized: "Download again"), systemImage: "arrow.down.circle", id: "retry", item
      ) {
        queue.retry(fileID: item.id)
      }
      selectButton(item)
      Divider()
      removeButton(item)
    case .paused where !queue.isWaitingForSlot(item.id):
      menuButton(String(localized: "Resume"), systemImage: "play", id: "resume", item) {
        queue.resume(fileID: item.id)
      }
      selectButton(item)
      Divider()
      cancelButton(item)
    case .queued, .waitingToConvert, .converting, .downloading, .waitingForNetwork,
      .waitingForStorage, .paused:
      menuButton(String(localized: "Pause"), systemImage: "pause", id: "pause", item) {
        queue.pause(fileID: item.id)
      }
      selectButton(item)
      Divider()
      cancelButton(item)
    }
  }

  private func menuButton(
    _ title: String, systemImage: String, id: String, _ item: PutioOfflineItem,
    role: ButtonRole? = nil, action: @escaping () -> Void
  ) -> some View {
    Button(role: role, action: action) {
      Label(title, systemImage: systemImage)
    }
    .accessibilityIdentifier("downloads.\(id).\(item.id.rawValue)")
  }

  private func selectButton(_ item: PutioOfflineItem) -> some View {
    menuButton(String(localized: "Select"), systemImage: "checkmark.circle", id: "select", item) {
      selectedIDs = [item.id]
      isEditing = true
    }
  }

  private func cancelButton(_ item: PutioOfflineItem) -> some View {
    menuButton(
      String(localized: "Cancel download"), systemImage: "xmark.circle", id: "cancel", item,
      role: .destructive
    ) {
      queue.remove(fileIDs: [item.id])
    }
  }

  private func removeButton(_ item: PutioOfflineItem) -> some View {
    menuButton(
      removalCopy.actionTitle, systemImage: "minus.circle", id: "remove-menu", item,
      role: .destructive
    ) {
      pendingRemoval = [item]
    }
  }

  @ToolbarContentBuilder
  private var toolbar: some ToolbarContent {
    if !queue.items.isEmpty {
      if isEditing {
        ToolbarItem(placement: .primaryAction) {
          Button("Done") { finishSelection() }
            .accessibilityIdentifier("downloads.select-done")
        }
        ToolbarItem(placement: .topBarLeading) {
          Button("Remove \(selectedIDs.count)", role: .destructive) {
            pendingRemoval = queue.items.filter { selectedIDs.contains($0.id) }
          }
          .disabled(selectedIDs.isEmpty)
          .accessibilityIdentifier("downloads.remove-selected")
        }
      } else {
        ToolbarItem(placement: .primaryAction) {
          Menu {
            Button {
              isEditing = true
            } label: {
              Label("Select", systemImage: "checkmark.circle")
            }
            .accessibilityIdentifier("downloads.select")
            switch queue.bulkAction {
            case .pauseAll:
              Button {
                queue.pauseAll()
              } label: {
                Label("Pause all", systemImage: "pause")
              }
              .accessibilityIdentifier("downloads.pause-all")
            case .resumeAll:
              Button {
                queue.resumeAll()
              } label: {
                Label("Resume all", systemImage: "play")
              }
              .accessibilityIdentifier("downloads.resume-all")
            case nil:
              EmptyView()
            }
          } label: {
            Label("More", systemImage: "ellipsis")
          }
          .accessibilityIdentifier("downloads.more")
        }
      }
    }
  }

  private func accessibilityValue(_ item: PutioOfflineItem) -> String {
    let stage = stageValue(item)
    return item.isWatched == true ? "\(stage);watched" : stage
  }

  private func stageValue(_ item: PutioOfflineItem) -> String {
    switch item.stage {
    case .queued: "queued"
    case .waitingToConvert: "waiting-to-convert"
    case .converting(let progress): "converting;\(Int(progress * 100))"
    case .downloading(let progress): "downloading;\(Int(progress * 100))"
    case .waitingForNetwork(let progress): "waiting-network;\(Int(progress * 100))"
    case .waitingForStorage: "waiting-storage"
    case .paused(let progress) where queue.isWaitingForSlot(item.id):
      "queued;\(Int(progress * 100))"
    case .paused(let progress): "paused;\(Int(progress * 100))"
    case .completed: "completed"
    case .failed(let failure):
      item.failedProgress.map { "failed;\(failure.kind.rawValue);\(Int($0 * 100))" }
        ?? "failed;\(failure.kind.rawValue)"
    case .missing: "missing"
    }
  }

  private func byteText(_ bytes: Int64) -> String {
    PutioFileRowModel.sizeText(bytes: bytes)
  }
}

/// Writes can fail while queuing from Files or during playback, so the
/// signed-in shell presents the failure on every tab, not only in Downloads.
struct PutioOfflinePersistenceFailureAlert: ViewModifier {
  let queue: PutioOfflineQueue
  /// Dismissing clears this, and each report sets it again, so a retry that
  /// fails again presents a new alert.
  @State private var shown: PutioOfflinePersistenceFailure?

  func body(content: Content) -> some View {
    content
      .onChange(of: queue.persistenceFailureReports, initial: true) {
        shown = queue.persistenceFailure
      }
      .putioAlert(
        shown?.title ?? "",
        isPresented: Binding(
          get: { shown != nil && queue.persistenceFailure != nil },
          set: { if !$0 { shown = nil } }),
        message: shown?.message,
        actions: actions
      )
  }

  private var actions: [PutioAlertAction] {
    guard shown != nil else { return [] }
    return [
      PutioAlertAction(
        String(localized: "OK"), tier: .cancel, id: "downloads.save-dismiss"
      ) { [queue] in
        queue.dismissPersistenceFailure()
      },
      PutioAlertAction(
        String(localized: "Try again"), tier: .primary, id: "downloads.save-retry"
      ) { [queue] in
        Task {
          try? await Task.sleep(for: .milliseconds(500))
          queue.retryPersisting()
        }
      },
    ]
  }
}

/// What one finished download stores: its size, when it landed, its length
/// and the audio and subtitle languages on disk.
struct PutioOfflineInfoView: View {
  let item: PutioOfflineItem
  let source: URL?
  @Environment(\.locale) private var locale
  @State private var lengthSeconds: Int?
  @State private var contentHeight: CGFloat = 0

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: PutioTheme.Spacing.space3) {
        Text(verbatim: item.name)
          .putioFont(PutioTheme.Typography.subheading)
          .foregroundStyle(PutioTheme.Colors.textPrimary)
          .lineLimit(1)
          .truncationMode(.middle)
          .frame(maxWidth: .infinity)
          .accessibilityAddTraits(.isHeader)
          .accessibilityIdentifier("downloads.info.title")
        facts
      }
      .padding(.horizontal, PutioTheme.Spacing.space3)
      .padding(.top, PutioTheme.Spacing.space4)
      .padding(.bottom, PutioTheme.Spacing.space3)
      .onGeometryChange(for: CGFloat.self) {
        $0.size.height
      } action: {
        contentHeight = $0
      }
    }
    .scrollBounceBehavior(.basedOnSize)
    .frame(idealHeight: contentHeight > 0 ? contentHeight : nil)
    .background(PutioTheme.Components.Sheet.background)
    .presentationDetents(contentHeight > 0 ? [.height(contentHeight)] : [.medium])
    .presentationDragIndicator(.visible)
    .presentationSizing(.form.fitted(horizontal: false, vertical: true))
    .presentationBackground(PutioTheme.Components.Sheet.background)
    .task(id: source) {
      guard let source, let seconds = await PutioVideoLength.seconds(of: source),
        !Task.isCancelled
      else { return }
      lengthSeconds = Int(seconds.rounded())
    }
    .accessibilityIdentifier("downloads.info-sheet.\(item.id.rawValue)")
  }

  private var facts: some View {
    Grid(
      alignment: .leading,
      horizontalSpacing: PutioTheme.Spacing.space3,
      verticalSpacing: PutioTheme.Spacing.space2
    ) {
      if let size = item.storedSizeText {
        fact("size", label: String(localized: "Size"), value: size, numeric: true)
      }
      fact(
        "downloaded", label: String(localized: "Downloaded"),
        value: PutioBrowserItemPresentation.relativeDateText(
          for: item.completedAt ?? item.createdAt, locale: locale))
      if let lengthSeconds {
        fact(
          "length", label: String(localized: "Length"),
          value: PutioFileDetailText.clock(seconds: lengthSeconds), numeric: true)
      }
      if let audio = languages(item.storedAudioTracks) {
        fact("audio", label: String(localized: "Audio"), value: audio)
      }
      if let subtitles = languages(item.storedSubtitleTracks) {
        fact("subtitles", label: String(localized: "Subtitles"), value: subtitles)
      }
    }
  }

  private static let labelWidth =
    PutioTheme.Spacing.space6 - PutioTheme.Spacing.space3 + PutioTheme.Spacing.space1

  private func languages(_ tracks: [PutioOfflineTrack]) -> String? {
    var seen = Set<String>()
    let names = tracks.map(\.displayName).filter { !$0.isEmpty && seen.insert($0).inserted }
    return names.isEmpty ? nil : names.formatted(.list(type: .and, width: .narrow).locale(locale))
  }

  private func fact(_ id: String, label: String, value: String, numeric: Bool = false)
    -> some View
  {
    GridRow(alignment: .firstTextBaseline) {
      Text(label)
        .putioFont(PutioTheme.Typography.body)
        .foregroundStyle(PutioTheme.Colors.textSecondary)
        .frame(minWidth: Self.labelWidth, alignment: .leading)
        .accessibilityValue(Text(verbatim: value))
        .accessibilityIdentifier("downloads.info.\(id)")
      Group {
        if numeric {
          Text(verbatim: value).putioFont(PutioTheme.Typography.numeric)
        } else {
          Text(verbatim: value).putioFont(PutioTheme.Typography.body)
        }
      }
      .foregroundStyle(PutioTheme.Colors.textPrimary)
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityHidden(true)
    }
  }
}
