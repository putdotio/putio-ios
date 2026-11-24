import AVFoundation
import Observation
import PutioCore
import SwiftUI

@MainActor
struct PutioVideoPlaybackView: View {
  @State private var model: PutioVideoPlaybackModel
  @State private var nextVideoModel: PutioVideoUpNextModel
  @State private var resumePrompter: PutioVideoResumePrompter
  @State private var retrySequence: UInt64 = 0
  @State private var playerIsReady = false
  @State private var observedPlaybackPosition: Int?
  @State private var selectedAudioLanguage: String?
  #if DEBUG
    @State private var selectedSubtitle: String?
    @State private var shownSubtitleText: String?
  #endif
  @State private var playbackReachedEnd = false
  @State private var reportedFaults: [PutioVideoPlayerFault] = []
  @State private var fallbacks = 0
  @State private var rememberedFallback = false
  @State private var conversionHistory = HarnessConversionHistory()
  @State private var nextVideoTransitionTask: Task<Void, Never>?
  @State private var playerFailureTask: Task<Void, Never>?
  @State private var transport: PutioVideoTransport
  private let fileID: PutioFileID
  private let title: String
  private let onDismiss: @MainActor @Sendable () -> Void
  private let onDurationKnown: @MainActor @Sendable (Double) -> Void
  private let preferredAudioLanguages: [String]
  private let selectsAVPlayerAudio: Bool
  private let remembersPlaybackPosition: Bool
  private let reportsPlayerFailures: Bool
  private let reportFailure: @MainActor @Sendable (PutioPlaybackFailureReport) -> Void
  private let showsHarnessReadiness: Bool
  private let positionPipeline: PutioPlaybackPositionPipeline
  private let reportPosition: PutioPlaybackPositionReport
  private let onPlayNext: @MainActor @Sendable (PutioPlayableNextVideo) -> Void
  private let castButton: AnyView?
  private let onCast: (@MainActor @Sendable () -> Void)?
  private let castHandOff: PutioVideoConvertedHandOff?
  private let onOpenInVLC: (() -> Void)?
  private let onFallbackPlays: @MainActor @Sendable () -> Void
  private let subtitlePolicy: PutioSubtitleStartupPolicy
  private let subtitleMemory: PutioSubtitleMemory?
  private let account: PutioAccountSnapshot?

  init(
    route: PutioVideoRoute,
    onDismiss: @escaping @MainActor @Sendable () -> Void,
    onDurationKnown: @escaping @MainActor @Sendable (Double) -> Void = { _ in },
    preferredAudioLanguages: [String] = [],
    selectsAVPlayerAudio: Bool = false,
    remembersPlaybackPosition: Bool = true,
    suggestsNextVideo: Bool = true,
    autoplayNextVideo: @escaping PutioNextVideoAutoplayPolicy = { false },
    reportsPlayerFailures: Bool = true,
    reportFailure: @escaping @MainActor @Sendable (PutioPlaybackFailureReport) -> Void,
    showsHarnessReadiness: Bool = false,
    conversionPollInterval: Duration = PutioVideoPlaybackModel.conversionPollInterval,
    upNextSleep: @escaping PutioNextVideoSleep = { try await Task.sleep(for: $0) },
    positionPipeline: PutioPlaybackPositionPipeline,
    reportPosition: @escaping PutioPlaybackPositionReport = { _, _ in },
    startConversion: @escaping PutioVideoConversionStart,
    loadConversionStatus: @escaping PutioVideoConversionStatusLoad,
    findNextVideo: @escaping PutioUpNextFind,
    prepareNextVideo: @escaping PutioUpNextPrepare,
    onPlayNext: @escaping @MainActor @Sendable (PutioPlayableNextVideo) -> Void,
    castButton: AnyView? = nil,
    onCast: (@MainActor @Sendable () -> Void)? = nil,
    castHandOff: PutioVideoConvertedHandOff? = nil,
    onOpenInVLC: (() -> Void)? = nil,
    onFallbackPlays: @escaping @MainActor @Sendable () -> Void = {},
    resolveConverted: PutioPlaybackResolve? = nil,
    subtitlePolicy: PutioSubtitleStartupPolicy = .accountDefault,
    subtitleMemory: PutioSubtitleMemory? = nil,
    account: PutioAccountSnapshot? = nil,
    resolve: @escaping PutioPlaybackResolve
  ) {
    self.account = account
    self.onFallbackPlays = onFallbackPlays
    self.castButton = castButton
    self.subtitlePolicy = subtitlePolicy
    self.subtitleMemory = subtitleMemory
    let transport = PutioVideoTransport()
    transport.onSubtitlePicked = { subtitleMemory?.remember($0) }
    transport.onSubtitleFailed = { subtitleMemory?.forget($0) }
    _transport = State(initialValue: transport)
    self.onCast = onCast
    self.castHandOff = castHandOff
    self.onOpenInVLC = onOpenInVLC
    self.fileID = route.id
    self.title = route.title
    self.onDismiss = onDismiss
    self.onDurationKnown = onDurationKnown
    self.preferredAudioLanguages = preferredAudioLanguages
    self.selectsAVPlayerAudio = selectsAVPlayerAudio
    self.remembersPlaybackPosition = remembersPlaybackPosition
    self.reportsPlayerFailures = reportsPlayerFailures
    self.reportFailure = reportFailure
    self.showsHarnessReadiness = showsHarnessReadiness
    self.positionPipeline = positionPipeline
    self.reportPosition = reportPosition
    self.onPlayNext = onPlayNext
    let resumePrompter = PutioVideoResumePrompter()
    _resumePrompter = State(initialValue: resumePrompter)
    _model = State(
      initialValue: PutioVideoPlaybackModel(
        fileID: route.id,
        initialResolution: route.initialResolution,
        conversionPollInterval: conversionPollInterval,
        startConversion: startConversion,
        loadConversionStatus: loadConversionStatus,
        chooseStart: PutioVideoStart.choice(
          for: route.start, remembersPosition: remembersPlaybackPosition,
          durationSeconds: { await PutioVideoLength.seconds(of: $0) },
          ask: { await resumePrompter.ask(positionSeconds: $0, durationSeconds: $1) }),
        handOffConverted: castHandOff,
        resolveConverted: resolveConverted.map { resolveConverted in
          { fileID in
            await positionPipeline.waitForPendingReports(fileID: fileID)
            return try await resolveConverted(fileID)
          }
        }
      ) { fileID in
        await positionPipeline.waitForPendingReports(fileID: fileID)
        return try await resolve(fileID)
      }
    )
    _nextVideoModel = State(
      initialValue: PutioVideoUpNextModel(
        fileID: route.id,
        suggestionsEnabled: suggestsNextVideo,
        autoplayEnabled: autoplayNextVideo,
        waitForReset: { completedFileID in
          await positionPipeline.waitForPendingReports(fileID: completedFileID)
        },
        find: findNextVideo,
        prepare: prepareNextVideo,
        sleep: upNextSleep
      )
    )
  }

  var body: some View {
    ZStack {
      content
      PutioVideoSubtitleOverlay(
        cues: transport.subtitleCues, size: transport.subtitleSize, picture: transport.picture)
      if isReady, nextVideoFailed {
        nextVideoFailure
      } else if isReady, !transport.wait.state.hidesControls {
        PutioVideoControls(
          title: title, transport: transport, onClose: onDismiss, upNext: upNext
        ) {
          castControls
        }
      } else {
        if isReady { waitState }
        VStack {
          PutioVideoTopBar(
            title: title, showsTrailing: showsCastWhileWaiting, onClose: onDismiss
          ) { castControls }
          Spacer()
        }
        .padding(PutioTheme.Spacing.space3)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.black)
    .putioVideoResumeAlert(resumePrompter)
    .task {
      await model.loadIfNeeded()
    }
    .task {
      await nextVideoModel.lookUp()
    }
    .task(id: retrySequence) {
      guard retrySequence > 0 else { return }
      playerIsReady = false
      await model.retry()
    }
    .onChange(of: model.state) { _, state in
      conversionHistory.record(state)
    }
    .onChange(of: nextVideoModel.state) { _, state in
      guard case .playing(let nextVideo) = state else { return }
      onPlayNext(nextVideo)
    }
    .onChange(of: castHandOff?.connection()) { _, connection in
      guard connection != nil else { return }
      model.receiverConnected(
        preparing: transport.wait.state == .preparing,
        playingAtSeconds: transport.isPlaying
          ? PutioVideoPositionReporter.normalizedPosition(
            seconds: transport.timeline.elapsedSeconds) : nil,
        tracks: transport.trackChoice)
    }
    .onChange(of: transport.wait.state) { _, wait in
      if wait != .preparing { model.playbackStarted() }
    }
    .onChange(of: nextVideoFailed) { _, failed in
      if failed, transport.isPlaying { transport.togglePlayPause() }
    }
    .onDisappear {
      playerFailureTask?.cancel()
      playerFailureTask = nil
      cancelNextVideo()
    }
    .overlay(alignment: .bottom) {
      nextVideoProbe
    }
    .overlay(alignment: .topLeading) {
      if showsHarnessReadiness {
        ZStack {
          if case .ready(let source) = model.state {
            Color.clear
              .frame(width: 1, height: 1)
              .accessibilityElement(children: .ignore)
              .accessibilityLabel("Resume position")
              .accessibilityValue("\(source.startFromSeconds)")
              .accessibilityIdentifier("video.resume-position")
              .allowsHitTesting(false)
          }
          if playerIsReady {
            Color.clear
              .frame(width: 1, height: 1)
              .accessibilityElement(children: .ignore)
              .accessibilityLabel("Video ready")
              .accessibilityIdentifier("video.ready")
              .allowsHitTesting(false)
          }
          if case .ready(let source) = model.state {
            Color.clear
              .frame(width: 1, height: 1)
              .accessibilityElement(children: .ignore)
              .accessibilityLabel("Video source")
              .accessibilityValue(Self.harnessSourceName(source))
              .accessibilityIdentifier("video.source")
              .allowsHitTesting(false)
          }
          if let selectedAudioLanguage {
            Color.clear
              .frame(width: 1, height: 1)
              .accessibilityElement(children: .ignore)
              .accessibilityLabel("Selected audio language")
              .accessibilityValue(selectedAudioLanguage)
              .accessibilityIdentifier("video.audio-language")
              .allowsHitTesting(false)
          }
          #if DEBUG
            if let shownSubtitleText {
              Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Shown subtitle text")
                .accessibilityValue(shownSubtitleText)
                .accessibilityIdentifier("video.subtitle-text")
                .allowsHitTesting(false)
            }
            if let shownCaption = transport.shownCaption {
              Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Shown caption")
                .accessibilityValue(shownCaption)
                .accessibilityIdentifier("video.caption-shown")
                .allowsHitTesting(false)
            }
            if let selectedSubtitle {
              Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Selected subtitle")
                .accessibilityValue(selectedSubtitle)
                .accessibilityIdentifier("video.subtitle")
                .allowsHitTesting(false)
            }
          #endif
          if let observedPlaybackPosition {
            Color.clear
              .frame(width: 1, height: 1)
              .accessibilityElement(children: .ignore)
              .accessibilityLabel("Current playback position")
              .accessibilityValue("\(observedPlaybackPosition)")
              .accessibilityIdentifier("video.current-position")
              .allowsHitTesting(false)
          }
          if playbackReachedEnd {
            Color.clear
              .frame(width: 1, height: 1)
              .accessibilityElement(children: .ignore)
              .accessibilityLabel("Playback reached end")
              .accessibilityIdentifier("video.ended")
              .allowsHitTesting(false)
          }
          if let conversionHistory = conversionHistory.value {
            Color.clear
              .frame(width: 1, height: 1)
              .accessibilityElement(children: .ignore)
              .accessibilityLabel("Observed conversion states")
              .accessibilityValue(conversionHistory)
              .accessibilityIdentifier("video.conversion-history")
              .allowsHitTesting(false)
          }
          if fallbacks > 0 {
            Color.clear
              .frame(width: 1, height: 1)
              .accessibilityElement(children: .ignore)
              .accessibilityLabel("Converted fallbacks")
              .accessibilityValue("\(fallbacks)")
              .accessibilityIdentifier("video.fallbacks")
              .allowsHitTesting(false)
          }
          if !reportedFaults.isEmpty {
            Color.clear
              .frame(width: 1, height: 1)
              .accessibilityElement(children: .ignore)
              .accessibilityLabel("Reported player failures")
              .accessibilityValue(reportedFaults.map(\.rawValue).joined(separator: ","))
              .accessibilityIdentifier("video.reported-failures")
              .allowsHitTesting(false)
          }
        }
      }
    }
  }

  private static func harnessSourceName(_ source: PutioPlaybackSource) -> String {
    switch source.original?.player {
    case .engine?: "original-engine"
    case .avPlayer?: "original-avplayer"
    case nil: "stream"
    }
  }

  private var isReady: Bool {
    if case .ready = model.state { return true }
    return false
  }

  private var showsCastWhileWaiting: Bool {
    guard castButton != nil || onCast != nil else { return false }
    if case .loading = model.state { return false }
    return !isReady
  }

  @ViewBuilder
  private var waitState: some View {
    switch transport.wait.state {
    case .preparing:
      PutioLoadingStateView(title: String(localized: "Preparing video"))
        .accessibilityIdentifier("video.preparing")
    case .stalled:
      ZStack {
        Color.black.ignoresSafeArea()
        PutioErrorStateView(
          icon: .warningCircle, title: String(localized: "Playback stalled"), message: nil,
          retryIdentifier: "video.stalled.retry"
        ) {
          transport.reload()
        }
        .secondaryAction(
          String(localized: "Back"), identifier: "video.stalled.back", perform: onDismiss
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("video.stalled")
      }
    case .clear, .buffering, .bufferingLong:
      EmptyView()
    }
  }

  @ViewBuilder
  private var castControls: some View {
    if let castButton {
      castButton
    }
    if let onCast {
      PutioButton(String(localized: "Cast"), tier: .secondary, size: .small) {
        onCast()
      }
      .accessibilityIdentifier("video.cast")
    }
  }

  private var nextVideoFailed: Bool {
    nextVideoModel.state == .failed
  }

  private var upNext: PutioVideoUpNext? {
    let offer: PutioVideoUpNext.Offer
    switch nextVideoModel.state {
    case .countingDown(let next, let secondsLeft):
      offer = .card(name: next.name, secondsLeft: secondsLeft)
    case .finding, .playing:
      guard nextVideoModel.upcoming != nil else { return nil }
      offer = .chip(busy: true)
    case .idle, .failed:
      guard nextVideoModel.upcoming != nil else { return nil }
      offer = .chip(busy: false)
    }
    return PutioVideoUpNext(
      offer: offer,
      onPlay: { startNextVideoTask { await nextVideoModel.playNext() } },
      onCancel: { cancelNextVideo() })
  }

  private var nextVideoFailure: some View {
    ZStack {
      Color.black.opacity(0.75).ignoresSafeArea()
      PutioErrorStateView(
        icon: .warningCircle, title: String(localized: "Couldn’t find the next video"),
        message: nil, retryIdentifier: "video.next-error.retry"
      ) {
        startNextVideoTask { await nextVideoModel.retry() }
      }
      .secondaryAction(
        String(localized: "Cancel"), identifier: "video.next-error.cancel",
        perform: cancelNextVideo
      )
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("video.next-error")
      VStack {
        PutioVideoTopBar(title: title, showsTrailing: false, onClose: onDismiss) {
          EmptyView()
        }
        Spacer()
      }
      .padding(PutioTheme.Spacing.space3)
    }
  }

  private func startNextVideoTask(_ operation: @escaping @MainActor () async -> Void) {
    let previous = nextVideoTransitionTask
    nextVideoTransitionTask = Task { @MainActor in await operation() }
    previous?.cancel()
  }

  private func cancelNextVideo() {
    nextVideoTransitionTask?.cancel()
    nextVideoTransitionTask = nil
    nextVideoModel.cancel()
  }

  @ViewBuilder
  private var nextVideoProbe: some View {
    if showsHarnessReadiness, nextVideoModel.lookupSettled {
      Color.clear
        .frame(width: 1, height: 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Next video lookup")
        .accessibilityValue(nextVideoModel.upcoming.map { "id=\($0.id.rawValue)" } ?? "none")
        .accessibilityIdentifier("video.next-lookup")
        .allowsHitTesting(false)
    }
  }

  private var playerCallbacks: PutioVideoPlayerCallbacks {
    var callbacks = PutioVideoPlayerCallbacks(
      onReady: {
        playerIsReady = true
        model.playerReady()
        if model.playsConvertedFallback, !rememberedFallback {
          rememberedFallback = true
          onFallbackPlays()
        }
      },
      onDurationKnown: onDurationKnown,
      observesPlaybackState: showsHarnessReadiness,
      onAudioSelected: { selectedAudioLanguage = $0 },
      onPositionChanged: { observedPlaybackPosition = $0 },
      onPlaybackEnded: {
        playbackReachedEnd = true
        guard !nextVideoModel.isPlayingChosenVideo else { return }
        startNextVideoTask { await nextVideoModel.playbackEnded() }
      },
      onPlaybackRestarted: {
        if playbackReachedEnd { cancelNextVideo() }
        playbackReachedEnd = false
      },
      onFailure: { failure in
        playerIsReady = false
        guard reportsPlayerFailures else { return }
        let report = model.failureReport(
          failure.error, beforeFirstFrame: failure.beforeFirstFrame, platform: .ios)
        if model.fallsBack(after: failure.fault, beforeFirstFrame: failure.beforeFirstFrame) {
          fallbacks += 1
        } else {
          reportedFaults.append(failure.fault)
        }
        if let report { reportFailure(report) }
        playerFailureTask?.cancel()
        playerFailureTask = Task {
          let refreshFailure = await model.playerFailed(
            failure.fault, heldSeconds: failure.heldSeconds,
            beforeFirstFrame: failure.beforeFirstFrame)
          if let refreshFailure { reportFailure(refreshFailure) }
        }
      })
    #if DEBUG
      callbacks.onSubtitleSelected = { selectedSubtitle = $0 }
    #endif
    return callbacks
  }

  @ViewBuilder
  private var content: some View {
    switch model.state {
    case .loading:
      PutioLoadingStateView(title: String(localized: "Preparing video"))
        .accessibilityIdentifier("video.loading")
    case .ready(let source):
      let callbacks = playerCallbacks
      Group {
        if source.original?.player == .engine {
          PutioDirectPlayerView(
            fileID: fileID,
            source: source,
            transport: transport,
            preferredAudioLanguages: preferredAudioLanguages,
            remembersPlaybackPosition: remembersPlaybackPosition,
            subtitlePolicy: subtitlePolicy,
            subtitleMemory: subtitleMemory,
            positionPipeline: positionPipeline,
            reportPosition: reportPosition,
            callbacks: callbacks
          )
        } else {
          PutioVideoPlayerView(
            fileID: fileID,
            source: source,
            transport: transport,
            preferredAudioLanguages: selectsAVPlayerAudio ? preferredAudioLanguages : [],
            subtitlePolicy: subtitlePolicy,
            subtitleMemory: subtitleMemory,
            remembersPlaybackPosition: remembersPlaybackPosition,
            positionPipeline: positionPipeline,
            reportPosition: reportPosition,
            onReady: callbacks.onReady,
            onDurationKnown: callbacks.onDurationKnown,
            observesPlaybackState: callbacks.observesPlaybackState,
            onAudioSelected: callbacks.onAudioSelected,
            onPositionChanged: callbacks.onPositionChanged,
            onPlaybackEnded: callbacks.onPlaybackEnded,
            onPlaybackRestarted: callbacks.onPlaybackRestarted,
            onFailure: callbacks.onFailure
          )
          #if DEBUG
            .onSubtitleSelected(callbacks.onSubtitleSelected)
            .onSubtitleTextShown { shownSubtitleText = $0 }
          #endif
        }
      }
      .ignoresSafeArea()
      .id(model.playerAttempt)
    case .conversionRequired:
      conversionGate(.waiting)
        .accessibilityIdentifier("video.conversion-required")
    case .conversionQueued:
      conversionGate(.waiting)
        .accessibilityIdentifier("video.conversion-queued")
    case .converting(let progress):
      conversionGate(.converting(progress: progress))
        .accessibilityIdentifier("video.conversion-converting")
    case .conversionCompleted:
      conversionGate(.converting(progress: 1))
        .accessibilityIdentifier("video.conversion-completed")
    case .failed(let failure):
      if let notice = failure.inactiveAccountNotice(for: account) {
        PutioErrorStateView(
          title: notice.title,
          message: notice.daysUntilFilesDeleted().map(
            PutioInactiveAccountNotice.filesDeletionMessage)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("video.account-notice")
      } else {
        failureView(failure)
          .accessibilityIdentifier("video.error")
      }
    }
  }

  private func unsupportedMessage(_ failure: PutioVideoPlaybackFailure) -> String {
    switch UIDevice.current.userInterfaceIdiom {
    case .phone:
      String(
        localized: "This iPhone can’t play the original file, and it has no converted version.")
    case .pad:
      String(
        localized: "This iPad can’t play the original file, and it has no converted version.")
    default:
      failure.message
    }
  }

  private func conversionGate(_ phase: PutioVideoConversionGate.Phase) -> some View {
    PutioVideoConversionGate(phase: phase, onCancel: onDismiss, onOpenInVLC: onOpenInVLC)
      .accessibilityElement(children: .contain)
  }

  @ViewBuilder
  private func failureView(_ failure: PutioVideoPlaybackFailure) -> some View {
    switch failure.kind {
    case .accessExpired, .connectionLost:
      PutioErrorStateView(
        icon: failure.kind == .connectionLost ? .wifiSlash : .warningCircle,
        title: failure.title,
        message: failure.message
      ) {
        retrySequence &+= 1
      }
    case .conversion:
      PutioErrorStateView(
        icon: .warningCircle, title: failure.title, message: failure.message,
        actionTitle: String(localized: "Convert again"),
        actionIdentifier: "video.conversion.convert-again", prominent: true
      ) {
        retrySequence &+= 1
      }
    case .conversionStatus:
      PutioErrorStateView(
        icon: .wifiSlash, title: failure.title, message: failure.message,
        retryIdentifier: "video.conversion.check-again"
      ) {
        retrySequence &+= 1
      }
    case .conversionUnavailable:
      PutioErrorStateView(
        icon: .warningCircle, title: failure.title, message: failure.message,
        actionTitle: String(localized: "Open in VLC"),
        actionIdentifier: "video.conversion.vlc", prominent: false, action: onOpenInVLC)
    case .unsupported:
      PutioErrorStateView(
        icon: .warningCircle, title: failure.title, message: unsupportedMessage(failure),
        actionTitle: String(localized: "Open in VLC"),
        actionIdentifier: "video.unsupported.vlc", prominent: false, action: onOpenInVLC)
    case .notFound, .rateLimited, .transient, .invalidResponse, .playback, .unknown:
      PutioErrorStateView(
        title: failure.title,
        message: failure.message,
        retryTitle: String(localized: "Try again")
      ) {
        retrySequence &+= 1
      }
    }
  }
}

/// A conversion state under app.put.io's explanation of why the video waits.
/// Centered when it fits; large text in landscape scrolls instead of clipping.
struct PutioConversionStatusView<Status: View>: View {
  @ViewBuilder let status: Status

  var body: some View {
    ViewThatFits(in: .vertical) {
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      ScrollView {
        content
          .frame(maxWidth: .infinity)
      }
    }
  }

  private var content: some View {
    VStack(spacing: PutioTheme.Spacing.space5) {
      Text(PutioVideoPlaybackState.conversionExplanation)
        .putioFont(PutioTheme.Typography.body)
        .foregroundStyle(PutioTheme.Colors.textPrimary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("conversion.explanation")
      status
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(PutioTheme.Spacing.space4)
    .frame(maxWidth: 480)
  }
}

private struct PutioVideoPlayerView: UIViewRepresentable {
  let fileID: PutioFileID
  let source: PutioPlaybackSource
  let transport: PutioVideoTransport
  let preferredAudioLanguages: [String]
  let subtitlePolicy: PutioSubtitleStartupPolicy
  let subtitleMemory: PutioSubtitleMemory?
  let remembersPlaybackPosition: Bool
  let positionPipeline: PutioPlaybackPositionPipeline
  let reportPosition: PutioPlaybackPositionReport
  let onReady: @MainActor @Sendable () -> Void
  let onDurationKnown: @MainActor @Sendable (Double) -> Void
  let observesPlaybackState: Bool
  let onAudioSelected: @MainActor @Sendable (String) -> Void
  let onPositionChanged: @MainActor @Sendable (Int) -> Void
  let onPlaybackEnded: @MainActor @Sendable () -> Void
  let onPlaybackRestarted: @MainActor @Sendable () -> Void
  let onFailure: @MainActor @Sendable (PutioVideoPlayerFailure) -> Void
  #if DEBUG
    var subtitleSelected: (@MainActor @Sendable (String) -> Void)?

    var subtitleTextShown: (@MainActor @Sendable (String) -> Void)?

    func onSubtitleSelected(_ action: @escaping @MainActor @Sendable (String) -> Void) -> Self {
      var player = self
      player.subtitleSelected = action
      return player
    }

    func onSubtitleTextShown(_ action: @escaping @MainActor @Sendable (String) -> Void) -> Self {
      var player = self
      player.subtitleTextShown = action
      return player
    }
  #endif

  func makeCoordinator() -> PutioVideoPlayerCoordinator {
    PutioVideoPlayerCoordinator(
      positionPipeline: positionPipeline, subtitlePolicy: subtitlePolicy,
      subtitleMemory: subtitleMemory)
  }

  func makeUIView(context: Context) -> PutioVideoSurfaceView {
    let surface = PutioVideoSurfaceView()
    let transport = transport
    transport.originalAudioStreams = source.original?.audioStreams ?? []
    surface.pictureInPicture = transport.pictureInPicture
    surface.onPlayerChange = { old, new in transport.playerChanged(from: old, to: new) }
    surface.onPlaybackControlsChange = { [weak surface] shown in
      transport.setControlsEnabled(shown, for: surface?.player)
    }
    let coordinator = context.coordinator
    transport.onReload = { [weak coordinator] tracks in coordinator?.reload(restoring: tracks) }
    #if DEBUG
      if let subtitleSelected {
        context.coordinator.onSubtitleSelected = { subtitle in subtitleSelected(subtitle) }
      }
      if let subtitleTextShown {
        context.coordinator.onSubtitleTextShown = { text in subtitleTextShown(text) }
      }
    #endif
    context.coordinator.start(
      fileID: fileID,
      source: source,
      preferredAudioLanguages: preferredAudioLanguages,
      remembersPlaybackPosition: remembersPlaybackPosition,
      reportPosition: { try await reportPosition($0, $1) },
      in: surface,
      onReady: onReady,
      onDurationKnown: { onDurationKnown($0) },
      observesPlaybackState: observesPlaybackState,
      onAudioSelected: { code in onAudioSelected(code) },
      onPositionChanged: { position in onPositionChanged(position) },
      onPlaybackEnded: { onPlaybackEnded() },
      onPlaybackRestarted: { onPlaybackRestarted() },
      onFailure: onFailure
    )
    return surface
  }

  func updateUIView(_ surface: PutioVideoSurfaceView, context: Context) {}

  static func dismantleUIView(
    _ surface: PutioVideoSurfaceView,
    coordinator: PutioVideoPlayerCoordinator
  ) {
    coordinator.stop(surface: surface)
  }
}

typealias PutioVideoPlayerCoordinator = PutioVideoPlayerSession

extension PutioVideoSurfaceView: PutioVideoPlayerSurface {}
