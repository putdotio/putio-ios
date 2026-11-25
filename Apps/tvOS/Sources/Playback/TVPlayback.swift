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
  case asking(AVPlayerItem, PutioPlaybackSource, PutioVideoResumePrompt)
  case playing(AVPlayerItem, PutioPlaybackSource)
  case ended
}

/// The video screen: conversion gate, pre-play resume decision, the system
/// player, and the successor once it ends. State comes from the shared
/// playback models; this screen owns presentation and remote input.
struct TVVideoPlaybackView: View {
  @State private var model: PutioVideoPlaybackModel
  @State private var nextVideoModel: PutioVideoUpNextModel
  @State private var stage: TVPlaybackStage = .measuring
  @State private var retrySequence: UInt64 = 0
  @State private var probes = TVPlaybackProbes()
  @State private var nextVideoTask: Task<Void, Never>?
  @State private var subtitleMemory = TVVideoPlaybackView.makeSubtitleMemory()

  private let route: PutioVideoRoute
  private let account: PutioAccountSnapshot
  private let remembersPosition: Bool
  private let subtitlePolicy: PutioSubtitleStartupPolicy
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
    self.account = account
    self.remembersPosition = account.rememberVideoTime
    self.subtitlePolicy = PutioSubtitleStartupPolicy(
      hideSubtitles: account.hideSubtitles,
      dontAutoSelectSubtitles: account.dontAutoSelectSubtitles)
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
      initialValue: PutioVideoUpNextModel(
        fileID: route.id,
        suggestionsEnabled: account.suggestNextVideo,
        autoplayEnabled: { (try? await runtime.appConfig().autoplayNextVideo) ?? false },
        waitForReset: { await pipeline.waitForPendingReports(fileID: $0) },
        find: { fileID in
          try await findNextVideo(
            after: fileID, findNext: { try await runtime.findNextVideo(after: $0) })
        },
        prepare: { video in
          try await preparePlayableVideo(
            video, waitForPendingReports: { await pipeline.waitForPendingReports(fileID: $0) },
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
      .task { await nextVideoModel.lookUp() }
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
        guard case .playing(let next) = state else { return }
        onPlayNext(next)
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
      if let notice = failure.inactiveAccountNotice(for: account) {
        TVPlaybackAccountNotice(notice: notice)
      } else {
        PutioErrorStateView(
          title: failure.title, message: failure.message, retryTitle: "Try again",
          retryIdentifier: "video.retry"
        ) {
          retrySequence &+= 1
        }
        .takesFocus()
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
    case .asking(let item, let source, let prompt):
      TVResumePromptView(fileName: route.title, prompt: prompt) { choice in
        stage = .playing(item, source.starting(at: prompt.startSeconds(for: choice)))
      }
    case .playing(let item, let source):
      TVSystemVideoPlayer(
        item: item, source: source, fileID: route.id, remembersPosition: remembersPosition,
        pipeline: pipeline,
        reportPosition: { [runtime] fileID, seconds in
          try await runtime.reportPlaybackPosition(fileID: fileID, seconds: seconds)
        },
        subtitlePolicy: subtitlePolicy, subtitleMemory: subtitleMemory,
        probes: showsProbes ? probes : nil,
        onEnded: playbackEnded,
        onReportsSettled: { [route, onPlayerReportsSettled] in onPlayerReportsSettled(route) },
        onFailure: playerFailed
      )
      .ignoresSafeArea()
    case .ended:
      TVNextVideoStage(
        model: nextVideoModel,
        play: { runNextVideo { await nextVideoModel.playNext() } },
        retry: { runNextVideo { await nextVideoModel.retry() } },
        close: {
          nextVideoModel.cancel()
          onFinish()
        })
    }
  }

  private func playerFailed(_ failure: PutioVideoPlayerFailure) {
    if let source = readySource {
      let report = PutioPlaybackFailureReport(
        platform: .tvos, fileID: route.id, source: source, error: failure.error,
        playbackStarted: !failure.beforeFirstFrame, outcome: .failed)
      SentryTelemetry.report(report)
      if showsProbes { probes.failureReport = report }
    }
    model.playerFailed(failure.error.fault)
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
    switch PutioVideoStart.prompted(
      startFromSeconds: source.startFromSeconds, durationSeconds: seconds,
      remembersPosition: remembersPosition)
    {
    case .ask(let prompt):
      stage = .asking(item, source, prompt)
    case .play(let startSeconds):
      stage = .playing(item, source.starting(at: startSeconds))
    }
  }

  private static func makeSubtitleMemory() -> PutioSubtitleMemory {
    #if DEBUG
      HarnessSubtitleMemory.make()
    #else
      PutioSubtitleMemory()
    #endif
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
    runNextVideo {
      await nextVideoModel.playbackEnded()
      if nextVideoModel.upcoming == nil { await nextVideoModel.lookUp() }
    }
  }

  /// Leaves the screen only once a lookup confirms there is no successor.
  private func runNextVideo(_ operation: @escaping @MainActor () async -> Void) {
    startNextVideoTask {
      await operation()
      guard !Task.isCancelled, nextVideoModel.state == .idle, nextVideoModel.upcoming == nil,
        !nextVideoModel.lookupFailed
      else { return }
      onFinish()
    }
  }

  private func startNextVideoTask(_ operation: @escaping @MainActor () async -> Void) {
    let previous = nextVideoTask
    nextVideoTask = Task { @MainActor in await operation() }
    previous?.cancel()
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

/// The pre-play decision: the raw filename, a progress preview of the focused
/// choice, and two stacked buttons with the system focus. Continue takes the first focus; Menu
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
    .task { focusedChoice = initialChoice }
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

/// Only the yellow elapsed segment carries a put.io colour.
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

/// After the end: the successor with its countdown while autoplay is on,
/// the successor alone while it is off, and a retry when the lookup failed.
/// No successor ends the screen.
private struct TVNextVideoStage: View {
  let model: PutioVideoUpNextModel
  let play: () -> Void
  let retry: () -> Void
  let close: () -> Void

  var body: some View {
    switch model.state {
    case .countingDown(let next, let secondsLeft):
      TVUpNextView(
        nextVideo: next, autoplaySecondsRemaining: secondsLeft, onPlay: play, onCancel: close)
    case .idle where model.upcoming != nil,
      .finding where model.upcoming != nil && !model.isPlayingChosenVideo:
      if let next = model.upcoming {
        TVUpNextView(nextVideo: next, onPlay: play, onCancel: close)
      }
    case .failed,
      .idle where model.lookupFailed:
      PutioErrorStateView(
        icon: .warningCircle, title: String(localized: "Couldn’t find the next video"),
        message: nil, retryIdentifier: "video.next-error.retry", retry: retry
      )
      .secondaryAction(
        String(localized: "Cancel"), identifier: "video.next-error.cancel", perform: close
      )
      .takesFocus()
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("video.next-error")
    case .idle, .finding, .playing:
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
    .task { focusedAction = .play }
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
/// are AVKit's own; the shared session starts it at the chosen position,
/// applies the start subtitle, and reports positions.
private struct TVSystemVideoPlayer: UIViewControllerRepresentable {
  let item: AVPlayerItem
  let source: PutioPlaybackSource
  let fileID: PutioFileID
  let remembersPosition: Bool
  let pipeline: PutioPlaybackPositionPipeline
  let reportPosition: PutioPlaybackPositionReport
  let subtitlePolicy: PutioSubtitleStartupPolicy
  let subtitleMemory: PutioSubtitleMemory
  let probes: TVPlaybackProbes?
  let onEnded: @MainActor () -> Void
  let onReportsSettled: @MainActor () -> Void
  let onFailure: @MainActor (PutioVideoPlayerFailure) -> Void

  func makeCoordinator() -> TVVideoPlayerCoordinator {
    TVVideoPlayerCoordinator(subtitlePolicy: subtitlePolicy, subtitleMemory: subtitleMemory)
  }

  func makeUIViewController(context: Context) -> AVPlayerViewController {
    let controller = AVPlayerViewController()
    let probes = probes
    let report = reportPosition
    context.coordinator.start(
      item: item, source: source, fileID: fileID, remembersPosition: remembersPosition,
      pipeline: pipeline,
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

extension AVPlayerViewController: PutioVideoPlayerSurface {
  public var showsFirstFrame: Bool { isReadyForDisplay }
}

/// The shared AVPlayer session in the system player. The speed the viewer
/// picks is remembered for the next video, as on iOS, and a subtitle picked
/// once the controls show is remembered for the start pick.
@MainActor
final class TVVideoPlayerCoordinator {
  private var session: PutioVideoPlayerSession?
  private var observations: [NSKeyValueObservation] = []
  private var selectionObservation: NSObjectProtocol?
  private var onReportsSettled: (@MainActor () -> Void)?
  private var waitForReports: (@MainActor () async -> Void)?
  private let subtitlePolicy: PutioSubtitleStartupPolicy
  private let subtitleMemory: PutioSubtitleMemory?
  private let speedStore: PutioAudioSpeedStore
  private let makePlayer: @MainActor (AVPlayerItem) -> AVPlayer
  private let applyStartSubtitle: @MainActor (AVPlayerItem, AVPlayer?) async -> Void

  var player: AVPlayer? { session?.player }

  init(
    subtitlePolicy: PutioSubtitleStartupPolicy = .accountDefault,
    subtitleMemory: PutioSubtitleMemory? = nil,
    speedStore: PutioAudioSpeedStore? = nil,
    makePlayer: @escaping @MainActor (AVPlayerItem) -> AVPlayer = { AVPlayer(playerItem: $0) },
    applyStartSubtitle: (@MainActor (AVPlayerItem, AVPlayer?) async -> Void)? = nil
  ) {
    self.subtitlePolicy = subtitlePolicy
    self.subtitleMemory = subtitleMemory
    self.speedStore = speedStore ?? .video()
    self.makePlayer = makePlayer
    self.applyStartSubtitle =
      applyStartSubtitle ?? { item, player in
        await TVVideoPlayerCoordinator.selectStartSubtitle(
          in: item, for: player, policy: subtitlePolicy, remembered: subtitleMemory?.remembered)
      }
  }

  func start(
    item: AVPlayerItem,
    source: PutioPlaybackSource? = nil,
    fileID: PutioFileID,
    startSeconds: Int? = nil,
    remembersPosition: Bool,
    pipeline: PutioPlaybackPositionPipeline,
    reportPosition: @escaping PutioPlaybackPositionReport,
    in controller: AVPlayerViewController,
    probes: TVPlaybackProbes? = nil,
    onEnded: @escaping @MainActor () -> Void = {},
    onReportsSettled: @escaping @MainActor () -> Void = {},
    onFailure: @escaping @MainActor (PutioVideoPlayerFailure) -> Void
  ) {
    if let session { stop(session, controller: controller, settles: false) }
    let speed = speedStore.load()
    let makePlayer = makePlayer
    let applyStartSubtitle = applyStartSubtitle
    weak var created: AVPlayer?
    let session = PutioVideoPlayerSession(
      makeDriver: { item in
        let player = makePlayer(item)
        player.defaultRate = speed.rawValue
        created = player
        return PutioVideoPlayerDriver(player: player)
      },
      audioSession: PutioPlaybackAudioSession(),
      notificationCenter: .default,
      backgroundNotification: nil,
      positionPipeline: pipeline,
      applyDefaultSubtitle: { item in await applyStartSubtitle(item, created) })
    self.session = session
    self.onReportsSettled = onReportsSettled
    waitForReports = { await pipeline.waitForPendingReports(fileID: fileID) }
    session.onSubtitleSelected = probes.map { probes in { probes.subtitle = $0 } }

    controller.speeds = AVPlaybackSpeed.systemDefaultSpeeds
    let base =
      source
      ?? PutioPlaybackSource(
        url: (item.asset as? AVURLAsset)?.url ?? URL(fileURLWithPath: "/dev/null"),
        startFromSeconds: 0)
    session.start(
      fileID: fileID, source: base.starting(at: startSeconds ?? base.startFromSeconds),
      preparedItem: item, remembersPlaybackPosition: remembersPosition,
      reportPosition: reportPosition, in: controller,
      onReady: { [weak self, weak controller] in
        probes?.isReady = true
        guard let self, let controller else { return }
        self.watchSubtitlePicks(of: item, controller: controller)
      },
      observesPlaybackState: probes != nil,
      onAudioSelected: { probes?.audioLanguage = $0 },
      onPositionChanged: { probes?.currentPosition = $0 },
      onPlaybackEnded: { onEnded() },
      onFailure: onFailure)
    if let player = session.player {
      if let chosen = controller.speeds.first(where: { $0.rate == speed.rawValue }) {
        controller.selectSpeed(chosen)
      }
      observe(player, probes: probes)
    }
    probes?.speeds = controller.speeds.map { TVPlaybackProbes.format($0.rate) }
  }

  func stop(controller: AVPlayerViewController) {
    guard let session else { return }
    stop(session, controller: controller, settles: true)
  }

  private func stop(
    _ session: PutioVideoPlayerSession, controller: AVPlayerViewController, settles: Bool
  ) {
    for observation in observations { observation.invalidate() }
    observations = []
    if let selectionObservation {
      NotificationCenter.default.removeObserver(selectionObservation)
    }
    selectionObservation = nil
    session.stop(surface: controller)
    self.session = nil
    // The final position is enqueued by now; the callback follows it, and
    // every report before it, to the server.
    if settles, let settled = onReportsSettled, let waitForReports {
      Task { @MainActor in
        await waitForReports()
        settled()
      }
    }
    onReportsSettled = nil
    waitForReports = nil
  }

  private func observe(_ player: AVPlayer, probes: TVPlaybackProbes?) {
    let speedStore = speedStore
    observations = [
      player.observe(\.defaultRate, options: [.initial, .new]) { [weak probes] player, _ in
        let rate = player.defaultRate
        Task { @MainActor in
          probes?.speed = rate
          if let speed = PutioAudioSpeed(rawValue: rate) { speedStore.save(speed) }
        }
      }
    ]
    if let probes {
      observations.append(
        player.observe(\.rate, options: [.initial, .new]) { [weak probes] player, _ in
          let rate = player.rate
          Task { @MainActor in probes?.rate = rate }
        })
    }
  }

  private func watchSubtitlePicks(of item: AVPlayerItem, controller: AVPlayerViewController) {
    guard let subtitleMemory else { return }
    selectionObservation = NotificationCenter.default.addObserver(
      forName: AVPlayerItem.mediaSelectionDidChangeNotification, object: item, queue: .main
    ) { [weak controller] _ in
      MainActor.assumeIsolated {
        guard controller?.showsPlaybackControls == true else { return }
        Task { @MainActor in
          guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) else {
            return
          }
          let picked = item.currentMediaSelection.selectedMediaOption(in: group)
          guard picked.map({ !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) }) ?? true
          else { return }
          subtitleMemory.remember(
            picked.map {
              PutioSubtitleTrack(
                id: 0, title: $0.displayName,
                languageTag: $0.extendedLanguageTag ?? $0.locale?.identifier)
            })
        }
      }
    }
  }

  /// The shared start pick, from the account's subtitle settings and the
  /// remembered language. The tvOS player re-applies automatic selection once
  /// playback starts, so the legible criteria name the pick's language before
  /// it is selected. Only the legible group changes: audio keeps the system's
  /// automatic choice.
  static func selectStartSubtitle(
    in item: AVPlayerItem, for player: AVPlayer?, policy: PutioSubtitleStartupPolicy,
    remembered: PutioRememberedSubtitle?
  ) async {
    await PutioVideoTracks.selectStartSubtitle(in: item, policy: policy, remembered: remembered) {
      guard let language = $0.extendedLanguageTag ?? $0.locale?.identifier else { return }
      player?.setMediaSelectionCriteria(
        AVPlayerMediaSelectionCriteria(
          preferredLanguages: [language], preferredMediaCharacteristics: nil),
        forMediaCharacteristic: .legible)
    }
  }

  static func selectDefaultSubtitle(in item: AVPlayerItem, for player: AVPlayer) async {
    await selectStartSubtitle(in: item, for: player, policy: .accountDefault, remembered: nil)
  }
}

private struct TVTakesFocus: ViewModifier {
  @Namespace private var scope
  @Environment(\.resetFocus) private var resetFocus

  func body(content: Content) -> some View {
    content
      .focusScope(scope)
      .task {
        let stale = Self.focusedItem
        for _ in 0..<20 where !Task.isCancelled && Self.focusedItem === stale {
          resetFocus(in: scope)
          try? await Task.sleep(for: .milliseconds(50))
        }
      }
  }

  private static var focusedItem: AnyObject? {
    UIApplication.shared.connectedScenes.lazy
      .compactMap { ($0 as? UIWindowScene)?.focusSystem?.focusedItem }
      .first
  }
}

extension View {
  fileprivate func takesFocus() -> some View { modifier(TVTakesFocus()) }
}
