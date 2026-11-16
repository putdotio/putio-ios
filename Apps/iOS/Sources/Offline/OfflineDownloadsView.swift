import PutioCore
import SwiftUI
import UserNotifications

/// The Downloads tab: a storage line, then what is downloading, what needs
/// attention and what is on the device.
struct PutioOfflineDownloadsView: View {
  let queue: PutioOfflineQueue
  let trashEnabled: Bool
  /// False while account preferences are stale or saving; the runtime would
  /// refuse the delete.
  let canDeleteOriginals: Bool
  let onOpen: @MainActor (PutioOfflineItem) -> Void

  @Environment(\.locale) private var locale
  @State private var isEditing = false
  @State private var selectedIDs: Set<PutioFileID> = []
  @State private var pendingRemoval: [PutioOfflineRemovalTarget]?
  @State private var detailItem: PutioOfflineItem?
  @State private var shownOriginalFailure: PutioOfflineOriginalOutcome?

  /// Worded for the mode the presented targets captured, so a preference
  /// refresh while the dialog is up cannot make the text disagree with the
  /// action.
  private var copy: PutioOfflineRemovalCopy {
    PutioOfflineRemovalCopy(trashEnabled: pendingRemoval?.first?.movesToTrash ?? trashEnabled)
  }

  private var originalFailureActions: [PutioAlertAction] {
    guard let outcome = shownOriginalFailure else { return [] }
    var actions = [
      PutioAlertAction(String(localized: "OK"), tier: .cancel) { [queue] in
        queue.dismissOriginalFailure(shown: outcome)
      }
    ]
    if !outcome.retryableTargets.isEmpty {
      actions.append(
        PutioAlertAction(
          String(localized: "Try again"), tier: .primary, id: "downloads.remove-original-retry"
        ) { [queue] in
          let targets = queue.takeFailedOriginalsForRetry(shown: outcome)
          Task { _ = await queue.deleteOriginals(targets) }
        })
    }
    return actions
  }

  var body: some View {
    Group {
      if queue.items.isEmpty {
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
    .confirmationDialog(
      copy.title(names: pendingRemoval?.map(\.name) ?? []),
      isPresented: Binding(
        get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
      titleVisibility: .visible,
      presenting: pendingRemoval
    ) { targets in
      // The targets ride along with the presentation; the binding clears
      // before the action runs, so reading `pendingRemoval` here would see nil.
      Button(copy.localActionTitle(count: targets.count)) {
        queue.remove(fileIDs: targets.map(\.id))
        finishSelection()
      }
      .accessibilityIdentifier("downloads.remove-local")
      Button(copy.remoteActionTitle(count: targets.count), role: .destructive) {
        finishSelection()
        // The request outlives this screen; the queue keeps the outcome.
        let movesToTrash = targets.first?.movesToTrash ?? trashEnabled
        Task {
          _ = await queue.removeDeletingOriginals(
            fileIDs: targets.map(\.id), movesToTrash: movesToTrash)
        }
      }
      .disabled(!canDeleteOriginals)
      .accessibilityIdentifier("downloads.remove-original")
      Button("Cancel", role: .cancel) {}
    } message: { targets in
      Text(copy.message(count: targets.count))
    }
    .onChange(of: queue.originalFailure, initial: true) {
      shownOriginalFailure = queue.originalFailure
    }
    .putioAlert(
      copy.failureTitle(outcome: shownOriginalFailure ?? PutioOfflineOriginalOutcome()),
      isPresented: Binding(
        get: { shownOriginalFailure != nil && queue.originalFailure != nil },
        set: { if !$0 { shownOriginalFailure = nil } }),
      message: shownOriginalFailure.map { copy.failureMessage(outcome: $0) },
      actions: originalFailureActions
    )
    .sheet(item: $detailItem) { item in
      PutioOfflineDetailView(item: queue.item(for: item.id) ?? item)
        .preferredColorScheme(.dark)
    }
    .task {
      await queue.restore()
      queue.refreshStorage()
    }
    .accessibilityIdentifier("downloads.screen")
  }

  private func finishSelection() {
    selectedIDs = []
    isEditing = false
  }

  private func removalTarget(_ item: PutioOfflineItem) -> PutioOfflineRemovalTarget {
    PutioOfflineRemovalTarget(id: item.id, name: item.name, movesToTrash: trashEnabled)
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
    let sections = PutioOfflineSections(queue.items)
    return List(selection: isEditing ? $selectedIDs : nil) {
      storageLine
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .selectionDisabled()
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

  private func rowModel(_ item: PutioOfflineItem, queuePosition: Int?) -> PutioFileRowModel {
    let finished = item.stage == .completed
    return PutioFileRowModel(
      name: item.name, kind: item.kind == .video ? .video : .audio,
      sizeText: finished ? item.storedSizeText : nil,
      dateText: finished
        ? PutioBrowserItemPresentation.relativeDateText(for: item.createdAt, locale: locale) : nil,
      isWatched: finished && item.isWatched == true,
      showsDisclosure: false,
      downloadState: item.downloadState(
        queuePosition: queuePosition, isWaitingForSlot: queue.isWaitingForSlot(item.id)))
  }

  @ViewBuilder
  private func row(_ item: PutioOfflineItem, queuePosition: Int?) -> some View {
    let model = rowModel(item, queuePosition: queuePosition)
    Group {
      if isEditing {
        PutioFileRow(model)
          .contentShape(Rectangle())
          .accessibilityElement(children: .combine)
          .accessibilityValue(
            Text(selectedIDs.contains(item.id) ? "Selected" : "Not selected"))
      } else if item.stage == .completed {
        Button {
          if item.isPlayable { onOpen(item) } else { detailItem = item }
        } label: {
          PutioFileRow(model)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(Text(accessibilityValue(item)))
      } else {
        PutioFileRow(model) { action in
          perform(action, on: item)
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue(Text(accessibilityValue(item)))
      }
    }
    .accessibilityIdentifier("downloads.item.\(item.id.rawValue)")
    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
      Button(role: .destructive) {
        pendingRemoval = [removalTarget(item)]
      } label: {
        Label("Remove", systemImage: "trash")
      }
      .accessibilityIdentifier("downloads.remove.\(item.id.rawValue)")
    }
    .contextMenu { controls(item) }
    .swipeActions(edge: .leading, allowsFullSwipe: false) { controls(item) }
  }

  private func perform(_ action: PutioDownloadAction, on item: PutioOfflineItem) {
    switch action {
    case .pause: queue.pause(fileID: item.id)
    case .resume: queue.resume(fileID: item.id)
    case .cancel: queue.remove(fileIDs: [item.id])
    case .retry, .downloadAgain: queue.retry(fileID: item.id)
    }
  }

  @ViewBuilder
  private func controls(_ item: PutioOfflineItem) -> some View {
    switch item.stage {
    case .queued, .converting, .downloading,
      .paused where queue.isWaitingForSlot(item.id):
      Button {
        queue.pause(fileID: item.id)
      } label: {
        Label("Pause", systemImage: "pause")
      }
      .accessibilityIdentifier("downloads.pause.\(item.id.rawValue)")
    case .paused:
      Button {
        queue.resume(fileID: item.id)
      } label: {
        Label("Resume", systemImage: "play")
      }
      .accessibilityIdentifier("downloads.resume.\(item.id.rawValue)")
    case .failed(let failure) where failure.canRetry:
      Button {
        queue.retry(fileID: item.id)
      } label: {
        Label("Try again", systemImage: "arrow.counterclockwise")
      }
      .accessibilityIdentifier("downloads.retry.\(item.id.rawValue)")
    case .missing:
      Button {
        queue.retry(fileID: item.id)
      } label: {
        Label("Download again", systemImage: "arrow.down.circle")
      }
      .accessibilityIdentifier("downloads.retry.\(item.id.rawValue)")
    case .completed:
      Button {
        detailItem = item
      } label: {
        Label("Details", systemImage: "info.circle")
      }
      .accessibilityIdentifier("downloads.details.\(item.id.rawValue)")
    case .failed:
      Button(role: .destructive) {
        pendingRemoval = [removalTarget(item)]
      } label: {
        Label("Remove", systemImage: "trash")
      }
      .accessibilityIdentifier("downloads.remove.\(item.id.rawValue)")
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
            pendingRemoval = queue.items.filter { selectedIDs.contains($0.id) }.map(removalTarget)
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
          } label: {
            Label("More", systemImage: "ellipsis")
          }
          .accessibilityIdentifier("downloads.more")
        }
      }
    }
  }

  private func accessibilityValue(_ item: PutioOfflineItem) -> String {
    let marks = [
      item.waitingForNetwork == true ? "network" : nil,
      item.isRemoving == true ? "removing" : nil,
      item.isWatched == true ? "watched" : nil,
    ].compactMap(\.self)
    return ([stageValue(item)] + marks).joined(separator: ";")
  }

  private func stageValue(_ item: PutioOfflineItem) -> String {
    switch item.stage {
    case .queued: "queued"
    case .converting(let progress): "converting;\(Int(progress * 100))"
    case .downloading(let progress): "downloading;\(Int(progress * 100))"
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
    guard let failure = shown else { return [] }
    var actions = [
      PutioAlertAction(
        String(localized: "OK"), tier: .cancel, id: "downloads.save-dismiss"
      ) { [queue] in
        queue.dismissPersistenceFailure()
      }
    ]
    if failure.canRetry {
      actions.append(
        PutioAlertAction(
          String(localized: "Try again"), tier: .primary, id: "downloads.save-retry"
        ) { [queue] in
          Task {
            try? await Task.sleep(for: .milliseconds(500))
            queue.retryPersisting()
          }
        })
    }
    return actions
  }
}

/// Stored tracks and sizes for one download.
struct PutioOfflineDetailView: View {
  let item: PutioOfflineItem
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        Section {
          if let size = item.storedSizeText {
            LabeledContent("Size", value: size)
          }
          LabeledContent("Status", value: status)
        }
        Section("Audio") {
          if item.storedAudioTracks.isEmpty {
            Text("Default track").foregroundStyle(PutioTheme.Colors.textSecondary)
          }
          ForEach(item.storedAudioTracks, id: \.self) { track in
            LabeledContent(track.displayName, value: track.languageCode)
              .accessibilityIdentifier("downloads.detail.audio.\(track.languageCode)")
          }
        }
        Section("Subtitles") {
          if item.storedSubtitleTracks.isEmpty {
            Text("None stored").foregroundStyle(PutioTheme.Colors.textSecondary)
          }
          ForEach(item.storedSubtitleTracks, id: \.self) { track in
            LabeledContent(track.displayName, value: track.languageCode)
              .accessibilityIdentifier("downloads.detail.subtitle.\(track.languageCode)")
          }
        }
      }
      .putioContentBackground()
      .navigationTitle(item.name)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }.accessibilityIdentifier("downloads.detail.done")
        }
      }
      .accessibilityIdentifier("downloads.detail.\(item.id.rawValue)")
    }
  }

  private var status: String {
    switch item.stage {
    case .queued: String(localized: "Waiting")
    case .converting: String(localized: "Converting")
    case .downloading: String(localized: "Downloading")
    case .paused: String(localized: "Paused")
    case .completed: String(localized: "Downloaded")
    case .failed(let failure): failure.reason
    case .missing: String(localized: "No longer on this iPhone")
    }
  }
}

/// Completion notifications are requested from the download flow, once, and
/// only after the first item is queued.
enum PutioOfflineNotifications {
  static func requestPermissionIfNeeded(center: UNUserNotificationCenter = .current()) async {
    let settings = await center.notificationSettings()
    guard settings.authorizationStatus == .notDetermined else { return }
    _ = try? await center.requestAuthorization(options: [.alert, .sound])
  }

  static func notifyCompletion(
    _ item: PutioOfflineItem, center: UNUserNotificationCenter = .current()
  ) {
    let content = UNMutableNotificationContent()
    content.title = String(localized: "Download complete")
    content.body = String(localized: "\(item.name) is ready to play.")
    let request = UNNotificationRequest(
      identifier: "offline-\(item.id.rawValue)", content: content, trigger: nil)
    center.add(request)
  }
}
