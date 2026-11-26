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
  let continueWatching: PutioContinueWatchingModel
  let refreshRequests: PutioFolderRefreshRequests

  @Environment(\.dismiss) private var dismiss
  @State private var route: PutioVideoRoute

  init(
    route: PutioVideoRoute, runtime: PutioRuntime, account: PutioAccountSnapshot,
    pipeline: PutioPlaybackPositionPipeline, continueWatching: PutioContinueWatchingModel,
    refreshRequests: PutioFolderRefreshRequests
  ) {
    self.runtime = runtime
    self.account = account
    self.pipeline = pipeline
    self.continueWatching = continueWatching
    self.refreshRequests = refreshRequests
    _route = State(initialValue: route)
  }

  var body: some View {
    TVVideoPlaybackView(
      route: route, runtime: runtime, account: account, pipeline: pipeline,
      continueWatching: continueWatching,
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

struct TVVideoCover<Content: View>: View {
  @ViewBuilder let content: () -> Content

  @Environment(\.dismiss) private var dismiss
  @State private var presented = false

  var body: some View {
    Color.black
      .ignoresSafeArea()
      .onAppear { presented = true }
      .fullScreenCover(isPresented: $presented, onDismiss: { dismiss() }, content: content)
  }
}

/// The video screen: conversion gate, pre-play resume decision, the system
/// player, and the successor once it ends. State comes from the shared
/// playback models; this screen owns presentation and remote input.
struct TVVideoPlaybackView: View {
  @State private var model: PutioVideoPlaybackModel
  @State private var nextVideoModel: PutioVideoUpNextModel
  @State private var resumePrompter: PutioVideoResumePrompter
  @State private var ended = false
  @State private var leftPlayer = false
  @State private var upNextFolder: String?
  @State private var toast: PutioToast?
  @State private var retrySequence: UInt64 = 0
  @State private var playerFailureTask: Task<Void, Never>?
  @State private var probes = TVPlaybackProbes()
  @State private var nextVideoTask: Task<Void, Never>?
  @State private var subtitleMemory = TVVideoPlaybackView.makeSubtitleMemory()
  @State private var wait = PutioVideoWaitModel()
  @State private var switchesToStream = false
  @State private var failureReference: String?
  @State private var announcedFallback = false
  @State private var dismissedUpNext = false

  private let route: PutioVideoRoute
  private let account: PutioAccountSnapshot
  private let remembersPosition: Bool
  private let subtitlePolicy: PutioSubtitleStartupPolicy
  private let pipeline: PutioPlaybackPositionPipeline
  private let continueWatching: PutioContinueWatchingModel
  private let runtime: PutioRuntime
  private let convertedFallbacks: PutioConvertedFallbacks
  private let showsProbes: Bool
  private let onPlayNext: @MainActor (PutioPlayableNextVideo) -> Void
  private let onPlayerReportsSettled: @MainActor (PutioVideoRoute) -> Void
  private let onFinish: @MainActor () -> Void

  init(
    route: PutioVideoRoute, runtime: PutioRuntime, account: PutioAccountSnapshot,
    pipeline: PutioPlaybackPositionPipeline, continueWatching: PutioContinueWatchingModel,
    onPlayNext: @escaping @MainActor (PutioPlayableNextVideo) -> Void,
    onPlayerReportsSettled: @escaping @MainActor (PutioVideoRoute) -> Void,
    onFinish: @escaping @MainActor () -> Void
  ) {
    let convertedFallbacks = PutioConvertedFallbacks(accountID: account.id)
    let media = TVPlaybackMedia(
      runtime: runtime, account: account, convertedFallbacks: convertedFallbacks)
    self.convertedFallbacks = convertedFallbacks
    self.route = route
    self.account = account
    self.remembersPosition = account.rememberVideoTime
    self.subtitlePolicy = PutioSubtitleStartupPolicy(
      hideSubtitles: account.hideSubtitles,
      dontAutoSelectSubtitles: account.dontAutoSelectSubtitles)
    self.pipeline = pipeline
    self.continueWatching = continueWatching
    self.runtime = runtime
    self.showsProbes = media.isHarness
    self.onPlayNext = onPlayNext
    self.onPlayerReportsSettled = onPlayerReportsSettled
    self.onFinish = onFinish
    let resumePrompter = PutioVideoResumePrompter()
    _resumePrompter = State(initialValue: resumePrompter)
    // Without a choice from the browser, the player asks.
    let start = route.start == .asksAfterConversion ? .asksInPlayer : route.start
    _model = State(
      initialValue: PutioVideoPlaybackModel(
        fileID: route.id,
        initialResolution: route.initialResolution,
        conversionPollInterval: media.isHarness ? .milliseconds(1_200) : .seconds(3),
        startConversion: { try await runtime.startVideoConversion(fileID: $0) },
        loadConversionStatus: { try await runtime.videoConversionStatus(fileID: $0) },
        chooseStart: PutioVideoStart.choice(
          for: start, remembersPosition: account.rememberVideoTime,
          durationSeconds: { await PutioVideoLength.seconds(of: $0) },
          ask: { await resumePrompter.ask(positionSeconds: $0, durationSeconds: $1) }),
        resolveConverted: { fileID in
          await pipeline.waitForPendingReports(fileID: fileID)
          return try await media.resolve(fileID, playsConverted: true)
        }
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
      .task(id: nextVideoModel.upcoming?.parentID) {
        guard let parent = nextVideoModel.upcoming?.parentID, parent != .root else {
          upNextFolder = nil
          return
        }
        upNextFolder = try? await runtime.getFile(fileID: parent).name
      }
      .task(id: retrySequence) {
        guard retrySequence > 0 else { return }
        failureReference = nil
        await model.retry()
      }
      .onChange(of: model.state) { _, state in
        probes.record(state)
        if case .ready(let source) = state {
          probes.resumePosition = source.startFromSeconds
          probes.source = source.original?.player == .engine ? "original-engine" : "stream"
        }
      }
      .onChange(of: nextVideoModel.state) { _, state in
        guard case .playing(let next) = state else { return }
        onPlayNext(next)
      }
      .onDisappear {
        nextVideoTask?.cancel()
        nextVideoTask = nil
        nextVideoModel.cancel()
        playerFailureTask?.cancel()
        playerFailureTask = nil
      }
      .overlay {
        if showsProbes { TVPlaybackProbeView(probes: probes) }
      }
  }

  @ViewBuilder
  private var content: some View {
    if resumePrompter.isAsking {
      TVResumePromptView(
        fileName: route.title, positionSeconds: resumePrompter.positionSeconds,
        prompt: resumePrompter.prompt
      ) { resumePrompter.answer($0) }
    } else {
      stateContent
    }
  }

  @ViewBuilder
  private var stateContent: some View {
    switch model.state {
    case .loading:
      TVPlaybackLoadingView(
        title: route.title,
        status: switchesToStream
          ? String(localized: "Switching to streaming…", bundle: .putioCore)
          : String(localized: "Loading", bundle: .putioCore))
    case .conversionRequired, .conversionQueued, .converting, .conversionCompleted:
      TVPlaybackConvertingScreen(state: model.state, fileName: route.title, back: onFinish)
    case .failed(let failure):
      if let notice = failure.inactiveAccountNotice(for: account) {
        TVPlaybackAccountNotice(notice: notice)
      } else {
        TVPlaybackFailureScreen(
          failure: failure, fileID: route.id, fileName: route.title,
          reference: failureReference, retry: { retrySequence &+= 1 }, back: onFinish)
      }

    case .ready(let source):
      readyContent(source)
    }
  }

  @ViewBuilder
  private func readyContent(_ source: PutioPlaybackSource) -> some View {
    if wait.state == .stalled {
      TVPlaybackStalledScreen(
        fileName: route.title, runtime: runtime,
        retry: {
          let seconds = wait.waitingFromSeconds
          wait.restart()
          Task { await model.retry(resumingAt: seconds) }
        }, back: onFinish)
    } else if showsNextVideoStage {
      TVNextVideoStage(
        model: nextVideoModel,
        play: { runNextVideo { await nextVideoModel.playNext() } },
        retry: {
          leftPlayer = true
          runNextVideo { await nextVideoModel.retry() }
        },
        close: {
          nextVideoModel.cancel()
          onFinish()
        })
    } else if source.original?.player == .engine {
      TVDirectVideoPlayer(
        title: route.title, fileID: route.id, source: source,
        remembersPosition: remembersPosition, subtitlePolicy: subtitlePolicy,
        subtitleMemory: subtitleMemory, pipeline: pipeline,
        reportPosition: feedingReport,
        wait: wait, callbacks: directCallbacks, onNextFile: nextFileAction,
        onAudioSwitchFailed: {
          toast = PutioToast(
            String(localized: "Couldn’t switch audio track", bundle: .putioCore), icon: .warning,
            width: .fit)
        },
        onReportsSettled: { [route, onPlayerReportsSettled] in onPlayerReportsSettled(route) },
        onRateChanged: { [probes] in probes.rate = $0 },
        onControlsShown: { [probes] in probes.controlsShown = $0 },
        onBadgeShown: { [probes] in probes.lastBadge = $0.identifier },
        onFocusChanged: { [probes] in probes.focus = $0 },
        onExit: onFinish
      )
      .disabled(showsEngineUpNext)
      .overlay {
        if showsEngineUpNext {
          TVNextVideoStage(
            model: nextVideoModel,
            play: { runNextVideo { await nextVideoModel.playNext() } },
            retry: { runNextVideo { await nextVideoModel.retry() } },
            close: dismissEngineUpNext
          )
          .onExitCommand(perform: dismissEngineUpNext)
        }
      }
      .id(model.playerAttempt)
      .putioToast($toast)
    } else {
      TVSystemVideoPlayer(
        title: route.title, source: source, fileID: route.id,
        remembersPosition: remembersPosition,
        pipeline: pipeline,
        reportPosition: feedingReport,
        onDurationKnown: durationKnown,
        subtitlePolicy: subtitlePolicy, subtitleMemory: subtitleMemory,
        probes: showsProbes ? probes : nil,
        wait: wait,
        onReady: playerReady,
        onNextFile: nextFileAction,
        upNext: upNextProposal,
        onSubtitleFailed: {
          toast = PutioToast(
            String(localized: "Couldn’t load subtitles", bundle: .putioCore), icon: .warning,
            width: .fit)
        },
        onEnded: playbackEnded,
        onRestarted: playbackRestarted,
        onReportsSettled: { [route, onPlayerReportsSettled] in onPlayerReportsSettled(route) },
        onFailure: playerFailed
      )
      .ignoresSafeArea()
      .id(model.playerAttempt)
      .putioToast($toast)
    }
  }

  private var feedingReport: PutioPlaybackPositionReport {
    continueWatching.feeding { [runtime] fileID, seconds in
      try await runtime.reportPlaybackPosition(fileID: fileID, seconds: seconds)
    }
  }

  private var durationKnown: @MainActor @Sendable (Double) -> Void {
    { [route, continueWatching] in
      continueWatching.opened(
        fileID: route.id, parentID: route.parentID, name: route.title, durationSeconds: $0)
    }
  }

  private var directCallbacks: PutioVideoPlayerCallbacks {
    PutioVideoPlayerCallbacks(
      onReady: playerReady,
      onDurationKnown: durationKnown,
      observesPlaybackState: showsProbes,
      onAudioSelected: { [probes] in probes.audioLanguage = $0 },
      onSubtitleSelected: { [probes] in probes.subtitle = $0 },
      onPositionChanged: { [probes] in probes.currentPosition = $0 },
      onPlaybackEnded: playbackEnded,
      onPlaybackRestarted: playbackRestarted,
      onFailure: playerFailed)
  }

  private func playerReady() {
    model.playerReady()
    probes.isReady = true
    switchesToStream = false
    guard model.playsConvertedFallback, !announcedFallback else { return }
    announcedFallback = true
    convertedFallbacks.remember(route.id)
    toast = PutioToast(
      String(localized: "Playing the streaming version", bundle: .putioCore),
      icon: .symbol(.info), width: .fit)
  }

  private func playerFailed(_ failure: PutioVideoPlayerFailure) {
    playerFailureTask?.cancel()
    let handled = model.handlePlayerFailure(failure, platform: .tvos) {
      [probes, showsProbes] report in
      SentryTelemetry.report(report)
      if report.outcome == .failed { failureReference = report.reference }
      if showsProbes { probes.failureReport = report }
    }
    switchesToStream = handled.fellBack
    playerFailureTask = handled.recovery
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

  private var showsNextVideoStage: Bool {
    if leftPlayer { return true }
    guard ended else { return false }
    switch nextVideoModel.state {
    case .failed: return true
    case .idle: return nextVideoModel.lookupFailed
    case .finding, .countingDown, .playing: return false
    }
  }

  private var showsEngineUpNext: Bool {
    ended && !dismissedUpNext && nextVideoModel.upcoming != nil
  }

  private var nextFileAction: (@MainActor () -> Void)? {
    guard nextVideoModel.upcoming != nil else { return nil }
    return { playNextFile() }
  }

  private var upNextProposal: TVUpNextProposal? {
    guard let next = nextVideoModel.upcoming else { return nil }
    return TVUpNextProposal(
      next: next, folderName: upNextFolder, model: nextVideoModel,
      accept: { runNextVideo { await nextVideoModel.playNext() } },
      reject: { nextVideoModel.cancel() })
  }

  private func dismissEngineUpNext() {
    dismissedUpNext = true
    nextVideoModel.cancel()
  }

  private func playNextFile() {
    leftPlayer = true
    runNextVideo { await nextVideoModel.playNext() }
  }

  private func playbackRestarted() {
    probes.ended = false
    ended = false
    dismissedUpNext = false
    nextVideoModel.cancel()
  }

  private func playbackEnded() {
    probes.ended = true
    ended = true
    dismissedUpNext = false
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
  let convertedFallbacks: PutioConvertedFallbacks

  var isHarness: Bool {
    #if DEBUG
      TVHarnessMedia.current != nil
    #else
      false
    #endif
  }

  /// The account's playback method picks the source, as on iOS: Direct play
  /// plays the original unless an earlier attempt fell back to streaming.
  func resolve(
    _ fileID: PutioFileID, playsConverted: Bool = false
  ) async throws -> PutioPlaybackResolution {
    let method = (try? await runtime.appConfig().playbackMethod) ?? .standard
    let resolution = try await runtime.resolveVideoPlayback(
      fileID: fileID, method: method,
      playsConverted: playsConverted || convertedFallbacks.contains(fileID),
      isPlayableInAVPlayer: { PutioDirectPlayback.isPlayableInAVPlayer($0) })
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
  let positionSeconds: Int
  let prompt: PutioVideoResumePrompt?
  var initialChoice: PutioVideoResumePrompt.Choice = .resume
  let choose: (PutioVideoResumePrompt.Choice) -> Void

  @FocusState private var focusedChoice: PutioVideoResumePrompt.Choice?

  private var previewedChoice: PutioVideoResumePrompt.Choice {
    focusedChoice ?? initialChoice
  }

  var body: some View {
    VStack(spacing: 0) {
      Text(PutioVideoResumePrompt.question(positionSeconds: positionSeconds))
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
      if let prompt {
        TVResumeProgress(fraction: prompt.progress(for: previewedChoice))
          .padding(.top, TVResumePromptLayout.progressGap)
      }
      VStack(spacing: TVResumePromptLayout.buttonGap) {
        choiceButton(
          PutioVideoResumePrompt.resumeTitle, choice: .resume,
          accessibilityLabel: PutioVideoResumePrompt.resumeAccessibilityLabel(
            positionSeconds: positionSeconds),
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

struct TVPlaybackLoadingView: View {
  let title: String
  var status = String(localized: "Loading", bundle: .putioCore)

  var body: some View {
    ZStack(alignment: .topLeading) {
      PutioLoadingStateView(title: status)
        .accessibilityIdentifier("video.loading")
      Text(title)
        .putioFont(PutioTheme.TV.Typography.caption)
        .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
        .lineLimit(1)
        .accessibilityIdentifier("video.loading.title")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tvOverscanPadding()
    }
    .background(Color.black.ignoresSafeArea())
  }
}

/// The system player. Transport, info panels, subtitles, and audio are
/// AVKit's own; the shared session starts it at the chosen position, applies
/// the start subtitle, and reports positions.
private struct TVSystemVideoPlayer: UIViewControllerRepresentable {
  let title: String
  let source: PutioPlaybackSource
  let fileID: PutioFileID
  let remembersPosition: Bool
  let pipeline: PutioPlaybackPositionPipeline
  let reportPosition: PutioPlaybackPositionReport
  let onDurationKnown: @MainActor (Double) -> Void
  let subtitlePolicy: PutioSubtitleStartupPolicy
  let subtitleMemory: PutioSubtitleMemory
  let probes: TVPlaybackProbes?
  let wait: PutioVideoWaitModel
  let onReady: @MainActor () -> Void
  let onNextFile: (@MainActor () -> Void)?
  let upNext: TVUpNextProposal?
  let onSubtitleFailed: @MainActor () -> Void
  let onEnded: @MainActor () -> Void
  let onRestarted: @MainActor () -> Void
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
      item: TVVideoPlaybackView.playerItem(asset: AVURLAsset(url: source.url), title: title),
      source: source, fileID: fileID, remembersPosition: remembersPosition,
      pipeline: pipeline,
      reportPosition: { fileID, seconds in
        try await report(fileID, seconds)
        probes?.reportedPosition = "id=\(fileID.rawValue);seconds=\(seconds)"
      },
      in: controller, probes: probes, wait: wait, onReady: onReady,
      onSubtitleFailed: onSubtitleFailed, onDurationKnown: onDurationKnown, onEnded: onEnded,
      onRestarted: onRestarted, onReportsSettled: onReportsSettled, onFailure: onFailure)
    controller.view.accessibilityIdentifier = "video.system-player"
    return controller
  }

  func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
    context.coordinator.showNextFile(onNextFile, in: controller)
    context.coordinator.propose(upNext, in: controller)
  }

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
  private let backgroundNotification: Notification.Name?
  private let makePlayer: @MainActor (AVPlayerItem) -> AVPlayer
  private let applyStartSubtitle: @MainActor (AVPlayerItem, AVPlayer?) async -> Void

  var player: AVPlayer? { session?.player }
  private var nextFile: (@MainActor () -> Void)?
  private let proposalDelegate = TVUpNextProposalDelegate()
  private var proposalController: TVUpNextProposalController?
  private var proposed: (id: PutioFileID, folderName: String?)?
  private var errorLogObservation: NSObjectProtocol?
  private var subtitleRenditions: [URL] = []
  private var renditionLoad: Task<Void, Never>?
  private var checkedErrorEvents = 0
  private var failureTurnedSubtitlesOff = false
  private var onSubtitleFailed: (@MainActor () -> Void)?

  init(
    subtitlePolicy: PutioSubtitleStartupPolicy = .accountDefault,
    subtitleMemory: PutioSubtitleMemory? = nil,
    speedStore: PutioAudioSpeedStore? = nil,
    backgroundNotification: Notification.Name? = PutioVideoPlayerSession
      .applicationBackgroundNotification,
    makePlayer: @escaping @MainActor (AVPlayerItem) -> AVPlayer = { AVPlayer(playerItem: $0) },
    applyStartSubtitle: (@MainActor (AVPlayerItem, AVPlayer?) async -> Void)? = nil
  ) {
    self.subtitlePolicy = subtitlePolicy
    self.subtitleMemory = subtitleMemory
    self.speedStore = speedStore ?? .video()
    self.backgroundNotification = backgroundNotification
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
    wait: PutioVideoWaitModel? = nil,
    onReady: @escaping @MainActor () -> Void = {},
    onSubtitleFailed: @escaping @MainActor () -> Void = {},
    onDurationKnown: @escaping @MainActor (Double) -> Void = { _ in },
    onEnded: @escaping @MainActor () -> Void = {},
    onRestarted: @escaping @MainActor () -> Void = {},
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
      backgroundNotification: backgroundNotification,
      positionPipeline: pipeline,
      applyDefaultSubtitle: { item in await applyStartSubtitle(item, created) })
    self.session = session
    self.onSubtitleFailed = onSubtitleFailed
    self.onReportsSettled = onReportsSettled
    waitForReports = { await pipeline.waitForPendingReports(fileID: fileID) }
    session.onSubtitleSelected = probes.map { probes in { probes.subtitle = $0 } }

    controller.speeds = PutioAudioSpeed.tvMenu.map {
      AVPlaybackSpeed(rate: $0.rawValue, localizedName: $0.title)
    }
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
        onReady()
        guard let self, let controller else { return }
        self.watchSubtitlePicks(of: item, controller: controller)
        self.watchSubtitleFailures(of: item, probes: probes)
        self.propose(self.proposalDelegate.proposal, in: controller)
      },
      onDurationKnown: onDurationKnown,
      observesPlaybackState: probes != nil,
      onAudioSelected: { probes?.audioLanguage = $0 },
      onPositionChanged: { probes?.currentPosition = $0 },
      onPlaybackEnded: { onEnded() },
      onPlaybackRestarted: { onRestarted() },
      onFailure: onFailure)
    controller.delegate = proposalDelegate
    proposed = nil
    if let player = session.player {
      if let chosen = controller.speeds.first(where: { $0.rate == speed.rawValue }) {
        controller.selectSpeed(chosen)
      }
      observe(player, probes: probes, wait: wait)
    }
    probes?.speeds = controller.speeds.map { TVPlaybackProbes.format($0.rate) }
  }

  func showNextFile(_ action: (@MainActor () -> Void)?, in controller: AVPlayerViewController) {
    let shown = nextFile != nil
    nextFile = action
    guard shown != (action != nil) else { return }
    controller.transportBarCustomMenuItems =
      action == nil
      ? []
      : [
        UIAction(
          title: String(localized: "Next file", bundle: .putioCore),
          image: UIImage(systemName: "forward.end.fill")
        ) { [weak self] _ in self?.nextFile?() }
      ]
  }

  func propose(_ proposal: TVUpNextProposal?, in controller: AVPlayerViewController) {
    proposalDelegate.proposal = proposal
    guard let item = player?.currentItem else { return }
    guard let proposal else {
      proposed = nil
      item.nextContentProposal = nil
      return
    }
    if let proposed, proposed.id == proposal.next.id, proposed.folderName == proposal.folderName {
      return
    }
    proposed = (proposal.next.id, proposal.folderName)
    let card = proposalController ?? TVUpNextProposalController()
    proposalController = card
    card.willAccept = { [weak self, weak controller] in
      guard let self, let controller else { return }
      self.stop(controller: controller)
    }
    card.show(proposal)
    controller.contentProposalViewController = card
    item.nextContentProposal = AVContentProposal(
      contentTimeForTransition: .indefinite, title: proposal.next.name, previewImage: nil)
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
    if let errorLogObservation {
      NotificationCenter.default.removeObserver(errorLogObservation)
    }
    errorLogObservation = nil
    renditionLoad?.cancel()
    renditionLoad = nil
    subtitleRenditions = []
    checkedErrorEvents = 0
    failureTurnedSubtitlesOff = false
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

  private func observe(_ player: AVPlayer, probes: TVPlaybackProbes?, wait: PutioVideoWaitModel?) {
    let speedStore = speedStore
    wait?.restart()
    observations = [
      player.observe(\.defaultRate, options: [.initial, .new]) { [weak probes] player, _ in
        let rate = player.defaultRate
        Task { @MainActor in
          probes?.speed = rate
          if let speed = PutioAudioSpeed(rawValue: rate) { speedStore.save(speed) }
        }
      }
    ]
    if let wait {
      observations.append(
        player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak wait] player, _ in
          let activity: PutioVideoPlayerActivity =
            switch player.timeControlStatus {
            case .playing: .playing
            case .waitingToPlayAtSpecifiedRate: .waiting
            default: .paused
            }
          let time = player.currentTime().seconds
          let seconds = time.isFinite ? Int(time) : nil
          Task { @MainActor in wait?.activityChanged(activity, atSeconds: seconds) }
        })
    }
    if let probes {
      observations.append(
        player.observe(\.rate, options: [.initial, .new]) { [weak probes] player, _ in
          let rate = player.rate
          Task { @MainActor in probes?.rate = rate }
        })
    }
  }

  private func watchSubtitleFailures(of item: AVPlayerItem, probes: TVPlaybackProbes?) {
    errorLogObservation = NotificationCenter.default.addObserver(
      forName: AVPlayerItem.newErrorLogEntryNotification, object: item, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.checkSubtitleFailures(of: item, probes: probes) }
    }
    guard let master = (item.asset as? AVURLAsset)?.url,
      master.scheme == "http" || master.scheme == "https",
      master.pathExtension.lowercased() == "m3u8"
    else { return }
    renditionLoad = Task { @MainActor [weak self] in
      guard let (data, _) = try? await URLSession.shared.data(from: master),
        let text = String(data: data, encoding: .utf8)
      else { return }
      guard let self, !Task.isCancelled else { return }
      subtitleRenditions = PutioSubtitleRenditions.uris(inMasterPlaylist: text, relativeTo: master)
      checkSubtitleFailures(of: item, probes: probes)
    }
  }

  private func checkSubtitleFailures(of item: AVPlayerItem, probes: TVPlaybackProbes?) {
    guard !subtitleRenditions.isEmpty, let events = item.errorLog()?.events else { return }
    let fresh = events.dropFirst(checkedErrorEvents).filter {
      $0.errorComment?.contains(#/HTTP [45]\d\d/#) == true
    }
    checkedErrorEvents = events.count
    let failing = Set(fresh.compactMap { $0.uri.flatMap(URL.init(string:))?.absoluteURL })
    let failedSegments = failing.filter { $0.pathExtension.lowercased() == "vtt" }
    guard !failing.isEmpty else { return }
    let renditions = subtitleRenditions
    Task { @MainActor [weak self] in
      guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
        let selected = item.currentMediaSelection.selectedMediaOption(in: group)
      else { return }
      let rendition = group.options.firstIndex(of: selected).flatMap {
        renditions.count == group.options.count ? renditions[$0] : nil
      }
      let failedPlaylist = rendition.map(failing.contains) ?? !failing.isDisjoint(with: renditions)
      var failedSegment = rendition == nil && !failedSegments.isEmpty
      if !failedPlaylist, !failedSegments.isEmpty, let rendition {
        failedSegment =
          await Self.segments(of: rendition).map { !$0.isDisjoint(with: failedSegments) } ?? false
      }
      guard let self, failedPlaylist || failedSegment,
        item.currentMediaSelection.selectedMediaOption(in: group) == selected
      else { return }
      failureTurnedSubtitlesOff = true
      item.select(nil, in: group)
      subtitleMemory?.forget(
        PutioSubtitleTrack(
          id: 0, title: selected.displayName,
          languageTag: selected.extendedLanguageTag ?? selected.locale?.identifier))
      probes?.subtitle = "off"
      onSubtitleFailed?()
    }
  }

  private static func segments(of rendition: URL) async -> Set<URL>? {
    guard let (data, _) = try? await URLSession.shared.data(from: rendition),
      let text = String(data: data, encoding: .utf8)
    else { return nil }
    return PutioSubtitleRenditions.segments(inMediaPlaylist: text, relativeTo: rendition)
  }

  private func watchSubtitlePicks(of item: AVPlayerItem, controller: AVPlayerViewController) {
    guard let subtitleMemory else { return }
    selectionObservation = NotificationCenter.default.addObserver(
      forName: AVPlayerItem.mediaSelectionDidChangeNotification, object: item, queue: .main
    ) { [weak self, weak controller] _ in
      MainActor.assumeIsolated {
        guard controller?.showsPlaybackControls == true else { return }
        Task { @MainActor in
          guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) else {
            return
          }
          let picked = item.currentMediaSelection.selectedMediaOption(in: group)
          if picked == nil, self?.failureTurnedSubtitlesOff == true { return }
          self?.failureTurnedSubtitlesOff = false
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
