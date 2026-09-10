import PutioCore
import SwiftUI

/// The Cast entry point for toolbars. Google's button owns discovery and the
/// picker on device; the harness controller draws a plain button that opens
/// its stub picker so journeys need no network.
struct PutioCastButton: View {
  let model: PutioCastModel

  var body: some View {
    if model.showsCastButton {
      if model.providesSystemCastButton {
        PutioGoogleCastButton()
          .frame(width: 24, height: 24)
          .accessibilityLabel(model.isConnected ? "Cast, connected" : "Cast")
      } else {
        Button {
          model.presentDevicePicker()
        } label: {
          Image(systemName: model.isConnected ? "tv.fill" : "tv")
        }
        .accessibilityLabel(model.isConnected ? "Cast, connected" : "Cast")
        .accessibilityIdentifier("cast.button")
      }
    }
  }
}

/// The persistent bar above the tab bar while a receiver has something of
/// ours: title, transport, and the route into the expanded controls.
struct PutioCastBar: View {
  let model: PutioCastModel

  var body: some View {
    HStack(spacing: PutioTheme.Spacing.space3) {
      Image(systemName: "tv")
        .foregroundStyle(PutioTheme.Colors.accent)
      VStack(alignment: .leading, spacing: 2) {
        Text(model.currentTitle ?? "Preparing…")
          .putioFont(PutioTheme.Typography.body)
          .foregroundStyle(PutioTheme.Colors.textPrimary)
          .lineLimit(1)
          .accessibilityIdentifier("cast.bar.title")
        Text(barSubtitle)
          .putioFont(PutioTheme.Typography.caption)
          .foregroundStyle(PutioTheme.Colors.textSecondary)
          .lineLimit(1)
          .accessibilityIdentifier("cast.bar.status")
      }
      Spacer(minLength: PutioTheme.Spacing.space2)
      if model.status != nil {
        Button {
          model.togglePlayback()
        } label: {
          Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
            .font(.title3)
        }
        .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
        .accessibilityIdentifier("cast.bar.toggle")
      } else if case .failed = model.activity {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(PutioTheme.Colors.destructive)
      } else {
        ProgressView()
      }
    }
    .padding(.horizontal, PutioTheme.Spacing.space4)
    .padding(.vertical, PutioTheme.Spacing.space3)
    .background(PutioTheme.Colors.surface)
    .contentShape(Rectangle())
    .onTapGesture { model.showControls() }
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(.isButton)
    .accessibilityIdentifier("cast.bar")
  }

  private var barSubtitle: String {
    let device = model.connection.deviceName ?? "Chromecast"
    switch model.activity {
    case .resolving: return "Preparing for \(device)"
    case .conversionRequired, .conversionQueued: return "Waiting to convert"
    case .converting(_, let progress):
      return "Converting \(progress.formatted(.percent.precision(.fractionLength(0))))"
    case .loading: return "Loading on \(device)"
    case .failed(_, let failure): return failure.title
    case .idle:
      switch model.status?.playerState {
      case .buffering, .loading: return "Buffering on \(device)"
      case .paused: return "Paused on \(device)"
      case .playing: return "Playing on \(device)"
      case .idle, nil: return "Connected to \(device)"
      }
    }
  }
}

/// Expanded controls: artwork, scrubber, transport, subtitles, stop, and
/// disconnect. Conversion and failure states mirror the local player's copy.
struct PutioCastControlsView: View {
  let model: PutioCastModel
  @State private var scrubPosition: Double?

  var body: some View {
    NavigationStack {
      Group {
        switch model.activity {
        case .resolving:
          PutioLoadingStateView(title: "Preparing video")
            .accessibilityIdentifier("cast.preparing")
        case .conversionRequired:
          PutioLoadingStateView(title: "Starting conversion")
            .accessibilityIdentifier("cast.conversion-required")
        case .conversionQueued:
          PutioLoadingStateView(title: "Waiting to convert")
            .accessibilityIdentifier("cast.conversion-queued")
        case .converting(_, let progress):
          VStack(spacing: PutioTheme.Spacing.space3) {
            ProgressView(value: progress)
              .tint(PutioTheme.Colors.accent)
              .accessibilityLabel("Video conversion progress")
              .accessibilityValue(progress.formatted(.percent.precision(.fractionLength(0))))
              .accessibilityIdentifier("cast.conversion-progress")
            Text("Converting video")
              .putioFont(PutioTheme.Typography.body)
              .foregroundStyle(PutioTheme.Colors.textSecondary)
          }
          .padding(PutioTheme.Spacing.space4)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loading:
          PutioLoadingStateView(title: "Loading on \(model.connection.deviceName ?? "Chromecast")")
            .accessibilityIdentifier("cast.loading")
        case .failed(_, let failure):
          PutioErrorStateView(
            title: failure.title, message: failure.message,
            retryTitle: failure.canRetry ? "Try again" : nil,
            retryIdentifier: "cast.retry",
            retry: failure.canRetry ? { model.retry() } : nil
          )
        case .idle:
          if let media = model.media {
            controls(for: media)
          } else {
            PutioEmptyStateView(
              icon: .fileVideo, title: "Nothing casting",
              message: "Pick a video to play it on \(model.connection.deviceName ?? "Chromecast")."
            )
            .accessibilityIdentifier("cast.empty")
          }
        }
      }
      .putioContentBackground()
      .navigationTitle(model.connection.deviceName ?? "Chromecast")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { model.hideControls() }
            .accessibilityIdentifier("cast.controls.done")
        }
        if model.media == nil {
          ToolbarItem(placement: .primaryAction) {
            Button("Disconnect", role: .destructive) { model.disconnect() }
              .accessibilityIdentifier("cast.disconnect")
          }
        }
      }
    }
  }

  private func controls(for media: PutioCastMedia) -> some View {
    VStack(spacing: PutioTheme.Spacing.space4) {
      AsyncImage(url: media.artworkURL) { phase in
        if let image = phase.image {
          image.resizable().aspectRatio(16 / 9, contentMode: .fit)
        } else {
          ZStack {
            PutioTheme.Colors.surface
            Image(putioIcon: .fileVideo)
              .foregroundStyle(PutioTheme.Colors.textSecondary)
          }
          .aspectRatio(16 / 9, contentMode: .fit)
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: PutioTheme.Radius.medium))
      .accessibilityHidden(true)
      Text(media.title)
        .putioFont(PutioTheme.Typography.heading)
        .foregroundStyle(PutioTheme.Colors.textPrimary)
        .lineLimit(2)
        .accessibilityIdentifier("cast.title")
      scrubber(for: media)
      HStack(spacing: PutioTheme.Spacing.space6) {
        transportButton("gobackward.30", label: "Back 30 seconds", identifier: "cast.rewind") {
          model.seek(toSeconds: (model.status?.positionSeconds ?? 0) - 30)
        }
        Button {
          model.togglePlayback()
        } label: {
          Image(systemName: model.isPlaying ? "pause.circle.fill" : "play.circle.fill")
            .font(.system(size: 56))
        }
        .disabled(model.status == nil)
        .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
        .accessibilityIdentifier("cast.toggle")
        transportButton("goforward.30", label: "Forward 30 seconds", identifier: "cast.forward") {
          model.seek(toSeconds: (model.status?.positionSeconds ?? 0) + 30)
        }
      }
      if !media.subtitles.isEmpty {
        subtitlePicker(for: media)
      } else if media.playbackType == .hls {
        Text("Subtitles are handled by the receiver for HLS streams.")
          .putioFont(PutioTheme.Typography.caption)
          .foregroundStyle(PutioTheme.Colors.textSecondary)
          .multilineTextAlignment(.center)
      }
      Spacer(minLength: 0)
      sessionActions
    }
    .padding(PutioTheme.Spacing.space4)
  }

  /// Stop keeps the device; Disconnect ends the session. Plain buttons, not
  /// a menu: they are the two things a person reaches for on this screen.
  private var sessionActions: some View {
    HStack(spacing: PutioTheme.Spacing.space3) {
      PutioButton("Stop casting", tier: .secondary) { model.stopCasting() }
        .disabled(model.media == nil)
        .accessibilityIdentifier("cast.stop")
      PutioButton("Disconnect", tier: .secondary) { model.disconnect() }
        .accessibilityIdentifier("cast.disconnect")
    }
  }

  private func transportButton(
    _ systemImage: String, label: String, identifier: String, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemImage).font(.title)
    }
    .disabled(model.status == nil)
    .accessibilityLabel(label)
    .accessibilityIdentifier(identifier)
  }

  private func scrubber(for media: PutioCastMedia) -> some View {
    let reported = model.status?.durationSeconds ?? 0
    let duration = max(reported > 0 ? reported : media.durationSeconds, 1)
    let position = scrubPosition ?? min(model.status?.positionSeconds ?? 0, duration)
    return VStack(spacing: PutioTheme.Spacing.space1) {
      Slider(
        value: Binding(get: { position }, set: { scrubPosition = $0 }),
        in: 0...duration
      ) { editing in
        guard !editing, let target = scrubPosition else { return }
        model.seek(toSeconds: target)
        scrubPosition = nil
      }
      .tint(PutioTheme.Colors.accent)
      .disabled(model.status == nil)
      .accessibilityLabel("Playback position")
      .accessibilityValue(Self.clock(position))
      .accessibilityIdentifier("cast.position")
      HStack {
        Text(Self.clock(position))
        Spacer()
        Text(Self.clock(duration))
      }
      .putioFont(PutioTheme.Typography.caption)
      .foregroundStyle(PutioTheme.Colors.textSecondary)
      .monospacedDigit()
    }
  }

  private func subtitlePicker(for media: PutioCastMedia) -> some View {
    Picker(
      "Subtitles",
      selection: Binding(
        get: { model.status?.activeSubtitleKey ?? "" },
        set: { model.selectSubtitle(key: $0.isEmpty ? nil : $0) })
    ) {
      Text("Off").tag("")
      ForEach(media.subtitles, id: \.key) { subtitle in
        Text("\(subtitle.language) · \(subtitle.name)").tag(subtitle.key)
      }
    }
    .pickerStyle(.menu)
    .disabled(model.status == nil)
    .accessibilityIdentifier("cast.subtitles")
    .accessibilityValue(activeSubtitleName(in: media))
  }

  /// VoiceOver reads the language, not the server key; the journey asserts
  /// the same string.
  private func activeSubtitleName(in media: PutioCastMedia) -> String {
    guard let key = model.status?.activeSubtitleKey,
      let subtitle = media.subtitles.first(where: { $0.key == key })
    else { return "Off" }
    return subtitle.language
  }

  static func clock(_ seconds: Double) -> String {
    let total = Int(seconds.rounded(.down))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    return hours > 0
      ? String(format: "%d:%02d:%02d", hours, minutes, secs)
      : String(format: "%d:%02d", minutes, secs)
  }
}

/// The feature-owned Chromecast settings: the server-side playback type and
/// the local receiver override. Account settings link here.
struct PutioCastPreferencesView: View {
  let model: PutioCastModel
  @State private var receiverDraft: String
  @State private var receiverOverride: String?
  @State private var receiverError: String?
  private let bundledAppID: String
  private let defaults: UserDefaults

  init(model: PutioCastModel, defaults: UserDefaults = .standard) {
    self.model = model
    self.defaults = defaults
    bundledAppID = PutioCastReceiver.bundledAppID()
    let override = PutioCastReceiver.storedOverride(defaults: defaults)
    _receiverOverride = State(initialValue: override)
    _receiverDraft = State(initialValue: override ?? "")
  }

  var body: some View {
    Form {
      Section {
        if let playbackType = model.playbackType {
          PutioPickerRow(
            title: "Playback type",
            selection: Binding(
              get: { playbackType },
              set: { newValue in
                guard newValue != playbackType else { return }
                Task { await model.savePlaybackType(newValue) }
              }),
            options: PutioCastPlaybackType.allCases
          ) { $0 == .hls ? "HLS" : "MP4" }
          .disabled(model.isSavingPlaybackType)
          .accessibilityIdentifier("cast-settings.playback-type")
          .accessibilityValue(playbackType == .hls ? "HLS" : "MP4")
        } else if let failure = model.playbackTypeFailure {
          Text(failure).foregroundStyle(PutioTheme.Colors.textSecondary)
          Button("Try again") { Task { await model.loadPlaybackTypeIfNeeded(force: true) } }
            .accessibilityIdentifier("cast-settings.retry")
        } else {
          ProgressView("Loading playback type")
        }
        if model.playbackType != nil, let failure = model.playbackTypeFailure {
          Text(failure).foregroundStyle(PutioTheme.Colors.textSecondary)
            .accessibilityIdentifier("cast-settings.save-failure")
        }
      } header: {
        Text("Chromecast")
      } footer: {
        Text(
          "HLS streams the original file with put.io subtitles. MP4 casts the converted file and lets you switch subtitles on the receiver."
        )
      }
      .listRowBackground(PutioTheme.Colors.surface)
      Section {
        PutioFormField(
          label: "Receiver app ID", placeholder: bundledAppID, text: $receiverDraft,
          errorText: receiverError
        )
        .textInputAutocapitalization(.characters)
        .autocorrectionDisabled()
        .accessibilityIdentifier("cast-settings.receiver")
        .onChange(of: receiverDraft) { _, _ in receiverError = nil }
        Button("Save receiver") { saveReceiver() }
          .disabled(PutioCastReceiver.normalized(receiverDraft) == (receiverOverride ?? ""))
          .accessibilityIdentifier("cast-settings.receiver.save")
        if receiverOverride != nil {
          Button("Use default receiver", role: .destructive) {
            receiverDraft = ""
            saveReceiver()
          }
          .accessibilityIdentifier("cast-settings.receiver.reset")
        }
      } header: {
        Text("Receiver")
      } footer: {
        Text(
          receiverOverride == nil
            ? "Using the built-in receiver. A custom receiver applies the next time the app launches."
            : "Custom receiver \(receiverOverride ?? "") applies the next time the app launches."
        )
        .accessibilityIdentifier("cast-settings.receiver.footer")
      }
      .listRowBackground(PutioTheme.Colors.surface)
    }
    .navigationTitle("Chromecast")
    .putioFont(PutioTheme.Typography.body)
    .putioContentBackground()
    .task { await model.loadPlaybackTypeIfNeeded() }
  }

  private func saveReceiver() {
    let candidate = PutioCastReceiver.normalized(receiverDraft)
    if candidate.isEmpty {
      defaults.removeObject(forKey: PutioCastReceiver.overrideKey)
      receiverOverride = nil
      receiverDraft = ""
      receiverError = nil
      return
    }
    guard PutioCastReceiver.isValid(candidate) else {
      receiverError = "Enter the 8-character receiver app ID."
      return
    }
    defaults.set(candidate, forKey: PutioCastReceiver.overrideKey)
    receiverOverride = candidate
    receiverDraft = candidate
    receiverError = nil
  }
}
