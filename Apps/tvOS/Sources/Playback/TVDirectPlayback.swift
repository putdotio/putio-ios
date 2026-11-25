import AetherEngine
import Combine
import PutioCore
import SwiftUI

/// The engine-side state of Direct play on tvOS: what the put.io controls
/// and captions draw, and the actions the Siri Remote sends.
@MainActor
@Observable
final class TVDirectTransport: PutioDirectPlayTransport {
  private(set) var isPlaying = false
  private(set) var controlsEnabled = false
  private(set) var speed: PutioAudioSpeed
  private(set) var audioTracks: [PutioVideoAudioTrack] = []
  private(set) var selectedAudio: Int?
  private(set) var subtitles: [PutioSubtitleTrack] = []
  private(set) var selectedSubtitle: Int?
  private(set) var subtitleCues: [PutioVideoCue] = []
  private(set) var picture = PutioVideoPicture.unknown
  private(set) var subtitleTiming = PutioSubtitleTiming()
  private var playhead = PutioVideoPlayhead()
  let wait: PutioVideoWaitModel
  @ObservationIgnored var onEngineRestart: (@MainActor (Double) -> Void)?
  @ObservationIgnored var onReload: (@MainActor (PutioVideoTrackSelection?) -> Void)?

  @ObservationIgnored private var engine: AetherEngine?
  @ObservationIgnored private var observations: Set<AnyCancellable> = []
  @ObservationIgnored private var attachment: UInt64 = 0
  @ObservationIgnored private let speedStore: PutioAudioSpeedStore

  init(wait: PutioVideoWaitModel? = nil, speedStore: PutioAudioSpeedStore? = nil) {
    self.wait = wait ?? PutioVideoWaitModel()
    let speedStore = speedStore ?? .video()
    self.speedStore = speedStore
    speed = speedStore.load()
  }

  var timeline: PutioVideoTimeline { playhead.timeline }

  func engineChanged(to engine: AetherEngine) {
    detach()
    attachment &+= 1
    wait.restart()
    self.engine = engine
    engine.setSoftwareSubtitleDelay(subtitleTiming.seconds)
    engine.$state
      .sink { [weak self] state in self?.isPlaying = state == .playing }
      .store(in: &observations)
    engine.$playbackPhase
      .sink { [weak self] phase in
        guard let self else { return }
        wait.activityChanged(
          Self.activity(phase),
          atSeconds: PutioVideoPositionReporter.normalizedPosition(seconds: timeline.elapsedSeconds)
        )
      }
      .store(in: &observations)
    engine.clock.$currentTime.combineLatest(engine.$duration)
      .sink { [weak self] elapsed, duration in
        self?.playhead.observed(elapsedSeconds: elapsed, durationSeconds: duration)
      }
      .store(in: &observations)
    engine.$audioTracks.combineLatest(engine.$activeAudioTrackIndex)
      .sink { [weak self] tracks, active in
        guard let self else { return }
        (audioTracks, selectedAudio) = PutioEngineTracks.audio(tracks, active: active)
      }
      .store(in: &observations)
    engine.$subtitleTracks.combineLatest(engine.$activeSubtitleTrackIndex)
      .sink { [weak self] tracks, active in
        self?.subtitles = PutioEngineTracks.subtitles(tracks)
        self?.selectedSubtitle = active
      }
      .store(in: &observations)
    engine.$subtitleCues.combineLatest(engine.clock.$sourceTime)
      .sink { [weak self] cues, time in self?.showCues(cues, at: time) }
      .store(in: &observations)
    engine.$softwareDisplaySize
      .combineLatest(engine.$sourceVideoWidth, engine.$sourceVideoHeight)
      .sink { [weak self, weak engine] display, width, height in
        guard let self, let engine else { return }
        picture = PutioEngineTracks.picture(
          width: width, height: height, display: display,
          pixelAspectRatio: engine.sourceVideoPixelAspectRatio)
      }
      .store(in: &observations)
  }

  func engineReleased(_ engine: AetherEngine) {
    guard engine === self.engine else { return }
    onEngineRestart = nil
    onReload = nil
    detach()
    attachment &+= 1
  }

  func setControlsEnabled(_ enabled: Bool, for engine: AetherEngine) {
    guard engine === self.engine else { return }
    controlsEnabled = enabled
    if enabled, speed != .normal { engine.setRate(speed.rawValue) }
  }

  func togglePlayPause() {
    guard controlsEnabled, let engine else { return }
    if engine.state == .ended {
      let duration = timeline.durationSeconds ?? 0
      onEngineRestart?(timeline.elapsedSeconds >= duration - 0.5 ? 0 : timeline.elapsedSeconds)
    } else if isPlaying {
      engine.pause()
    } else {
      engine.play()
    }
  }

  func skip(by seconds: Double) {
    seek(to: timeline.target(skippingBy: seconds))
  }

  func seek(to seconds: Double) {
    guard controlsEnabled, let engine else { return }
    let attachment = attachment
    let seek = playhead.seekStarted(to: seconds)
    let target = playhead.timeline.elapsedSeconds
    Task { @MainActor [weak self, weak engine] in
      await engine?.seek(to: target)
      guard let self, self.attachment == attachment else { return }
      playhead.seekFinished(seek)
    }
  }

  private func showCues(_ cues: [SubtitleCue], at time: Double) {
    let showing = PutioEngineTracks.showing(cues, at: time, delay: subtitleTiming.seconds)
    guard showing.map(\.id) != subtitleCues.map(\.id) else { return }
    subtitleCues = showing.map(PutioVideoCue.init)
  }

  private func detach() {
    observations.removeAll()
    engine = nil
    controlsEnabled = false
    isPlaying = false
    playhead = PutioVideoPlayhead()
    audioTracks = []
    selectedAudio = nil
    subtitles = []
    selectedSubtitle = nil
    subtitleCues = []
    picture = .unknown
  }

  private static func activity(_ phase: PlaybackPhase) -> PutioVideoPlayerActivity {
    switch phase {
    case .playing: .playing
    case .loading, .seeking, .rebuffering, .stalled: .waiting
    case .idle, .paused, .ended, .error: .paused
    }
  }
}

/// The engine's video surface. The shared coordinator claims the engine,
/// loads the original with its put.io subtitles, and reports positions.
struct TVDirectPlayerView: UIViewRepresentable {
  let fileID: PutioFileID
  let source: PutioPlaybackSource
  let transport: TVDirectTransport
  let remembersPlaybackPosition: Bool
  let subtitlePolicy: PutioSubtitleStartupPolicy
  let subtitleMemory: PutioSubtitleMemory
  let positionPipeline: PutioPlaybackPositionPipeline
  let reportPosition: PutioPlaybackPositionReport
  let callbacks: PutioVideoPlayerCallbacks
  let onReportsSettled: @MainActor () -> Void

  final class Coordinator {
    let playback: PutioDirectPlayCoordinator
    let settles: @MainActor () async -> Void

    init(playback: PutioDirectPlayCoordinator, settles: @escaping @MainActor () async -> Void) {
      self.playback = playback
      self.settles = settles
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(
      playback: PutioDirectPlayCoordinator(positionPipeline: positionPipeline),
      settles: { [fileID, positionPipeline, onReportsSettled] in
        await positionPipeline.waitForPendingReports(fileID: fileID)
        onReportsSettled()
      })
  }

  func makeUIView(context: Context) -> AetherPlayerView {
    let view = AetherPlayerView()
    view.backgroundColor = .black
    context.coordinator.playback.start(
      fileID: fileID, source: source, transport: transport,
      preferredAudioLanguages: Locale.preferredLanguages,
      remembersPlaybackPosition: remembersPlaybackPosition,
      subtitles: PutioDirectPlayCoordinator.SubtitleStart(
        policy: subtitlePolicy, remembered: { [subtitleMemory] in subtitleMemory.remembered }),
      reportPosition: { try await reportPosition($0, $1) }, in: view, callbacks: callbacks)
    return view
  }

  func updateUIView(_ view: AetherPlayerView, context: Context) {}

  static func dismantleUIView(_ view: AetherPlayerView, coordinator: Coordinator) {
    coordinator.playback.stop()
    let settles = coordinator.settles
    Task { @MainActor in await settles() }
  }
}

/// Direct play with put.io controls over the engine. Click and Play/Pause
/// pause or play, left and right skip ten seconds, and Menu hides the
/// controls before it leaves.
struct TVDirectVideoPlayer: View {
  let title: String
  let fileID: PutioFileID
  let source: PutioPlaybackSource
  let remembersPosition: Bool
  let subtitlePolicy: PutioSubtitleStartupPolicy
  let subtitleMemory: PutioSubtitleMemory
  let pipeline: PutioPlaybackPositionPipeline
  let reportPosition: PutioPlaybackPositionReport
  let callbacks: PutioVideoPlayerCallbacks
  let onReportsSettled: @MainActor () -> Void
  let onExit: @MainActor () -> Void

  init(
    title: String, fileID: PutioFileID, source: PutioPlaybackSource, remembersPosition: Bool,
    subtitlePolicy: PutioSubtitleStartupPolicy, subtitleMemory: PutioSubtitleMemory,
    pipeline: PutioPlaybackPositionPipeline, reportPosition: @escaping PutioPlaybackPositionReport,
    wait: PutioVideoWaitModel, callbacks: PutioVideoPlayerCallbacks,
    onReportsSettled: @escaping @MainActor () -> Void = {},
    onExit: @escaping @MainActor () -> Void
  ) {
    self.title = title
    self.fileID = fileID
    self.source = source
    self.remembersPosition = remembersPosition
    self.subtitlePolicy = subtitlePolicy
    self.subtitleMemory = subtitleMemory
    self.pipeline = pipeline
    self.reportPosition = reportPosition
    self.callbacks = callbacks
    self.onReportsSettled = onReportsSettled
    self.onExit = onExit
    _transport = State(initialValue: TVDirectTransport(wait: wait))
  }

  @State private var transport: TVDirectTransport
  @State private var visibility = PutioVideoControlsVisibility()
  @FocusState private var focused: Bool
  @Environment(\.isEnabled) private var isEnabled

  var body: some View {
    ZStack {
      TVDirectPlayerView(
        fileID: fileID, source: source, transport: transport,
        remembersPlaybackPosition: remembersPosition, subtitlePolicy: subtitlePolicy,
        subtitleMemory: subtitleMemory, positionPipeline: pipeline,
        reportPosition: reportPosition, callbacks: callbacks, onReportsSettled: onReportsSettled
      )
      .ignoresSafeArea()
      PutioVideoSubtitleOverlay(
        cues: transport.subtitleCues, size: .medium, picture: transport.picture,
        bottomInset: showsControls
          ? TVDirectControlsMetrics.captionLift : TVDirectControlsMetrics.captionInset)
      if showsControls {
        TVDirectControls(title: title, timeline: transport.timeline)
          .transition(.opacity)
      }
      if transport.wait.state.showsSpinner {
        PutioLoadingStateView(title: nil).allowsHitTesting(false)
      }
    }
    .animation(.easeInOut(duration: 0.2), value: showsControls)
    .focusable()
    .focused($focused)
    .onAppear { focused = true }
    .onChange(of: isEnabled) { _, enabled in
      if enabled { focused = true }
    }
    .onPlayPauseCommand { playPause() }
    .onTapGesture { playPause() }
    .onMoveCommand { direction in
      switch direction {
      case .left: skip(by: -PutioVideoTimeline.skipInterval)
      case .right: skip(by: PutioVideoTimeline.skipInterval)
      default: visibility.interacted()
      }
    }
    .onExitCommand {
      if showsControls, transport.isPlaying {
        withAnimation {
          visibility.idleElapsed(generation: visibility.idleGeneration, isPlaying: true)
        }
      } else {
        onExit()
      }
    }
    .task(id: visibility.idleGeneration) {
      try? await Task.sleep(for: PutioVideoControlsVisibility.idleDelay)
      guard !Task.isCancelled else { return }
      visibility.idleElapsed(generation: visibility.idleGeneration, isPlaying: transport.isPlaying)
    }
    .onChange(of: transport.isPlaying) { _, _ in visibility.interacted() }
    .accessibilityIdentifier("video.direct-player")
  }

  private var showsControls: Bool {
    visibility.isVisible && !transport.wait.state.hidesControls
  }

  private func playPause() {
    visibility.interacted()
    transport.togglePlayPause()
  }

  private func skip(by seconds: Double) {
    visibility.interacted()
    transport.skip(by: seconds)
  }
}

enum TVDirectControlsMetrics {
  static let captionInset = PutioTheme.TV.Spacing.large
  static let captionLift: CGFloat = 280
  static let progressHeight: CGFloat = 12
  static let scrimHeight: CGFloat = 480
}

/// The transport overlay of board `rd-tvos-dp-01-controls`: the file name,
/// the progress bar, elapsed and remaining time over a bottom scrim.
struct TVDirectControls: View {
  let title: String
  let timeline: PutioVideoTimeline

  private var fraction: Double {
    guard let duration = timeline.durationSeconds, duration > 0 else { return 0 }
    return timeline.elapsedSeconds / duration
  }

  var body: some View {
    ZStack(alignment: .bottomLeading) {
      LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
        .frame(height: TVDirectControlsMetrics.scrimHeight)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .ignoresSafeArea()
      VStack(alignment: .leading, spacing: PutioTheme.TV.Spacing.small) {
        Text(title)
          .putioFont(PutioTheme.TV.Typography.body)
          .foregroundStyle(PutioTheme.TV.Colors.textPrimary)
          .lineLimit(1)
          .accessibilityIdentifier("video.title")
        TVDirectProgressBar(fraction: fraction)
          .frame(height: TVDirectControlsMetrics.progressHeight)
          .accessibilityElement()
          .accessibilityIdentifier("video.progress")
          .accessibilityValue(timeline.elapsedText)
        HStack {
          Text(timeline.elapsedText)
            .accessibilityIdentifier("video.elapsed")
          Spacer()
          Text(timeline.remainingText)
            .accessibilityIdentifier("video.remaining")
        }
        .putioFont(PutioTheme.TV.Typography.numeric)
        .foregroundStyle(PutioTheme.TV.Colors.textSecondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
      .tvOverscanPadding()
    }
    .allowsHitTesting(false)
  }
}

private struct TVDirectProgressBar: View {
  let fraction: Double

  var body: some View {
    GeometryReader { geometry in
      let width = geometry.size.width * min(max(fraction, 0), 1)
      ZStack(alignment: .leading) {
        Capsule().fill(.white.opacity(0.25))
        Capsule().fill(.white).frame(width: width)
        Rectangle().fill(.white).frame(width: 4, height: geometry.size.height * 1.75)
          .offset(x: max(width - 2, 0))
      }
    }
  }
}
