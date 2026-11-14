import AVFoundation
import Observation
import PutioCore
import SwiftUI

@MainActor
struct PutioVideoPlaybackView: View {
  @State private var model: PutioVideoPlaybackModel
  @State private var nextVideoModel: PutioNextVideoModel
  @State private var resumePrompter: PutioVideoResumePrompter
  @State private var retrySequence: UInt64 = 0
  @State private var playerIsReady = false
  @State private var observedPlaybackPosition: Int?
  @State private var selectedAudioLanguage: String?
  #if DEBUG
    @State private var selectedSubtitle: String?
  #endif
  @State private var playbackReachedEnd = false
  @State private var reportedFaults: [PutioVideoPlayerFault] = []
  @State private var conversionHistory: [String] = []
  @State private var nextVideoTransitionTask: Task<Void, Never>?
  @State private var playerFailureTask: Task<Void, Never>?
  @State private var transport = PutioVideoTransport()
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
  private let onOpenInVLC: (() -> Void)?

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
    nextVideoAutoplayDelay: Duration = PutioNextVideoModel.defaultAutoplayDelay,
    positionPipeline: PutioPlaybackPositionPipeline,
    reportPosition: @escaping PutioPlaybackPositionReport = { _, _ in },
    startConversion: @escaping PutioVideoConversionStart,
    loadConversionStatus: @escaping PutioVideoConversionStatusLoad,
    loadNextVideo: @escaping PutioNextVideoLoad,
    onPlayNext: @escaping @MainActor @Sendable (PutioPlayableNextVideo) -> Void,
    castButton: AnyView? = nil,
    onCast: (@MainActor @Sendable () -> Void)? = nil,
    onOpenInVLC: (() -> Void)? = nil,
    resolve: @escaping PutioPlaybackResolve
  ) {
    self.castButton = castButton
    self.onCast = onCast
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
    let startsOver = route.startsOver
    _model = State(
      initialValue: PutioVideoPlaybackModel(
        fileID: route.id,
        initialResolution: route.initialResolution,
        conversionPollInterval: conversionPollInterval,
        startConversion: startConversion,
        loadConversionStatus: loadConversionStatus,
        chooseStart: { source, afterConversion in
          if startsOver { return PutioVideoStart.source(source, startingWith: .startOver) }
          guard afterConversion, remembersPlaybackPosition, source.startFromSeconds > 0 else {
            return source
          }
          let duration = await PutioVideoLength.seconds(of: source.url)
          guard
            PutioVideoStart.asksWhereToStart(
              savedSeconds: source.startFromSeconds, durationSeconds: duration,
              remembersPosition: true)
          else { return source }
          let choice = await resumePrompter.ask(positionSeconds: source.startFromSeconds)
          return PutioVideoStart.source(source, startingWith: choice ?? .resume)
        }
      ) { fileID in
        await positionPipeline.waitForPendingReports(fileID: fileID)
        return try await resolve(fileID)
      }
    )
    _nextVideoModel = State(
      initialValue: PutioNextVideoModel(
        suggestionsEnabled: suggestsNextVideo,
        autoplayEnabled: autoplayNextVideo,
        autoplayDelay: nextVideoAutoplayDelay,
        waitForReset: { completedFileID in
          await positionPipeline.waitForPendingReports(fileID: completedFileID)
        },
        loadNext: loadNextVideo
      )
    )
  }

  var body: some View {
    ZStack {
      content
      if isReady, !transport.wait.state.hidesControls {
        PutioVideoControls(
          title: title, transport: transport, showsCast: castButton != nil || onCast != nil,
          onClose: onDismiss
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
    .onDisappear {
      playerFailureTask?.cancel()
      playerFailureTask = nil
      nextVideoTransitionTask?.cancel()
      nextVideoTransitionTask = nil
      nextVideoModel.cancel()
    }
    .overlay(alignment: .bottom) {
      nextVideoOverlay
        .padding(.bottom, isReady ? PutioTheme.Spacing.space5 : 0)
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
    case .clear, .buffering, .bufferingLong:
      EmptyView()
    }
  }

  @ViewBuilder
  private var castControls: some View {
    if let castButton {
      castButton
        .frame(minWidth: 44, minHeight: 44)
    }
    if let onCast {
      PutioButton(String(localized: "Cast"), tier: .secondary, size: .small) {
        onCast()
      }
      .accessibilityIdentifier("video.cast")
    }
  }

  @ViewBuilder
  private var nextVideoOverlay: some View {
    switch nextVideoModel.state {
    case .loading:
      if showsHarnessReadiness {
        ProgressView()
          .tint(PutioTheme.Colors.accent)
          .accessibilityLabel("Finding the next video")
          .accessibilityIdentifier("video.next-loading")
          .padding(PutioTheme.Spacing.space4)
      }
    case .available(let nextVideo):
      PutioNextVideoOverlay(
        nextVideo: nextVideo.video,
        autoplaySecondsRemaining: nextVideoModel.autoplaySecondsRemaining,
        onPlay: { nextVideoModel.playNext() },
        onCancel: { nextVideoModel.cancel() }
      )
      .padding(PutioTheme.Spacing.space4)
    case .unavailable:
      if showsHarnessReadiness {
        Color.clear
          .frame(width: 1, height: 1)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("No next video")
          .accessibilityIdentifier("video.next-unavailable")
          .allowsHitTesting(false)
      }
    case .idle, .playing, .cancelled:
      EmptyView()
    }
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
      PutioVideoPlayerView(
        fileID: fileID,
        source: source,
        transport: transport,
        preferredAudioLanguages: preferredAudioLanguages,
        remembersPlaybackPosition: remembersPlaybackPosition,
        positionPipeline: positionPipeline,
        reportPosition: reportPosition,
        onReady: {
          playerIsReady = true
          model.playerReady()
        },
        onDurationKnown: onDurationKnown,
        observesPlaybackState: showsHarnessReadiness,
        onAudioSelected: { selectedAudioLanguage = $0 },
        onPositionChanged: { observedPlaybackPosition = $0 },
        onPlaybackEnded: {
          playbackReachedEnd = true
          nextVideoTransitionTask?.cancel()
          nextVideoTransitionTask = Task { @MainActor in
            await nextVideoModel.playbackEnded(completedFileID: fileID)
          }
        },
        onPlaybackRestarted: {
          playbackReachedEnd = false
          nextVideoTransitionTask?.cancel()
          nextVideoTransitionTask = nil
          nextVideoModel.cancel()
        }
      ) { failure in
        playerIsReady = false
        guard reportsPlayerFailures else { return }
        reportedFaults.append(failure.fault)
        reportFailure(failure.fault)
        playerFailureTask?.cancel()
        playerFailureTask = Task {
          await model.playerFailed(failure.fault, heldSeconds: failure.heldSeconds)
        }
      }
      #if DEBUG
        .onSubtitleSelected { selectedSubtitle = $0 }
      #endif
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

struct PutioNextVideoOverlay: View {
  let nextVideo: PutioNextVideo
  var autoplaySecondsRemaining: Int?
  let onPlay: () -> Void
  let onCancel: () -> Void

  // Video chrome uses fixed white opacities under the Apple contract (DESIGN.md).
  var body: some View {
    VStack(alignment: .leading, spacing: PutioTheme.Spacing.space3) {
      Text("Up Next")
        .putioFont(PutioTheme.Typography.heading)
        .foregroundStyle(.white)
      Text(nextVideo.name)
        .putioFont(PutioTheme.Typography.body)
        .foregroundStyle(.white.opacity(0.78))
        .accessibilityLabel("Up next, \(nextVideo.name)")
        .accessibilityIdentifier("video.next-title")
      if let autoplaySecondsRemaining {
        Text(
          "Playing in \(Duration.seconds(autoplaySecondsRemaining).formatted(.units(allowed: [.seconds], width: .wide)))"
        )
        .putioFont(PutioTheme.Typography.caption)
        .foregroundStyle(.white.opacity(0.78))
        .monospacedDigit()
        .accessibilityIdentifier("video.next-countdown")
      }
      HStack(spacing: PutioTheme.Spacing.space2) {
        PutioButton(String(localized: "Play Next"), tier: .primary, action: onPlay)
          .accessibilityLabel("Play next, \(nextVideo.name)")
          .accessibilityIdentifier("video.play-next")
        PutioButton(String(localized: "Cancel"), tier: .secondary, action: onCancel)
          .accessibilityLabel("Cancel playing \(nextVideo.name)")
          .accessibilityIdentifier("video.cancel-next")
      }
    }
    .padding(PutioTheme.Spacing.space4)
    .frame(maxWidth: 480, alignment: .leading)
    .modifier(PutioNextVideoSurface())
  }
}

private struct PutioNextVideoSurface: ViewModifier {
  @ViewBuilder func body(content: Content) -> some View {
    if HarnessRendering.usesRasterFallback {
      content.background(
        .regularMaterial,
        in: RoundedRectangle(cornerRadius: PutioTheme.Radius.large)
      )
    } else {
      content.glassEffect(
        .regular,
        in: RoundedRectangle(cornerRadius: PutioTheme.Radius.large)
      )
    }
  }
}

private struct PutioVideoPlayerView: UIViewRepresentable {
  let fileID: PutioFileID
  let source: PutioPlaybackSource
  let transport: PutioVideoTransport
  let preferredAudioLanguages: [String]
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

    func onSubtitleSelected(_ action: @escaping @MainActor @Sendable (String) -> Void) -> Self {
      var player = self
      player.subtitleSelected = action
      return player
    }
  #endif

  func makeCoordinator() -> PutioVideoPlayerCoordinator {
    PutioVideoPlayerCoordinator(positionPipeline: positionPipeline)
  }

  func makeUIView(context: Context) -> PutioVideoSurfaceView {
    let surface = PutioVideoSurfaceView()
    let transport = transport
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
  private var onReady: (() -> Void)?
  private var onDurationKnown: (@MainActor (Double) -> Void)?
  private var onAudioSelected: (@MainActor @Sendable (String) -> Void)?
  #if DEBUG
    /// Harness probe; set before `start` and reported only while observing.
    var onSubtitleSelected: (@MainActor @Sendable (String) -> Void)?
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

  convenience init(positionPipeline: PutioPlaybackPositionPipeline) {
    self.init(
      makeDriver: { PutioVideoPlayerDriver(item: $0) },
      audioSession: PutioPlaybackAudioSession(),
      notificationCenter: .default,
      positionPipeline: positionPipeline
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
    onFailure?(PutioVideoPlayerFailure(fault: fault, heldSeconds: heldSeconds))
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
    guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
      let option = group.defaultOption
    else { return }
    item.select(option, in: group)
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
