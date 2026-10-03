import AVFoundation
import AVKit
import PutioCore
import SwiftUI

/// One playback from a file row, kept on screen across episodic
/// continuation: a successor replaces the finished video in place, and
/// leaving the screen ends the session.
struct TVVideoSession: View {
  let runtime: PutioRuntime
  let account: PutioAccountSnapshot
  let pipeline: PutioPlaybackPositionPipeline
  let refreshRequests: PutioFolderRefreshRequests

  @Environment(\.dismiss) private var dismiss
  @State private var route: PutioVideoRoute

  init(
    route: PutioVideoRoute, runtime: PutioRuntime, account: PutioAccountSnapshot,
    pipeline: PutioPlaybackPositionPipeline, refreshRequests: PutioFolderRefreshRequests
  ) {
    self.runtime = runtime
    self.account = account
    self.pipeline = pipeline
    self.refreshRequests = refreshRequests
    _route = State(initialValue: route)
  }

  var body: some View {
    TVVideoPlaybackView(
      route: route, runtime: runtime, account: account, pipeline: pipeline,
      onPlayNext: { route = PutioVideoRoute(nextVideo: $0) },
      // A row shows its watched state once the player's last report
      // landed; the folder's own refresh on reappearing can run before it.
      onPlayerReportsSettled: { [refreshRequests] finished in
        refreshRequests.request(folderID: finished.parentID)
      },
      onFinish: { dismiss() }
    )
    .id(route.id)
  }
}

/// What the screen shows once the source resolved.
private enum TVPlaybackStage {
  case measuring
  case asking(AVPlayerItem, PutioVideoResumePrompt)
  case playing(AVPlayerItem, startSeconds: Int)
  case ended
}

/// The video screen: conversion gate, pre-play resume decision, the system
/// player, and the successor once it ends. State comes from the shared
/// playback models; this screen owns presentation and remote input.
struct TVVideoPlaybackView: View {
  @State private var model: PutioVideoPlaybackModel
  @State private var nextVideoModel: PutioNextVideoModel
  @State private var stage: TVPlaybackStage = .measuring
  @State private var retrySequence: UInt64 = 0
  @State private var probes = TVPlaybackProbes()
  @State private var nextVideoTask: Task<Void, Never>?

  private let route: PutioVideoRoute
  private let remembersPosition: Bool
  private let pipeline: PutioPlaybackPositionPipeline
  private let runtime: PutioRuntime
  private let showsProbes: Bool
  private let onPlayNext: @MainActor (PutioPlayableNextVideo) -> Void
  private let onPlayerReportsSettled: @MainActor (PutioVideoRoute) -> Void
  private let onFinish: @MainActor () -> Void

  init(
    route: PutioVideoRoute, runtime: PutioRuntime, account: PutioAccountSnapshot,
    pipeline: PutioPlaybackPositionPipeline,
    onPlayNext: @escaping @MainActor (PutioPlayableNextVideo) -> Void,
    onPlayerReportsSettled: @escaping @MainActor (PutioVideoRoute) -> Void,
    onFinish: @escaping @MainActor () -> Void
  ) {
    let media = TVPlaybackMedia(runtime: runtime, account: account)
    self.route = route
    self.remembersPosition = account.rememberVideoTime
    self.pipeline = pipeline
    self.runtime = runtime
    self.showsProbes = media.isHarness
    self.onPlayNext = onPlayNext
    self.onPlayerReportsSettled = onPlayerReportsSettled
    self.onFinish = onFinish
    _model = State(
      initialValue: PutioVideoPlaybackModel(
        fileID: route.id,
        initialResolution: route.initialResolution,
        conversionPollInterval: media.isHarness ? .milliseconds(1_200) : .seconds(3),
        startConversion: { try await runtime.startVideoConversion(fileID: $0) },
        loadConversionStatus: { try await runtime.videoConversionStatus(fileID: $0) }
      ) { fileID in
        await pipeline.waitForPendingReports(fileID: fileID)
        return try await media.resolve(fileID)
      })
    _nextVideoModel = State(
      initialValue: PutioNextVideoModel(
        suggestionsEnabled: account.suggestNextVideo,
        autoplayEnabled: { (try? await runtime.appConfig().autoplayNextVideo) ?? false },
        waitForReset: { await pipeline.waitForPendingReports(fileID: $0) },
        loadNext: { fileID in
          try await prepareNextVideo(
            after: fileID,
            findNext: { try await runtime.findNextVideo(after: $0) },
            waitForPendingReports: { await pipeline.waitForPendingReports(fileID: $0) },
            resolve: { try await media.resolve($0) })
        }))
  }

  private var readySource: PutioPlaybackSource? {
    if case .ready(let source) = model.state { return source }
    return nil
  }

  var body: some View {
    content
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.black.ignoresSafeArea())
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("video.screen.\(route.id.rawValue)")
      .task { await model.loadIfNeeded() }
      .task(id: retrySequence) {
        guard retrySequence > 0 else { return }
        await model.retry()
      }
      .task(id: readySource) {
        guard let source = readySource else { return }
        await prepare(source)
      }
      .onChange(of: model.state) { _, state in probes.record(state) }
      .onChange(of: nextVideoModel.state) { _, state in
        // A cancel is the Cancel button's own; the one from leaving the
        // screen must not close the screen under it.
        switch state {
        case .playing(let next): onPlayNext(next)
        case .unavailable: onFinish()
        case .idle, .loading, .available, .cancelled: break
        }
      }
      .onDisappear {
        nextVideoTask?.cancel()
        nextVideoTask = nil
        nextVideoModel.cancel()
      }
      .overlay {
        if showsProbes { TVPlaybackProbeView(probes: probes) }
      }
  }

  @ViewBuilder
  private var content: some View {
    switch model.state {
    case .loading:
      PutioLoadingStateView(title: "Preparing video")
        .accessibilityIdentifier("video.loading")
    case .conversionRequired, .conversionQueued, .converting, .conversionCompleted:
      TVConversionStatusView(state: model.state)
    case .failed(let failure):
      PutioErrorStateView(
        title: failure.title, message: failure.message, retryTitle: "Try again",
        retryIdentifier: "video.retry"
      ) {
        retrySequence &+= 1
      }

    case .ready:
      readyContent
    }
  }

  @ViewBuilder
  private var readyContent: some View {
    switch stage {
    case .measuring:
      PutioLoadingStateView(title: "Preparing video")
        .accessibilityIdentifier("video.preparing")
    case .asking(let item, let prompt):
      TVResumePromptView(fileName: route.title, prompt: prompt) { choice in
        stage = .playing(item, startSeconds: prompt.startSeconds(for: choice))
      }
    case .playing(let item, let startSeconds):
      TVSystemVideoPlayer(
        item: item, fileID: route.id, startSeconds: startSeconds,
        remembersPosition: remembersPosition, pipeline: pipeline,
        reportPosition: { [runtime] fileID, seconds in
          try await runtime.reportPlaybackPosition(fileID: fileID, seconds: seconds)
        },
        probes: showsProbes ? probes : nil,
        onEnded: playbackEnded,
        onReportsSettled: { [route, onPlayerReportsSettled] in onPlayerReportsSettled(route) },
        onFailure: { model.playerFailed() }
      )
      .ignoresSafeArea()
    case .ended:
      TVNextVideoStage(model: nextVideoModel) {
        nextVideoModel.cancel()
        onFinish()
      }
    }
  }

  /// Loads the stream's duration for the resume decision; the same item then
  /// plays, so the manifest is not fetched twice.
  private func prepare(_ source: PutioPlaybackSource) async {
    stage = .measuring
    probes.resumePosition = source.startFromSeconds
    let asset = AVURLAsset(url: source.url)
    let item = Self.playerItem(asset: asset, title: route.title)
    let duration = try? await asset.load(.duration)
    guard !Task.isCancelled else { return }
    let seconds = duration.map(CMTimeGetSeconds)
    if let prompt = PutioVideoResumePrompt(
      startFromSeconds: source.startFromSeconds, durationSeconds: seconds,
      remembersPosition: remembersPosition)
    {
      stage = .asking(item, prompt)
    } else {
      stage = .playing(
        item, startSeconds: remembersPosition ? source.startFromSeconds : 0)
    }
  }

  /// The system player shows the item's title over its transport bar and in
  /// its Info panel; the shipped app names the file there.
  static func playerItem(asset: AVAsset, title: String) -> AVPlayerItem {
    let item = AVPlayerItem(asset: asset)
    let titleMetadata = AVMutableMetadataItem()
    titleMetadata.identifier = .commonIdentifierTitle
    titleMetadata.value = title as NSString
    titleMetadata.extendedLanguageTag = "und"
    item.externalMetadata = [titleMetadata]
    return item
  }

  private func playbackEnded() {
    probes.ended = true
    stage = .ended
    let completed = route.id
    nextVideoTask?.cancel()
    nextVideoTask = Task { @MainActor in
      await nextVideoModel.playbackEnded(completedFileID: completed)
    }
  }
}

/// The source a TV playback resolves. Debug harness runs swap the stream
/// for the loopback fixture the journey serves.
@MainActor
struct TVPlaybackMedia {
  let runtime: PutioRuntime
  let account: PutioAccountSnapshot

  var isHarness: Bool {
    #if DEBUG
      TVHarnessMedia.current != nil
    #else
      false
    #endif
  }

  func resolve(_ fileID: PutioFileID) async throws -> PutioPlaybackResolution {
    let resolution = try await runtime.resolveVideoPlaybackSource(fileID: fileID)
    #if DEBUG
      if let harness = TVHarnessMedia.current {
        return harness.substituting(resolution, account: account)
      }
    #endif
    return resolution
  }
}

/// The pre-play decision of the `tvos-s03-continue-watching` contract: the
/// raw filename, a progress preview of the focused choice, and two stacked
/// buttons with the system focus. Continue takes the first focus; Menu
/// leaves the screen like any pushed screen.
struct TVResumePromptView: View {
  let fileName: String
  let prompt: PutioVideoResumePrompt
  var initialChoice: PutioVideoResumePrompt.Choice = .resume
  let choose: (PutioVideoResumePrompt.Choice) -> Void

  @FocusState private var focusedChoice: PutioVideoResumePrompt.Choice?

  private var previewedChoice: PutioVideoResumePrompt.Choice {
    focusedChoice ?? initialChoice
  }

  var body: some View {
    VStack(spacing: 0) {
      Text("Continue watching")
        .putioFont(PutioTheme.TV.Typography.label)
        .foregroundStyle(PutioTheme.TV.Colors.textPrimary)
        .accessibilityAddTraits(.isHeader)
      Text(fileName)
        .putioFont(PutioTheme.TV.Typography.caption)
        .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, TVResumePromptLayout.titleGap)
        .accessibilityIdentifier("video.resume.file-name")
      TVResumeProgress(fraction: prompt.progress(for: previewedChoice))
        .padding(.top, TVResumePromptLayout.progressGap)
      VStack(spacing: TVResumePromptLayout.buttonGap) {
        choiceButton(
          prompt.resumeTitle, choice: .resume,
          accessibilityLabel: prompt.resumeAccessibilityLabel,
          identifier: "video.resume.continue")
        choiceButton(
          PutioVideoResumePrompt.startOverTitle, choice: .startOver,
          accessibilityLabel: PutioVideoResumePrompt.startOverTitle,
          identifier: "video.resume.start-over")
      }
      .frame(width: TVResumePromptLayout.buttonWidth)
      .padding(.top, TVResumePromptLayout.buttonsGap)
      .focusSection()
    }
    .frame(width: TVResumePromptLayout.width)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(TVResumePromptLayout.backdrop.ignoresSafeArea())
    .defaultFocus($focusedChoice, initialChoice)
  }

  private func choiceButton(
    _ title: String, choice: PutioVideoResumePrompt.Choice, accessibilityLabel: String,
    identifier: String
  ) -> some View {
    Button {
      choose(choice)
    } label: {
      Text(title)
        .putioFont(PutioTheme.TV.Typography.body)
        .frame(maxWidth: .infinity)
    }
    .buttonStyle(.bordered)
    // The system focus fill: a white pill with dark text, not the accent.
    .tint(nil)
    .focused($focusedChoice, equals: choice)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityIdentifier(identifier)
  }
}

private struct TVResumeProgress: View {
  let fraction: Double

  var body: some View {
    ZStack(alignment: .leading) {
      Capsule().fill(PutioTheme.Colors.surfaceActive)
      Capsule()
        .fill(PutioTheme.Colors.accent)
        .frame(width: TVResumePromptLayout.progressWidth * fraction)
    }
    .frame(width: TVResumePromptLayout.progressWidth, height: TVResumePromptLayout.progressHeight)
    .animation(.easeOut(duration: 0.1), value: fraction)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Watched")
    .accessibilityValue(fraction.formatted(.percent.precision(.fractionLength(0))))
    .accessibilityIdentifier("video.resume.progress")
  }
}

/// Geometry from the contract; only the yellow elapsed segment carries a
/// put.io colour.
enum TVResumePromptLayout {
  static let width: CGFloat = 960
  static let titleGap: CGFloat = 20
  static let progressGap: CGFloat = 36
  static let progressWidth: CGFloat = 640
  static let progressHeight: CGFloat = 8
  static let buttonsGap: CGFloat = 48
  static let buttonGap: CGFloat = 24
  static let buttonWidth: CGFloat = 720
  static var backdrop: some View {
    PutioTheme.Colors.background.overlay(Color.black.opacity(0.45))
  }
}

/// The conversion gate under app.put.io's explanation, as the browser row
/// and the phone show it.
struct TVConversionStatusView: View {
  let state: PutioVideoPlaybackState

  @Environment(\.locale) private var locale

  var body: some View {
    VStack(spacing: PutioTheme.TV.Spacing.medium) {
      Text(PutioVideoPlaybackState.conversionExplanation)
        .putioFont(PutioTheme.TV.Typography.body)
        .foregroundStyle(PutioTheme.TV.Colors.textPrimary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("conversion.explanation")
      status
    }
    .frame(maxWidth: TVConversionLayout.width)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .tvOverscanPadding()
  }

  @ViewBuilder
  private var status: some View {
    switch state {
    case .converting(let progress):
      VStack(spacing: PutioTheme.TV.Spacing.small) {
        ProgressView(value: progress)
          .tint(PutioTheme.Colors.accent)
          .frame(width: TVConversionLayout.progressWidth)
          .accessibilityLabel("Video conversion progress")
          .accessibilityValue(percent(progress))
          .accessibilityIdentifier("video.conversion-progress")
        Text("Converting video \(percent(progress))")
          .putioFont(PutioTheme.TV.Typography.caption)
          .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
          .monospacedDigit()
      }
    case .conversionQueued:
      PutioLoadingStateView(title: "Waiting to convert")
        .accessibilityIdentifier("video.conversion-queued")
    case .conversionCompleted:
      PutioLoadingStateView(title: "Finishing conversion")
        .accessibilityIdentifier("video.conversion-completed")
    case .conversionRequired, .loading, .ready, .failed:
      PutioLoadingStateView(title: "Starting conversion")
        .accessibilityIdentifier("video.conversion-required")
    }
  }
}

extension TVConversionStatusView {
  fileprivate func percent(_ progress: Double) -> String {
    progress.formatted(.percent.precision(.fractionLength(0)).locale(locale))
  }
}

enum TVConversionLayout {
  static let width: CGFloat = 1200
  static let progressWidth: CGFloat = 640
}

/// After the end: the successor with its countdown, or nothing while the
/// shared model looks for one. No successor ends the screen.
private struct TVNextVideoStage: View {
  let model: PutioNextVideoModel
  let cancel: () -> Void

  var body: some View {
    switch model.state {
    case .available(let next):
      TVUpNextView(
        nextVideo: next.video, autoplaySecondsRemaining: model.autoplaySecondsRemaining,
        onPlay: { model.playNext() }, onCancel: cancel)
    case .idle, .loading, .playing, .cancelled, .unavailable:
      PutioLoadingStateView(title: "Finding the next video")
        .accessibilityIdentifier("video.next-loading")
    }
  }
}

struct TVUpNextView: View {
  let nextVideo: PutioNextVideo
  var autoplaySecondsRemaining: Int?
  let onPlay: () -> Void
  let onCancel: () -> Void

  private enum Action { case play, cancel }
  @FocusState private var focusedAction: Action?

  var body: some View {
    VStack(spacing: 0) {
      Text("Up next")
        .putioFont(PutioTheme.TV.Typography.label)
        .foregroundStyle(PutioTheme.TV.Colors.textPrimary)
        .accessibilityAddTraits(.isHeader)
      Text(nextVideo.name)
        .putioFont(PutioTheme.TV.Typography.caption)
        .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, TVResumePromptLayout.titleGap)
        .accessibilityLabel("Up next, \(nextVideo.name)")
        .accessibilityIdentifier("video.next-title")
      if let autoplaySecondsRemaining {
        Text(
          "Playing in \(Duration.seconds(autoplaySecondsRemaining).formatted(.units(allowed: [.seconds], width: .wide)))"
        )
        .putioFont(PutioTheme.TV.Typography.caption)
        .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
        .monospacedDigit()
        .padding(.top, TVResumePromptLayout.titleGap)
        .accessibilityIdentifier("video.next-countdown")
      }
      VStack(spacing: TVResumePromptLayout.buttonGap) {
        actionButton("Play next", action: .play, perform: onPlay)
          .accessibilityLabel("Play next, \(nextVideo.name)")
          .accessibilityIdentifier("video.play-next")
        actionButton("Cancel", action: .cancel, perform: onCancel)
          .accessibilityLabel("Cancel playing \(nextVideo.name)")
          .accessibilityIdentifier("video.cancel-next")
      }
      .frame(width: TVResumePromptLayout.buttonWidth)
      .padding(.top, TVResumePromptLayout.buttonsGap)
      .focusSection()
    }
    .frame(width: TVResumePromptLayout.width)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(TVResumePromptLayout.backdrop.ignoresSafeArea())
    .defaultFocus($focusedAction, .play)
  }

  private func actionButton(
    _ title: String, action: Action, perform: @escaping () -> Void
  ) -> some View {
    Button(action: perform) {
      Text(title)
        .putioFont(PutioTheme.TV.Typography.body)
        .frame(maxWidth: .infinity)
    }
    .buttonStyle(.bordered)
    .tint(nil)
    .focused($focusedAction, equals: action)
  }
}

/// The system player. Transport, info panels, subtitles, audio, and speed
/// are AVKit's own; the coordinator only starts it at the chosen position
/// and reports positions.
private struct TVSystemVideoPlayer: UIViewControllerRepresentable {
  let item: AVPlayerItem
  let fileID: PutioFileID
  let startSeconds: Int
  let remembersPosition: Bool
  let pipeline: PutioPlaybackPositionPipeline
  let reportPosition: PutioPlaybackPositionReport
  let probes: TVPlaybackProbes?
  let onEnded: @MainActor () -> Void
  let onReportsSettled: @MainActor () -> Void
  let onFailure: @MainActor () -> Void

  func makeCoordinator() -> TVVideoPlayerCoordinator {
    TVVideoPlayerCoordinator()
  }

  func makeUIViewController(context: Context) -> AVPlayerViewController {
    let controller = AVPlayerViewController()
    let probes = probes
    let report = reportPosition
    context.coordinator.start(
      item: item, fileID: fileID, startSeconds: startSeconds,
      remembersPosition: remembersPosition, pipeline: pipeline,
      reportPosition: { fileID, seconds in
        try await report(fileID, seconds)
        probes?.reportedPosition = "id=\(fileID.rawValue);seconds=\(seconds)"
      },
      in: controller, probes: probes, onEnded: onEnded, onReportsSettled: onReportsSettled,
      onFailure: onFailure)
    controller.view.accessibilityIdentifier = "video.system-player"
    return controller
  }

  func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}

  static func dismantleUIViewController(
    _ controller: AVPlayerViewController, coordinator: TVVideoPlayerCoordinator
  ) {
    coordinator.stop(controller: controller)
  }
}

/// Starts the system player at the chosen position, applies the server's
/// default subtitle before controls appear, and hands position reports to
/// the shared reporter. Every new playback starts at the system's 1× rate;
/// the speed control belongs to AVKit, which keeps the chosen rate through
/// pause, seeking, and Picture in Picture.
@MainActor
final class TVVideoPlayerCoordinator {
  private(set) var player: AVPlayer?
  private var reporter: PutioVideoPositionReporter?
  private var statusObservation: NSKeyValueObservation?
  private var rateObservations: [NSKeyValueObservation] = []
  private var notificationObservations: [NSObjectProtocol] = []
  private var positionObservation: Any?
  private var generation: UInt64 = 0
  private var readyReported = false
  private var failureReported = false
  private var audioSessionIsActive = false
  private var probes: TVPlaybackProbes?
  private var onEnded: (@MainActor () -> Void)?
  private var onReportsSettled: (@MainActor () -> Void)?
  private var waitForReports: (@MainActor () async -> Void)?
  private var onFailure: (@MainActor () -> Void)?
  private let makePlayer: @MainActor (AVPlayerItem) -> AVPlayer
  private let applyDefaultSubtitle: @MainActor (AVPlayerItem, AVPlayer) async -> Void

  init(
    makePlayer: @escaping @MainActor (AVPlayerItem) -> AVPlayer = { AVPlayer(playerItem: $0) },
    applyDefaultSubtitle: @escaping @MainActor (AVPlayerItem, AVPlayer) async -> Void = {
      await TVVideoPlayerCoordinator.selectDefaultSubtitle(in: $0, for: $1)
    }
  ) {
    self.makePlayer = makePlayer
    self.applyDefaultSubtitle = applyDefaultSubtitle
  }

  func start(
    item: AVPlayerItem,
    fileID: PutioFileID,
    startSeconds: Int,
    remembersPosition: Bool,
    pipeline: PutioPlaybackPositionPipeline,
    reportPosition: @escaping PutioPlaybackPositionReport,
    in controller: AVPlayerViewController,
    probes: TVPlaybackProbes? = nil,
    onEnded: @escaping @MainActor () -> Void = {},
    onReportsSettled: @escaping @MainActor () -> Void = {},
    onFailure: @escaping @MainActor () -> Void
  ) {
    generation &+= 1
    let playbackGeneration = generation
    readyReported = false
    failureReported = false
    reporter?.cancel()
    self.probes = probes
    self.onEnded = onEnded
    self.onReportsSettled = onReportsSettled
    waitForReports = { await pipeline.waitForPendingReports(fileID: fileID) }
    self.onFailure = onFailure

    let player = makePlayer(item)
    self.player = player
    let reporter = PutioVideoPositionReporter(
      fileID: fileID, remembersPosition: remembersPosition, pipeline: pipeline,
      report: reportPosition,
      currentPosition: { [weak self, weak player] in
        guard let self, let player, self.player === player else { return nil }
        return PutioVideoPositionReporter.normalizedPosition(
          seconds: CMTimeGetSeconds(player.currentTime()))
      })
    self.reporter = reporter

    // Controls stay hidden until the default subtitle is applied, so no
    // subtitle choice can be made before it and then overridden.
    controller.showsPlaybackControls = false
    // tvOS offers no speed control until the player lists its speeds.
    controller.speeds = AVPlaybackSpeed.systemDefaultSpeeds
    controller.player = player

    statusObservation = item.observe(\.status, options: [.initial, .new]) {
      [weak self, weak controller] observed, _ in
      let status = observed.status
      Task { @MainActor [weak self, weak controller] in
        self?.itemStatusChanged(
          status, item: item, controller: controller, generation: playbackGeneration)
      }
    }
    let center = NotificationCenter.default
    notificationObservations = [
      center.addObserver(
        forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.reportFailure(generation: playbackGeneration) }
      },
      center.addObserver(
        forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.reportEnded(generation: playbackGeneration) }
      },
    ]
    if let probes {
      probes.speeds = controller.speeds.map { TVPlaybackProbes.format($0.rate) }
      observe(player: player, item: item, probes: probes, generation: playbackGeneration)
    }

    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .moviePlayback)
      try session.setActive(true)
      audioSessionIsActive = true
    } catch {
      Task { @MainActor [weak self] in self?.reportFailure(generation: playbackGeneration) }
      return
    }

    guard startSeconds > 0 else {
      reporter.positionEstablished()
      player.play()
      return
    }
    let startTime = CMTime(seconds: Double(startSeconds), preferredTimescale: 600)
    player.seek(to: startTime, toleranceBefore: .zero, toleranceAfter: .zero) {
      [weak self, weak player] finished in
      Task { @MainActor [weak self, weak player] in
        guard let self, let player, generation == playbackGeneration, self.player === player,
          !failureReported
        else { return }
        guard finished else {
          reportFailure(generation: playbackGeneration)
          return
        }
        reporter.positionEstablished()
        reporter.startReporting()
        player.play()
      }
    }
  }

  func stop(controller: AVPlayerViewController) {
    reporter?.stop()
    reporter = nil
    generation &+= 1
    statusObservation?.invalidate()
    statusObservation = nil
    for observation in rateObservations { observation.invalidate() }
    rateObservations = []
    for observation in notificationObservations {
      NotificationCenter.default.removeObserver(observation)
    }
    notificationObservations = []
    if let positionObservation, let player {
      player.removeTimeObserver(positionObservation)
    }
    positionObservation = nil
    onEnded = nil
    onFailure = nil
    player?.currentItem?.cancelPendingSeeks()
    player?.pause()
    player?.replaceCurrentItem(with: nil)
    player = nil
    controller.player = nil
    if audioSessionIsActive {
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
      audioSessionIsActive = false
    }
    // The final position is enqueued by now; the callback follows it, and
    // every report before it, to the server.
    if let settled = onReportsSettled, let waitForReports {
      Task { @MainActor in
        await waitForReports()
        settled()
      }
    }
    onReportsSettled = nil
    waitForReports = nil
  }

  private func itemStatusChanged(
    _ status: AVPlayerItem.Status, item: AVPlayerItem, controller: AVPlayerViewController?,
    generation playbackGeneration: UInt64
  ) {
    guard generation == playbackGeneration else { return }
    switch status {
    case .readyToPlay:
      guard !readyReported, !failureReported else { return }
      readyReported = true
      // Playing already, so the end and the exit must count from here, even
      // while the subtitle default is still loading.
      reporter?.ready()
      probes?.isReady = true
      let applyDefaultSubtitle = applyDefaultSubtitle
      Task { @MainActor [weak self, weak controller, weak player] in
        if let player { await applyDefaultSubtitle(item, player) }
        guard let self, generation == playbackGeneration else { return }
        controller?.showsPlaybackControls = true
        reportMediaSelection(for: item, generation: playbackGeneration)
      }
    case .failed:
      reportFailure(generation: playbackGeneration)
    case .unknown:
      break
    @unknown default:
      break
    }
  }

  /// put.io marks the first subtitle `DEFAULT` unless the account disables
  /// auto-selection, and omits subtitles when they are hidden. Automatic
  /// selection leaves that default off under the system subtitle setting,
  /// and the tvOS player re-applies it once playback starts, so the legible
  /// criteria name the default's language before it is selected. Only the
  /// legible group changes: audio keeps the system's automatic choice, as on
  /// iOS.
  static func selectDefaultSubtitle(in item: AVPlayerItem, for player: AVPlayer) async {
    guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
      let option = group.defaultOption
    else { return }
    if let language = option.extendedLanguageTag ?? option.locale?.identifier {
      player.setMediaSelectionCriteria(
        AVPlayerMediaSelectionCriteria(
          preferredLanguages: [language], preferredMediaCharacteristics: nil),
        forMediaCharacteristic: .legible)
    }
    item.select(option, in: group)
  }

  private func reportFailure(generation playbackGeneration: UInt64) {
    guard generation == playbackGeneration, !failureReported else { return }
    failureReported = true
    onFailure?()
  }

  private func reportEnded(generation playbackGeneration: UInt64) {
    guard generation == playbackGeneration, readyReported, !failureReported,
      reporter?.playbackEnded() == true
    else { return }
    onEnded?()
  }

  // MARK: Harness probes

  private func observe(
    player: AVPlayer, item: AVPlayerItem, probes: TVPlaybackProbes,
    generation playbackGeneration: UInt64
  ) {
    positionObservation = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
    ) { [weak probes] time in
      MainActor.assumeIsolated {
        probes?.currentPosition = PutioVideoPositionReporter.normalizedPosition(
          seconds: CMTimeGetSeconds(time))
      }
    }
    rateObservations = [
      player.observe(\.rate, options: [.initial, .new]) { [weak probes] player, _ in
        let rate = player.rate
        Task { @MainActor in probes?.rate = rate }
      },
      player.observe(\.defaultRate, options: [.initial, .new]) { [weak probes] player, _ in
        let rate = player.defaultRate
        Task { @MainActor in probes?.speed = rate }
      },
    ]
    notificationObservations.append(
      NotificationCenter.default.addObserver(
        forName: AVPlayerItem.mediaSelectionDidChangeNotification, object: item, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.reportMediaSelection(for: item, generation: playbackGeneration)
        }
      })
  }

  private func reportMediaSelection(for item: AVPlayerItem, generation playbackGeneration: UInt64) {
    guard let probes else { return }
    Task { @MainActor [weak self, weak probes] in
      let selection = await TVMediaSelection.current(in: item)
      guard let self, generation == playbackGeneration, let probes else { return }
      probes.audioLanguage = selection.audio
      probes.subtitle = selection.subtitle
    }
  }
}

/// The audible and legible options in effect, as language codes.
@MainActor
enum TVMediaSelection {
  /// `subtitle` is `off` when the stream offers subtitles but none is
  /// selected, and `unavailable` when it offers none.
  static func current(in item: AVPlayerItem) async -> (audio: String?, subtitle: String) {
    let audio: String?
    if let group = try? await item.asset.loadMediaSelectionGroup(for: .audible),
      let option = item.currentMediaSelection.selectedMediaOption(in: group)
    {
      audio = languageCode(of: option)
    } else {
      audio = nil
    }
    guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) else {
      return (audio, "unavailable")
    }
    guard let option = item.currentMediaSelection.selectedMediaOption(in: group) else {
      return (audio, "off")
    }
    return (audio, languageCode(of: option))
  }

  /// "eng", "en-US", and "en" all read as "en".
  nonisolated static func languageCode(of option: AVMediaSelectionOption) -> String {
    let raw = option.extendedLanguageTag ?? option.locale?.identifier ?? "und"
    return Locale.Language(identifier: raw).languageCode?.identifier(.alpha2) ?? raw
  }
}
