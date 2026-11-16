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
  @State private var conversionHistory: [String] = []
  @State private var nextVideoTransitionTask: Task<Void, Never>?
  @State private var playerFailureTask: Task<Void, Never>?
  @State private var transport: PutioVideoTransport
  private let fileID: PutioFileID
  private let title: String
  private let onDismiss: @MainActor @Sendable () -> Void
  private let onDurationKnown: @MainActor @Sendable (Double) -> Void
  private let preferredAudioLanguages: [String]
  private let remembersPlaybackPosition: Bool
  private let reportsPlayerFailures: Bool
  private let reportFailure: @MainActor @Sendable (PutioVideoPlayerFault) -> Void
  private let showsHarnessReadiness: Bool
  private let positionPipeline: PutioPlaybackPositionPipeline
  private let reportPosition: PutioPlaybackPositionReport
  private let onPlayNext: @MainActor @Sendable (PutioPlayableNextVideo) -> Void
  private let castButton: AnyView?
  private let onCast: (@MainActor @Sendable () -> Void)?
  private let castHandOff: PutioVideoConvertedHandOff?
  private let onOpenInVLC: (() -> Void)?
  private let onFallback: @MainActor @Sendable () -> Void
  private let onFallbackPlays: @MainActor @Sendable () -> Void
  private let subtitlePolicy: PutioSubtitleStartupPolicy
  private let subtitleMemory: PutioSubtitleMemory?
  private let loadSubtitleListings: PutioSubtitleListingsLoad

  init(
    route: PutioVideoRoute,
    onDismiss: @escaping @MainActor @Sendable () -> Void,
    onDurationKnown: @escaping @MainActor @Sendable (Double) -> Void = { _ in },
    preferredAudioLanguages: [String] = [],
    remembersPlaybackPosition: Bool = true,
    suggestsNextVideo: Bool = true,
    autoplayNextVideo: @escaping PutioNextVideoAutoplayPolicy = { false },
    reportsPlayerFailures: Bool = true,
    reportFailure: @escaping @MainActor @Sendable (PutioVideoPlayerFault) -> Void,
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
    onFallback: @escaping @MainActor @Sendable () -> Void = {},
    onFallbackPlays: @escaping @MainActor @Sendable () -> Void = {},
    resolveConverted: PutioPlaybackResolve? = nil,
    subtitlePolicy: PutioSubtitleStartupPolicy = .accountDefault,
    subtitleMemory: PutioSubtitleMemory? = nil,
    loadSubtitleListings: @escaping PutioSubtitleListingsLoad = { _ in [] },
    resolve: @escaping PutioPlaybackResolve
  ) {
    self.onFallback = onFallback
    self.onFallbackPlays = onFallbackPlays
    self.castButton = castButton
    self.subtitlePolicy = subtitlePolicy
    self.subtitleMemory = subtitleMemory
    self.loadSubtitleListings = route.subtitleListings(loadSubtitleListings)
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
          ask: { await resumePrompter.ask(positionSeconds: $0) }),
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
      PutioVideoSubtitleOverlay(cues: transport.subtitleCues, size: transport.subtitleSize)
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
      transport.subtitleListings = (try? await loadSubtitleListings(fileID)) ?? []
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
      recordConversionState(state)
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
          if !conversionHistory.isEmpty {
            Color.clear
              .frame(width: 1, height: 1)
              .accessibilityElement(children: .ignore)
              .accessibilityLabel("Observed conversion states")
              .accessibilityValue(conversionHistory.joined(separator: ","))
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
        if model.fallsBack(after: failure.fault, beforeFirstFrame: failure.beforeFirstFrame) {
          fallbacks += 1
          onFallback()
        } else {
          reportedFaults.append(failure.fault)
          reportFailure(failure.fault)
        }
        playerFailureTask?.cancel()
        playerFailureTask = Task {
          await model.playerFailed(
            failure.fault, heldSeconds: failure.heldSeconds,
            beforeFirstFrame: failure.beforeFirstFrame)
        }
      })
    #if DEBUG
      callbacks.onSubtitleSelected = { selectedSubtitle = $0 }
    #endif
    return callbacks
  }

  private func recordConversionState(_ state: PutioVideoPlaybackState) {
    let phase: String
    switch state {
    case .conversionQueued:
      phase = "queued"
    case .converting:
      phase = "converting"
    case .conversionCompleted:
      phase = "completed"
    case .loading, .ready, .conversionRequired, .failed:
      return
    }
    guard conversionHistory.last != phase else { return }
    conversionHistory.append(phase)
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
            preferredAudioLanguages: preferredAudioLanguages,
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
      failureView(failure)
        .accessibilityIdentifier("video.error")
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

struct PutioVideoPlayerFailure: Equatable, Sendable {
  let fault: PutioVideoPlayerFault
  let heldSeconds: Int?
  var beforeFirstFrame = false
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

@MainActor
protocol PutioVideoPlayerDriving: AnyObject {
  var player: AVPlayer { get }
  var currentTime: CMTime { get }
  var itemDuration: CMTime { get }

  func play()
  func seek(to time: CMTime, completion: @escaping @Sendable (Bool) -> Void)
  func observePosition(
    every interval: CMTime,
    callback: @escaping @Sendable (CMTime) -> Void
  ) -> Any
  func removePositionObservation(_ observation: Any)
  func stop()
}

@MainActor
private final class PutioVideoPlayerDriver: PutioVideoPlayerDriving {
  let player: AVPlayer

  var currentTime: CMTime {
    player.currentTime()
  }

  var itemDuration: CMTime {
    player.currentItem?.duration ?? .invalid
  }

  init(item: AVPlayerItem) {
    player = AVPlayer(playerItem: item)
  }

  func play() {
    player.play()
  }

  func seek(to time: CMTime, completion: @escaping @Sendable (Bool) -> Void) {
    player.seek(
      to: time,
      toleranceBefore: .zero,
      toleranceAfter: .zero,
      completionHandler: completion
    )
  }

  func observePosition(
    every interval: CMTime,
    callback: @escaping @Sendable (CMTime) -> Void
  ) -> Any {
    player.addPeriodicTimeObserver(forInterval: interval, queue: .main, using: callback)
  }

  func removePositionObservation(_ observation: Any) {
    player.removeTimeObserver(observation)
  }

  func stop() {
    player.currentItem?.cancelPendingSeeks()
    player.pause()
    player.replaceCurrentItem(with: nil)
  }
}

@MainActor
protocol PutioPlaybackAudioSessioning: AnyObject {
  func activate() throws
  func deactivate()
}

@MainActor
private final class PutioPlaybackAudioSession: PutioPlaybackAudioSessioning {
  func activate() throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playback, mode: .moviePlayback)
    try session.setActive(true)
  }

  func deactivate() {
    try? AVAudioSession.sharedInstance().setActive(
      false,
      options: .notifyOthersOnDeactivation
    )
  }
}

@MainActor
protocol PutioPlayerItemStatusObservation: AnyObject {
  func invalidate()
}

extension NSKeyValueObservation: PutioPlayerItemStatusObservation {}

@MainActor
final class PutioVideoPlayerCoordinator {
  typealias DefaultSubtitleApplier = @MainActor (AVPlayerItem) async -> Void
  typealias TrackRestorer = @MainActor (PutioVideoTrackSelection, AVPlayerItem) async -> Void
  typealias DriverFactory = @MainActor (AVPlayerItem) -> any PutioVideoPlayerDriving
  typealias DurationLoader = @MainActor (AVPlayerItem) async -> Double?
  typealias PositionReportScheduler = PutioVideoPositionReporter.Scheduler
  typealias StatusObserverFactory =
    @MainActor (
      AVPlayerItem,
      @escaping @Sendable (AVPlayerItem.Status) -> Void
    ) -> any PutioPlayerItemStatusObservation

  private let makeItem: @MainActor (URL) -> AVPlayerItem
  private let makeDriver: DriverFactory
  private let observeItemStatus: StatusObserverFactory
  private let selectedAudioLanguage: @MainActor (AVPlayerItem) async -> String?
  private let applyDefaultSubtitle: DefaultSubtitleApplier
  private let restoreTracks: TrackRestorer
  private let audioSession: any PutioPlaybackAudioSessioning
  private let notificationCenter: NotificationCenter
  private let positionPipeline: PutioPlaybackPositionPipeline
  private let schedulePositionReports: PositionReportScheduler
  private let loadDuration: DurationLoader
  private var statusObservation: (any PutioPlayerItemStatusObservation)?
  private var positionReporter: PutioVideoPositionReporter?
  private var positionObservation: Any?
  private var failedToEndObservation: NSObjectProtocol?
  private var playedToEndObservation: NSObjectProtocol?
  private var timeJumpedObservation: NSObjectProtocol?
  private var mediaSelectionObservation: NSObjectProtocol?
  private var positionSaveObservations: [NSObjectProtocol] = []
  private var driver: (any PutioVideoPlayerDriving)?
  private var onReady: (@MainActor () -> Void)?
  private var onDurationKnown: (@MainActor (Double) -> Void)?
  private var onAudioSelected: (@MainActor @Sendable (String) -> Void)?
  #if DEBUG
    /// Harness probe; set before `start` and reported only while observing.
    var onSubtitleSelected: (@MainActor @Sendable (String) -> Void)?
    var onSubtitleTextShown: (@MainActor @Sendable (String) -> Void)?
    private var subtitleTextProbe: PutioSubtitleTextProbe?
  #endif
  private var observesPlaybackState = false
  private var onPositionChanged: (@MainActor @Sendable (Int) -> Void)?
  private var onPlaybackEnded: (@MainActor @Sendable () -> Void)?
  private var onPlaybackRestarted: (@MainActor @Sendable () -> Void)?
  private var onFailure: (@MainActor (PutioVideoPlayerFailure) -> Void)?
  private var generation: UInt64 = 0
  private var readyReported = false
  private var defaultSubtitleRequested = false
  private var failureReported = false
  private var positionEstablished = false
  private var recoveredStartSeconds: Int?
  private var fileID: PutioFileID?
  private var audioSessionIsActive = false
  private var pendingControlGates: Set<ControlGate> = []
  private weak var surface: PutioVideoSurfaceView?
  private var reloadAt: (@MainActor (Int?, PutioVideoTrackSelection?) -> Void)?

  private enum ControlGate {
    case audio
    case defaultSubtitle
    case position
  }

  convenience init() {
    self.init(
      makeDriver: { PutioVideoPlayerDriver(item: $0) },
      audioSession: PutioPlaybackAudioSession(),
      notificationCenter: .default,
      positionPipeline: PutioPlaybackPositionPipeline()
    )
  }

  convenience init(
    positionPipeline: PutioPlaybackPositionPipeline,
    subtitlePolicy: PutioSubtitleStartupPolicy,
    subtitleMemory: PutioSubtitleMemory?
  ) {
    self.init(
      makeDriver: { PutioVideoPlayerDriver(item: $0) },
      audioSession: PutioPlaybackAudioSession(),
      notificationCenter: .default,
      positionPipeline: positionPipeline,
      applyDefaultSubtitle: {
        await PutioVideoPlayerCoordinator.selectStartSubtitle(
          in: $0, policy: subtitlePolicy, remembered: subtitleMemory?.remembered)
      }
    )
  }

  init(
    makeItem: @escaping @MainActor (URL) -> AVPlayerItem = { AVPlayerItem(url: $0) },
    makeDriver: @escaping DriverFactory,
    observeItemStatus: @escaping StatusObserverFactory = { item, statusChanged in
      item.observe(\.status, options: [.initial, .new]) { item, _ in
        statusChanged(item.status)
      }
    },
    audioSession: any PutioPlaybackAudioSessioning,
    notificationCenter: NotificationCenter,
    positionPipeline: PutioPlaybackPositionPipeline,
    selectedAudioLanguage: @escaping @MainActor (AVPlayerItem) async -> String? = {
      await PutioVideoPlayerCoordinator.selectedAudioLanguage(in: $0)
    },
    applyDefaultSubtitle: @escaping DefaultSubtitleApplier = {
      await PutioVideoPlayerCoordinator.selectDefaultSubtitle(in: $0)
    },
    restoreTracks: @escaping TrackRestorer = {
      await PutioVideoPlayerCoordinator.restore($0, in: $1)
    },
    schedulePositionReports: @escaping PositionReportScheduler = { interval, callback in
      PutioMonotonicPositionReportSchedule(interval: interval, callback: callback)
    },
    loadDuration: @escaping DurationLoader = {
      await PutioVideoPlayerCoordinator.duration(of: $0)
    }
  ) {
    self.makeItem = makeItem
    self.makeDriver = makeDriver
    self.observeItemStatus = observeItemStatus
    self.selectedAudioLanguage = selectedAudioLanguage
    self.applyDefaultSubtitle = applyDefaultSubtitle
    self.restoreTracks = restoreTracks
    self.audioSession = audioSession
    self.notificationCenter = notificationCenter
    self.positionPipeline = positionPipeline
    self.schedulePositionReports = schedulePositionReports
    self.loadDuration = loadDuration
  }

  @discardableResult
  func start(
    fileID: PutioFileID = .root,
    source: PutioPlaybackSource,
    preferredAudioLanguages: [String] = [],
    remembersPlaybackPosition: Bool = true,
    reportPosition: @escaping PutioPlaybackPositionReport = { _, _ in },
    in surface: PutioVideoSurfaceView,
    onReady: @escaping @MainActor () -> Void = {},
    onDurationKnown: @escaping @MainActor (Double) -> Void = { _ in },
    observesPlaybackState: Bool = false,
    onAudioSelected: @escaping @MainActor @Sendable (String) -> Void = { _ in },
    onPositionChanged: @escaping @MainActor @Sendable (Int) -> Void = { _ in },
    onPlaybackEnded: @escaping @MainActor @Sendable () -> Void = {},
    onPlaybackRestarted: @escaping @MainActor @Sendable () -> Void = {},
    reloadingAt reloadSeconds: Int? = nil,
    restoringTracks restoredTracks: PutioVideoTrackSelection? = nil,
    onFailure: @escaping @MainActor (PutioVideoPlayerFailure) -> Void
  ) -> Bool {
    reloadAt = { [weak self, weak surface] seconds, tracks in
      guard let self, let surface else { return }
      stop(surface: surface)
      start(
        fileID: fileID, source: source, preferredAudioLanguages: preferredAudioLanguages,
        remembersPlaybackPosition: remembersPlaybackPosition, reportPosition: reportPosition,
        in: surface, onReady: onReady, onDurationKnown: onDurationKnown,
        observesPlaybackState: observesPlaybackState, onAudioSelected: onAudioSelected,
        onPositionChanged: onPositionChanged, onPlaybackEnded: onPlaybackEnded,
        onPlaybackRestarted: onPlaybackRestarted, reloadingAt: seconds,
        restoringTracks: tracks, onFailure: onFailure)
    }
    generation &+= 1
    let playbackGeneration = generation
    readyReported = false
    defaultSubtitleRequested = false
    failureReported = false
    positionEstablished = false
    recoveredStartSeconds = nil
    pendingControlGates = [.audio, .defaultSubtitle, .position]
    self.surface = surface
    positionReporter?.cancel()
    self.observesPlaybackState = observesPlaybackState
    self.fileID = fileID
    self.onReady = onReady
    self.onDurationKnown = onDurationKnown
    self.onAudioSelected = observesPlaybackState ? onAudioSelected : nil
    self.onPositionChanged = observesPlaybackState ? onPositionChanged : nil
    self.onPlaybackEnded = onPlaybackEnded
    self.onPlaybackRestarted = onPlaybackRestarted
    self.onFailure = onFailure

    let item = makeItem(source.url)
    statusObservation = observeItemStatus(item) { [weak self] status in
      Task { @MainActor [weak self] in
        switch status {
        case .readyToPlay:
          if let restoredTracks {
            await self?.restoreTracksOnce(restoredTracks, to: item, generation: playbackGeneration)
          } else {
            self?.applyDefaultSubtitleOnce(to: item, generation: playbackGeneration)
            if !preferredAudioLanguages.isEmpty {
              await Self.selectAudio(preferring: preferredAudioLanguages, in: item)
            }
          }
          self?.settleControls(.audio, generation: playbackGeneration)
          self?.reportMediaSelection(for: item, generation: playbackGeneration)
          self?.reportReady(generation: playbackGeneration)
        case .failed:
          self?.reportFailure(
            PutioVideoPlayerFault(error: item.error), generation: playbackGeneration)
        case .unknown:
          break
        @unknown default:
          break
        }
      }
    }
    #if DEBUG
      if observesPlaybackState, let onSubtitleTextShown {
        let probe = PutioSubtitleTextProbe(onText: onSubtitleTextShown)
        probe.attach(to: item)
        subtitleTextProbe = probe
      }
    #endif
    if observesPlaybackState {
      mediaSelectionObservation = notificationCenter.addObserver(
        forName: AVPlayerItem.mediaSelectionDidChangeNotification, object: item, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.reportMediaSelection(for: item, generation: playbackGeneration)
        }
      }
    }
    failedToEndObservation = notificationCenter.addObserver(
      forName: AVPlayerItem.failedToPlayToEndTimeNotification,
      object: item,
      queue: nil
    ) { [weak self] notification in
      let fault = PutioVideoPlayerFault(
        error: notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError)
      Task { @MainActor [weak self] in
        self?.reportFailure(fault, generation: playbackGeneration)
      }
    }
    playedToEndObservation = notificationCenter.addObserver(
      forName: AVPlayerItem.didPlayToEndTimeNotification,
      object: item,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.reportPlaybackEnded(generation: playbackGeneration)
      }
    }
    timeJumpedObservation = notificationCenter.addObserver(
      forName: AVPlayerItem.timeJumpedNotification,
      object: item,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.reportPlaybackRestarted(generation: playbackGeneration)
        self?.savePosition(generation: playbackGeneration)
      }
    }

    surface.showsPlaybackControls = false

    let driver = makeDriver(item)
    self.driver = driver
    surface.player = driver.player
    let positionReporter = PutioVideoPositionReporter(
      fileID: fileID,
      remembersPosition: remembersPlaybackPosition,
      pipeline: positionPipeline,
      report: reportPosition,
      currentPosition: { [weak self, weak driver] in
        guard let self, let driver, self.driver === driver else { return nil }
        return PutioVideoPositionReporter.normalizedPosition(
          seconds: CMTimeGetSeconds(driver.currentTime))
      },
      savedPosition: remembersPlaybackPosition ? reloadSeconds ?? source.startFromSeconds : nil,
      endOfPlayback: .keepsPosition,
      schedule: schedulePositionReports
    )
    self.positionReporter = positionReporter
    for observation in positionSaveObservations {
      notificationCenter.removeObserver(observation)
    }
    positionSaveObservations = [
      notificationCenter.addObserver(
        forName: AVPlayer.rateDidChangeNotification, object: driver.player, queue: .main
      ) { [weak self, weak driver] _ in
        MainActor.assumeIsolated {
          guard driver?.player.rate == 0 else { return }
          self?.savePosition(generation: playbackGeneration)
        }
      },
      notificationCenter.addObserver(
        forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.savePosition(generation: playbackGeneration)
        }
      },
    ]
    if self.onPositionChanged != nil {
      positionObservation = driver.observePosition(
        every: CMTime(seconds: 0.25, preferredTimescale: 600)
      ) { [weak self] time in
        Task { @MainActor [weak self] in
          guard
            let self,
            generation == playbackGeneration,
            time.isValid,
            time.isNumeric
          else { return }
          let seconds = time.seconds
          guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return }
          self.onPositionChanged?(Int(seconds.rounded(.down)))
        }
      }
    }

    let seeksToStart = remembersPlaybackPosition || source.resumesAfterFailure
    recoveredStartSeconds =
      reloadSeconds ?? (source.resumesAfterFailure ? source.startFromSeconds : nil)

    do {
      try audioSession.activate()
      audioSessionIsActive = true
    } catch {
      Task { @MainActor [weak self] in
        self?.reportFailure(.playback, generation: playbackGeneration)
      }
      return false
    }

    let requestedStart = reloadSeconds ?? (seeksToStart ? source.startFromSeconds : 0)
    guard requestedStart > 0 else {
      positionEstablished = true
      positionReporter.positionEstablished()
      settleControls(.position, generation: playbackGeneration)
      driver.play()
      return true
    }

    let loadDuration = loadDuration
    Task { @MainActor [weak self] in
      let duration = await loadDuration(item)
      guard let self, generation == playbackGeneration, self.driver === driver,
        !failureReported
      else { return }
      let startSeconds =
        reloadSeconds
        ?? (source.resumesAfterFailure
          ? source.startFromSeconds
          : PutioPlaybackProgress.startSeconds(
            savedSeconds: source.startFromSeconds, durationSeconds: duration))
      guard startSeconds > 0 else {
        positionEstablished = true
        positionReporter.positionEstablished()
        positionReporter.startReporting()
        settleControls(.position, generation: playbackGeneration)
        driver.play()
        return
      }
      seek(driver, to: startSeconds, reporter: positionReporter, generation: playbackGeneration)
    }
    return true
  }

  private func seek(
    _ driver: any PutioVideoPlayerDriving, to startSeconds: Int,
    reporter positionReporter: PutioVideoPositionReporter, generation playbackGeneration: UInt64
  ) {
    let startTime = CMTime(seconds: Double(startSeconds), preferredTimescale: 600)
    driver.seek(to: startTime) { [weak self] finished in
      Task { @MainActor [weak self] in
        guard let self, generation == playbackGeneration, self.driver === driver else { return }
        guard !failureReported else { return }
        guard finished else {
          reportFailure(
            PutioVideoPlayerFault(error: driver.player.currentItem?.error),
            generation: playbackGeneration)
          return
        }
        positionEstablished = true
        positionReporter.positionEstablished()
        positionReporter.startReporting()
        settleControls(.position, generation: playbackGeneration)
        driver.play()
      }
    }
  }

  static func duration(of item: AVPlayerItem) async -> Double? {
    guard let duration = try? await item.asset.load(.duration), duration.isNumeric else {
      return nil
    }
    return CMTimeGetSeconds(duration)
  }

  private func savePosition(generation playbackGeneration: UInt64) {
    guard generation == playbackGeneration else { return }
    positionReporter?.savePosition()
  }

  func reload(restoring tracks: PutioVideoTrackSelection? = nil) {
    guard let driver, let reloadAt else { return }
    let seconds = PutioVideoPositionReporter.normalizedPosition(
      seconds: CMTimeGetSeconds(driver.currentTime))
    reloadAt(seconds, tracks)
  }

  private func restoreTracksOnce(
    _ tracks: PutioVideoTrackSelection, to item: AVPlayerItem,
    generation playbackGeneration: UInt64
  ) async {
    guard generation == playbackGeneration, !defaultSubtitleRequested else { return }
    defaultSubtitleRequested = true
    await restoreTracks(tracks, item)
    settleControls(.defaultSubtitle, generation: playbackGeneration)
  }

  static func restore(_ tracks: PutioVideoTrackSelection, in item: AVPlayerItem) async {
    if let index = tracks.audio,
      let audible = try? await item.asset.loadMediaSelectionGroup(for: .audible),
      audible.options.indices.contains(index)
    {
      item.select(audible.options[index], in: audible)
    }
    guard let legible = try? await item.asset.loadMediaSelectionGroup(for: .legible) else {
      return
    }
    let options = legible.options.filter {
      !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles)
    }
    if let index = tracks.subtitle {
      guard options.indices.contains(index) else { return }
      item.select(options[index], in: legible)
    } else {
      item.select(nil, in: legible)
    }
  }

  func stop(surface: PutioVideoSurfaceView) {
    let stoppedDriver = driver
    positionReporter?.stop()
    positionReporter = nil
    generation &+= 1
    statusObservation?.invalidate()
    statusObservation = nil
    if let positionObservation, let stoppedDriver {
      stoppedDriver.removePositionObservation(positionObservation)
      self.positionObservation = nil
    }
    if let failedToEndObservation {
      notificationCenter.removeObserver(failedToEndObservation)
      self.failedToEndObservation = nil
    }
    if let playedToEndObservation {
      notificationCenter.removeObserver(playedToEndObservation)
      self.playedToEndObservation = nil
    }
    if let timeJumpedObservation {
      notificationCenter.removeObserver(timeJumpedObservation)
      self.timeJumpedObservation = nil
    }
    if let mediaSelectionObservation {
      notificationCenter.removeObserver(mediaSelectionObservation)
      self.mediaSelectionObservation = nil
    }
    for observation in positionSaveObservations {
      notificationCenter.removeObserver(observation)
    }
    positionSaveObservations = []
    #if DEBUG
      subtitleTextProbe = nil
    #endif
    onReady = nil
    onPositionChanged = nil
    onPlaybackEnded = nil
    onPlaybackRestarted = nil
    onFailure = nil
    stoppedDriver?.stop()
    driver = nil
    surface.player = nil
    self.surface = nil
    if audioSessionIsActive {
      audioSession.deactivate()
      audioSessionIsActive = false
    }
  }

  func waitForPendingPositionReports() async {
    guard let fileID else { return }
    await positionPipeline.waitForPendingReports(fileID: fileID)
  }

  private func reportFailure(
    _ fault: PutioVideoPlayerFault, generation playbackGeneration: UInt64
  ) {
    guard generation == playbackGeneration, !failureReported else { return }
    failureReported = true
    let playingSeconds = driver.flatMap {
      PutioVideoPositionReporter.normalizedPosition(seconds: CMTimeGetSeconds($0.currentTime))
    }
    let heldSeconds = positionEstablished ? playingSeconds : recoveredStartSeconds
    positionReporter?.playbackFailed()
    onFailure?(
      PutioVideoPlayerFailure(
        fault: fault, heldSeconds: heldSeconds,
        beforeFirstFrame: surface?.showsFirstFrame != true))
  }

  /// Offline assets keep every downloaded language; the player picks the
  /// first preferred one present and otherwise leaves the asset's default.
  static func selectAudio(preferring languages: [String], in item: AVPlayerItem) async {
    guard let group = try? await item.asset.loadMediaSelectionGroup(for: .audible) else { return }
    let stored = group.options.map(PutioOfflineQueue.track)
    guard let choice = PutioOfflineLanguage.match(from: stored, preferredLanguages: languages),
      let option = group.options.first(where: {
        PutioOfflineQueue.track($0).languageCode == choice.languageCode
      })
    else { return }
    item.select(option, in: group)
  }

  private func applyDefaultSubtitleOnce(
    to item: AVPlayerItem,
    generation playbackGeneration: UInt64
  ) {
    guard generation == playbackGeneration, !defaultSubtitleRequested else { return }
    defaultSubtitleRequested = true
    let applyDefaultSubtitle = applyDefaultSubtitle
    Task { @MainActor [weak self] in
      await applyDefaultSubtitle(item)
      guard let self, generation == playbackGeneration else { return }
      settleControls(.defaultSubtitle, generation: playbackGeneration)
      reportMediaSelection(for: item, generation: playbackGeneration)
    }
  }

  private func settleControls(_ gate: ControlGate, generation playbackGeneration: UInt64) {
    guard generation == playbackGeneration else { return }
    pendingControlGates.remove(gate)
    guard pendingControlGates.isEmpty else { return }
    surface?.showsPlaybackControls = true
  }

  /// put.io marks the first subtitle `DEFAULT` unless the account disables
  /// auto-selection, and omits subtitles when they are hidden. AVPlayer's
  /// automatic media selection leaves that default off under the system's
  /// automatic caption setting, so the player applies it before showing
  /// controls.
  static func selectDefaultSubtitle(in item: AVPlayerItem) async {
    await selectStartSubtitle(in: item, policy: .accountDefault, remembered: nil)
  }

  static func selectStartSubtitle(
    in item: AVPlayerItem, policy: PutioSubtitleStartupPolicy,
    remembered: PutioRememberedSubtitle?
  ) async {
    guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) else {
      return
    }
    let options = group.options.filter {
      !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles)
    }
    let tracks = PutioVideoTransport.subtitleTracks(options, defaultOption: group.defaultOption)
    if let start = policy.startingTrack(in: tracks, remembered: remembered) {
      item.select(options[start.id], in: group)
    } else if item.currentMediaSelection.selectedMediaOption(in: group)
      .map({ !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) }) ?? false
    {
      item.select(nil, in: group)
    }
  }

  /// Publishes the audible and legible options in effect so the journey can
  /// assert language picks without reaching into AVFoundation.
  private func reportMediaSelection(for item: AVPlayerItem, generation playbackGeneration: UInt64) {
    guard generation == playbackGeneration, observesPlaybackState else { return }
    if onAudioSelected != nil {
      let selectedAudioLanguage = selectedAudioLanguage
      Task { @MainActor [weak self] in
        guard let language = await selectedAudioLanguage(item) else { return }
        // A newer playback may have started during the load; its language is
        // reported by its own call.
        guard let self, generation == playbackGeneration, let onAudioSelected else { return }
        onAudioSelected(language)
      }
    }
    #if DEBUG
      if onSubtitleSelected != nil {
        Task { @MainActor [weak self] in
          let subtitle = await Self.selectedSubtitle(in: item)
          guard let self, generation == playbackGeneration, let onSubtitleSelected else { return }
          onSubtitleSelected(subtitle)
        }
      }
    #endif
  }

  static func selectedAudioLanguage(in item: AVPlayerItem) async -> String? {
    guard let group = try? await item.asset.loadMediaSelectionGroup(for: .audible),
      let option = item.currentMediaSelection.selectedMediaOption(in: group)
    else { return nil }
    return PutioOfflineQueue.track(option).languageCode
  }

  #if DEBUG
    /// The legible option's language, `off` when the stream offers subtitles
    /// but none is selected, or `unavailable` when it offers none.
    static func selectedSubtitle(in item: AVPlayerItem) async -> String {
      guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) else {
        return "unavailable"
      }
      guard let option = item.currentMediaSelection.selectedMediaOption(in: group) else {
        return "off"
      }
      return PutioOfflineQueue.track(option).languageCode
    }
  #endif

  private func reportReady(generation playbackGeneration: UInt64) {
    guard generation == playbackGeneration, !readyReported, !failureReported else { return }
    readyReported = true
    positionReporter?.ready()
    if let duration = driver?.itemDuration, duration.isValid, duration.isNumeric {
      onDurationKnown?(CMTimeGetSeconds(duration))
    }
    onReady?()
  }

  private func reportPlaybackEnded(generation playbackGeneration: UInt64) {
    guard
      generation == playbackGeneration,
      readyReported,
      !failureReported,
      positionReporter?.playbackEnded() == true
    else { return }
    onPlaybackEnded?()
  }

  /// A time jump after EOF is a restart only when playback actually moved
  /// back into the item. HLS discontinuities at the end jump to the duration,
  /// and treating those as a restart would save a stale position over the end.
  private func reportPlaybackRestarted(generation playbackGeneration: UInt64) {
    guard
      generation == playbackGeneration, let driver, let positionReporter,
      positionReporter.hasReportedFinalPosition
    else { return }
    guard !Self.isAtItemEnd(position: driver.currentTime, duration: driver.itemDuration) else {
      return
    }
    guard positionReporter.playbackRestarted() else { return }
    onPlaybackRestarted?()
  }

  private static func isAtItemEnd(position: CMTime, duration: CMTime) -> Bool {
    guard duration.isValid, duration.isNumeric else { return false }
    return PutioVideoPositionReporter.isAtEnd(
      positionSeconds: CMTimeGetSeconds(position), durationSeconds: CMTimeGetSeconds(duration))
  }
}

#if DEBUG
  @MainActor
  private final class PutioSubtitleTextProbe: NSObject, AVPlayerItemLegibleOutputPushDelegate {
    private let output = AVPlayerItemLegibleOutput()
    private let onText: @MainActor @Sendable (String) -> Void

    init(onText: @escaping @MainActor @Sendable (String) -> Void) {
      self.onText = onText
      super.init()
      output.setDelegate(self, queue: .main)
    }

    func attach(to item: AVPlayerItem) {
      item.add(output)
    }

    nonisolated func legibleOutput(
      _ output: AVPlayerItemLegibleOutput,
      didOutputAttributedStrings strings: [NSAttributedString],
      nativeSampleBuffers nativeSamples: [Any], forItemTime itemTime: CMTime
    ) {
      let text = strings.map(\.string).joined(separator: "\n")
      MainActor.assumeIsolated { onText(text.isEmpty ? "none" : text) }
    }
  }
#endif
