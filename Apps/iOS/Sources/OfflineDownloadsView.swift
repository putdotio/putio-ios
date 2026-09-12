import PutioCore
import SwiftUI
import UserNotifications

/// The Downloads screen: storage accounting, the queue with per-item
/// progress and controls, multi-select delete, and the concurrency limit.
struct PutioOfflineDownloadsView: View {
  let queue: PutioOfflineQueue
  let trashEnabled: Bool
  let onOpen: @MainActor (PutioOfflineItem) -> Void
  /// Originals put.io confirmed gone, so loaded file lists can reconcile.
  let onOriginalsDeleted: @MainActor ([PutioFileID]) -> Void

  @State private var isEditing = false
  @State private var selectedIDs: Set<PutioFileID> = []
  @State private var pendingRemoval: [PutioOfflineRemovalTarget]?
  @State private var detailItem: PutioOfflineItem?

  private var copy: PutioOfflineRemovalCopy { PutioOfflineRemovalCopy(trashEnabled: trashEnabled) }

  var body: some View {
    Group {
      if queue.items.isEmpty {
        PutioEmptyStateView(
          icon: .arrowCircleDown, title: "No downloads",
          message: "Files you download for offline playback appear here."
        )
        .accessibilityIdentifier("downloads.empty")
      } else {
        list
      }
    }
    .putioContentBackground()
    .navigationTitle("Downloads")
    .toolbar { toolbar }
    .environment(\.editMode, .constant(isEditing ? .active : .inactive))
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
        // Unstructured on purpose: the request outlives this screen, and the
        // queue keeps the outcome until the user dismisses it.
        Task { deliver(await queue.removeDeletingOriginals(fileIDs: targets.map(\.id))) }
      }
      .accessibilityIdentifier("downloads.remove-original")
      Button("Cancel", role: .cancel) {}
    } message: { targets in
      Text(copy.message(count: targets.count))
    }
    .alert(
      copy.failureTitle(outcome: queue.originalFailure ?? PutioOfflineOriginalOutcome()),
      isPresented: Binding(
        get: { queue.originalFailure != nil }, set: { if !$0 { queue.dismissOriginalFailure() } }),
      presenting: queue.originalFailure
    ) { outcome in
      Button("Try again") {
        Task { deliver(await queue.deleteOriginals(outcome.failedTargets)) }
      }
      .accessibilityIdentifier("downloads.remove-original-retry")
      Button("OK", role: .cancel) {}
    } message: { outcome in
      Text(copy.failureMessage(outcome: outcome))
    }
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

  private func deliver(_ outcome: PutioOfflineOriginalOutcome) {
    guard !outcome.deleted.isEmpty else { return }
    onOriginalsDeleted(outcome.deleted.map(\.id))
  }

  private func finishSelection() {
    selectedIDs = []
    isEditing = false
  }

  private var list: some View {
    List(selection: isEditing ? $selectedIDs : nil) {
      Section {
        LabeledContent("Downloaded", value: byteText(queue.storedBytes))
          .accessibilityIdentifier("downloads.storage-used")
        LabeledContent("Free on device", value: byteText(queue.availableBytes))
        if queue.pendingPositionCount > 0 {
          LabeledContent("Positions waiting to sync", value: "\(queue.pendingPositionCount)")
            .accessibilityElement(children: .combine)
            .accessibilityValue("\(queue.pendingPositionCount)")
            .accessibilityIdentifier("downloads.pending-positions")
        }
      } header: {
        Text("Storage")
      }
      Section {
        Picker("Simultaneous downloads", selection: concurrency) {
          ForEach(PutioOfflineQueue.concurrencyLimits, id: \.self) { Text("\($0)").tag($0) }
        }
        .accessibilityIdentifier("downloads.concurrency")
      }
      Section {
        ForEach(queue.items) { item in
          row(item)
            .tag(item.id)
        }
      } header: {
        Text("Queue")
      }
    }
    .listStyle(.insetGrouped)
  }

  @ViewBuilder
  private func row(_ item: PutioOfflineItem) -> some View {
    let row = PutioFileRowModel(
      name: item.name, kind: item.kind == .video ? .video : .audio,
      sizeText: subtitle(item))
    Group {
      if isEditing {
        rowContent(item, row)
          .contentShape(Rectangle())
          .accessibilityElement(children: .combine)
          .accessibilityValue(
            Text(selectedIDs.contains(item.id) ? "Selected" : "Not selected"))
      } else {
        Button {
          if item.isPlayable { onOpen(item) } else { detailItem = item }
        } label: {
          rowContent(item, row)
        }
        .buttonStyle(.plain)
        .accessibilityValue(Text(accessibilityValue(item)))
      }
    }
    .accessibilityIdentifier("downloads.item.\(item.id.rawValue)")
    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
      Button(role: .destructive) {
        pendingRemoval = [PutioOfflineRemovalTarget(id: item.id, name: item.name)]
      } label: {
        Label("Remove", systemImage: "trash")
      }
      .accessibilityIdentifier("downloads.remove.\(item.id.rawValue)")
    }
    .contextMenu { controls(item) }
    .swipeActions(edge: .leading, allowsFullSwipe: false) { controls(item) }
  }

  private func rowContent(_ item: PutioOfflineItem, _ row: PutioFileRowModel) -> some View {
    VStack(alignment: .leading, spacing: PutioTheme.Spacing.space2) {
      PutioFileRow(row)
      if item.isActive || item.stage == .queued {
        ProgressView(value: item.progress)
          .tint(PutioTheme.Colors.accent)
          .accessibilityHidden(true)
      }
    }
  }

  @ViewBuilder
  private func controls(_ item: PutioOfflineItem) -> some View {
    switch item.stage {
    case .queued, .converting, .downloading:
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
        Label(
          queue.isWaitingForSlot(item.id) ? "Waiting for a slot" : "Resume", systemImage: "play")
      }
      .disabled(queue.isWaitingForSlot(item.id))
      .accessibilityIdentifier("downloads.resume.\(item.id.rawValue)")
    case .failed(let failure) where failure.canRetry:
      Button {
        queue.retry(fileID: item.id)
      } label: {
        Label("Try again", systemImage: "arrow.counterclockwise")
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
        pendingRemoval = [PutioOfflineRemovalTarget(id: item.id, name: item.name)]
      } label: {
        Label("Remove", systemImage: "trash")
      }
      .accessibilityIdentifier("downloads.remove.\(item.id.rawValue)")
    }
  }

  @ToolbarContentBuilder
  private var toolbar: some ToolbarContent {
    if !queue.items.isEmpty {
      ToolbarItem(placement: .primaryAction) {
        Button(isEditing ? "Done" : "Select") {
          isEditing.toggle()
          if !isEditing { selectedIDs = [] }
        }
        .accessibilityIdentifier("downloads.select")
      }
      if isEditing {
        ToolbarItem(placement: .topBarLeading) {
          Button("Remove \(selectedIDs.count)", role: .destructive) {
            pendingRemoval = queue.items.filter { selectedIDs.contains($0.id) }.map {
              PutioOfflineRemovalTarget(id: $0.id, name: $0.name)
            }
          }
          .disabled(selectedIDs.isEmpty)
          .accessibilityIdentifier("downloads.remove-selected")
        }
      }
    }
  }

  private var concurrency: Binding<Int> {
    Binding(get: { queue.concurrencyLimit }, set: { queue.setConcurrencyLimit($0) })
  }

  private func subtitle(_ item: PutioOfflineItem) -> String {
    switch item.stage {
    case .queued: "Waiting"
    case .converting(let progress): "Converting · \(percent(progress))"
    case .downloading(let progress): "Downloading · \(percent(progress))"
    case .paused(let progress):
      queue.isWaitingForSlot(item.id)
        ? "Waiting for a slot · \(percent(progress))" : "Paused · \(percent(progress))"
    case .completed: byteText(item.storedBytes)
    case .failed(let failure): failure.message
    }
  }

  private func accessibilityValue(_ item: PutioOfflineItem) -> String {
    switch item.stage {
    case .queued: "queued"
    case .converting(let progress): "converting;\(Int(progress * 100))"
    case .downloading(let progress): "downloading;\(Int(progress * 100))"
    case .paused(let progress): "paused;\(Int(progress * 100))"
    case .completed: "completed"
    case .failed(let failure): "failed;\(failure.kind.rawValue)"
    }
  }

  private func percent(_ value: Double) -> String {
    value.formatted(.percent.precision(.fractionLength(0)))
  }

  private func byteText(_ bytes: Int64) -> String {
    bytes.formatted(ByteCountFormatStyle(style: .file))
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
          LabeledContent(
            "Size", value: item.storedBytes.formatted(ByteCountFormatStyle(style: .file)))
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
    case .queued: "Waiting"
    case .converting: "Converting"
    case .downloading: "Downloading"
    case .paused: "Paused"
    case .completed: "Downloaded"
    case .failed(let failure): failure.message
    }
  }
}

/// The pre-download sheet: language inventory, bounded multi-select, and the
/// storage estimate. Audio files and single-track videos skip it.
struct PutioOfflineTrackPickerView: View {
  let name: String
  let inventory: PutioOfflineInventory
  let availableBytes: Int64
  let onConfirm: @MainActor ([String]) -> Void
  let onCancel: @MainActor () -> Void

  @State private var selected: [String]

  init(
    name: String, inventory: PutioOfflineInventory, availableBytes: Int64,
    preferredLanguages: [String] = Locale.preferredLanguages,
    onConfirm: @escaping @MainActor ([String]) -> Void, onCancel: @escaping @MainActor () -> Void
  ) {
    self.name = name
    self.inventory = inventory
    self.availableBytes = availableBytes
    self.onConfirm = onConfirm
    self.onCancel = onCancel
    let stored = inventory.audioOptions.map {
      PutioOfflineTrack(languageCode: $0.languageCode, displayName: $0.displayName)
    }
    let preferred = PutioOfflineLanguage.preferred(
      from: stored, preferredLanguages: preferredLanguages)
    _selected = State(initialValue: preferred.map { [$0.languageCode] } ?? [])
  }

  private var estimate: Int64 { inventory.estimatedBytes(selecting: selected) }
  private var overBudget: Bool {
    !PutioOfflineQueue.fits(estimatedBytes: estimate, freeBytes: availableBytes)
  }

  var body: some View {
    NavigationStack {
      List {
        Section {
          ForEach(inventory.audioOptions) { option in
            Toggle(isOn: binding(option.languageCode)) {
              LabeledContent(
                option.displayName,
                value: option.estimatedBytes.formatted(ByteCountFormatStyle(style: .file)))
            }
            .accessibilityIdentifier("downloads.track.\(option.languageCode)")
          }
        } header: {
          Text("Audio languages")
        } footer: {
          Text("Every selected language is stored and can be switched while offline.")
        }
        Section {
          LabeledContent(
            "Estimated size", value: estimate.formatted(ByteCountFormatStyle(style: .file))
          )
          .accessibilityIdentifier("downloads.estimate")
          LabeledContent(
            "Free on device", value: availableBytes.formatted(ByteCountFormatStyle(style: .file)))
          if overBudget {
            Text("This selection does not fit. Deselect a language or free up space.")
              .foregroundStyle(PutioTheme.Colors.destructive)
              .accessibilityIdentifier("downloads.over-budget")
          }
        }
      }
      .putioContentBackground()
      .navigationTitle(name)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { onCancel() }.accessibilityIdentifier("downloads.picker.cancel")
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Download") { onConfirm(selected) }
            .disabled(selected.isEmpty || overBudget)
            .accessibilityIdentifier("downloads.picker.confirm")
        }
      }
    }
  }

  private func binding(_ code: String) -> Binding<Bool> {
    Binding(
      get: { selected.contains(code) },
      set: { on in
        if on {
          if !selected.contains(code) { selected.append(code) }
        } else {
          selected.removeAll { $0 == code }
        }
      })
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
    content.title = "Download complete"
    content.body = item.name
    let request = UNNotificationRequest(
      identifier: "offline-\(item.id.rawValue)", content: content, trigger: nil)
    center.add(request)
  }
}
