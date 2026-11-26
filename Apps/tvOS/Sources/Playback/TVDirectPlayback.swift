import AetherEngine
import Combine
import PutioCore
import SwiftUI

/// The engine-side state of Direct play on tvOS: what the put.io controls
/// and captions draw, and the actions the Siri Remote sends.
@MainActor
@Observable
final class TVDirectTransport: PutioDirectPlayTransport, PutioDirectPlayAudioSwitching {
  private(set) var isPlaying = false
  private(set) var ended = false
  private(set) var controlsEnabled = false
  private(set) var speed: PutioAudioSpeed
  private(set) var audioTracks: [PutioVideoAudioTrack] = []
  private(set) var selectedAudio: Int?
  private(set) var subtitles: [PutioSubtitleTrack] = []
  private(set) var selectedSubtitle: Int?
  private(set) var subtitleCues: [PutioVideoCue] = []
  private(set) var picture = PutioVideoPicture.unknown
  private(set) var subtitleTiming = PutioSubtitleTiming()
  private(set) var subtitleSize: PutioSubtitleTextSize
  private(set) var switchingAudio = false
  private var playhead = PutioVideoPlayhead()
  let wait: PutioVideoWaitModel
  @ObservationIgnored var onEngineRestart: (@MainActor (Double) -> Void)?
  @ObservationIgnored var onReload: (@MainActor (PutioVideoTrackSelection?) -> Void)?
  @ObservationIgnored var onAudioSwitch:
    (@MainActor (Int, @escaping @MainActor (Bool) -> Void) -> Void)?
  @ObservationIgnored var onAudioSwitchFailed: (@MainActor () -> Void)?
  @ObservationIgnored var onSubtitlePicked: (@MainActor (PutioSubtitleTrack?) -> Void)?

  @ObservationIgnored private var engine: AetherEngine?
  @ObservationIgnored private var observations: Set<AnyCancellable> = []
  @ObservationIgnored private var attachment: UInt64 = 0
  @ObservationIgnored private let speedStore: PutioAudioSpeedStore
  @ObservationIgnored private let sizeMemory: PutioSubtitleSizeMemory
  @ObservationIgnored private var engineCues: (cues: [SubtitleCue], time: Double) = ([], 0)

  init(
    wait: PutioVideoWaitModel? = nil, speedStore: PutioAudioSpeedStore? = nil,
    sizeMemory: PutioSubtitleSizeMemory? = nil
  ) {
    self.wait = wait ?? PutioVideoWaitModel()
    let speedStore = speedStore ?? .video()
    self.speedStore = speedStore
    speed = speedStore.load()
    let sizeMemory = sizeMemory ?? PutioSubtitleSizeMemory()
    self.sizeMemory = sizeMemory
    subtitleSize = sizeMemory.size
  }

  var subtitleMenu: PutioSubtitleMenu { PutioSubtitleMenu(tracks: subtitles) }

  var timeline: PutioVideoTimeline { playhead.timeline }

  func engineChanged(to engine: AetherEngine) {
    detach()
    attachment &+= 1
    wait.restart()
    self.engine = engine
    engine.setSoftwareSubtitleDelay(subtitleTiming.seconds)
    engine.$state
      .sink { [weak self] state in
        if state != .seeking, state != .loading { self?.isPlaying = state == .playing }
        self?.ended = state == .ended
        self?.playhead.ended(state == .ended)
      }
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
    onAudioSwitch = nil
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

  func setSpeed(_ speed: PutioAudioSpeed) {
    self.speed = speed
    speedStore.save(speed)
    engine?.setRate(speed.rawValue)
  }

  func pickSubtitle(_ index: Int?) {
    guard controlsEnabled, let engine else { return }
    if let index {
      guard subtitles.contains(where: { $0.id == index }) else { return }
      engine.selectSubtitleTrack(index: index)
    } else {
      engine.clearSubtitle()
    }
    selectedSubtitle = index
    onSubtitlePicked?(index.flatMap { index in subtitles.first { $0.id == index } })
  }

  func selectAudio(_ index: Int) {
    guard controlsEnabled, !switchingAudio, index != selectedAudio,
      audioTracks.contains(where: { $0.id == index }), let onAudioSwitch
    else { return }
    switchingAudio = true
    let attachment = attachment
    onAudioSwitch(index) { [weak self] switched in
      guard let self, self.attachment == attachment else { return }
      switchingAudio = false
      if speed != .normal { engine?.setRate(speed.rawValue) }
      if !switched { onAudioSwitchFailed?() }
    }
  }

  func setSubtitleSize(_ size: PutioSubtitleTextSize) {
    subtitleSize = size
    sizeMemory.size = size
  }

  func moveSubtitlesEarlier() {
    subtitleTiming.moveEarlier()
    subtitleTimingChanged()
  }

  func moveSubtitlesLater() {
    subtitleTiming.moveLater()
    subtitleTimingChanged()
  }

  func resetSubtitleTiming() {
    subtitleTiming.reset()
    subtitleTimingChanged()
  }

  private func subtitleTimingChanged() {
    engine?.setSoftwareSubtitleDelay(subtitleTiming.seconds)
    showCues(engineCues.cues, at: engineCues.time)
  }

  private func showCues(_ cues: [SubtitleCue], at time: Double) {
    engineCues = (cues, time)
    let showing = PutioEngineTracks.showing(cues, at: time, delay: subtitleTiming.seconds)
    guard showing.map(\.id) != subtitleCues.map(\.id) else { return }
    subtitleCues = showing.map(PutioVideoCue.init)
  }

  private func detach() {
    observations.removeAll()
    engine = nil
    controlsEnabled = false
    isPlaying = false
    ended = false
    playhead = PutioVideoPlayhead()
    audioTracks = []
    selectedAudio = nil
    subtitles = []
    selectedSubtitle = nil
    subtitleCues = []
    engineCues = ([], 0)
    switchingAudio = false
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
/// pause or play, left and right skip ten seconds, up or down reach the
/// chips, and Menu steps back one level before it leaves.
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
  let onNextFile: (@MainActor () -> Void)?
  let onReportsSettled: @MainActor () -> Void
  let onRateChanged: @MainActor (Float) -> Void
  let onControlsShown: @MainActor (Bool) -> Void
  let onBadgeShown: @MainActor (TVDirectBadge) -> Void
  let onFocusChanged: @MainActor (String) -> Void
  let onExit: @MainActor () -> Void

  init(
    title: String, fileID: PutioFileID, source: PutioPlaybackSource, remembersPosition: Bool,
    subtitlePolicy: PutioSubtitleStartupPolicy, subtitleMemory: PutioSubtitleMemory,
    pipeline: PutioPlaybackPositionPipeline, reportPosition: @escaping PutioPlaybackPositionReport,
    wait: PutioVideoWaitModel, callbacks: PutioVideoPlayerCallbacks,
    onNextFile: (@MainActor () -> Void)? = nil,
    onAudioSwitchFailed: @escaping @MainActor () -> Void = {},
    onReportsSettled: @escaping @MainActor () -> Void = {},
    onRateChanged: @escaping @MainActor (Float) -> Void = { _ in },
    onControlsShown: @escaping @MainActor (Bool) -> Void = { _ in },
    onBadgeShown: @escaping @MainActor (TVDirectBadge) -> Void = { _ in },
    onFocusChanged: @escaping @MainActor (String) -> Void = { _ in },
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
    self.onNextFile = onNextFile
    self.onReportsSettled = onReportsSettled
    self.onRateChanged = onRateChanged
    self.onControlsShown = onControlsShown
    self.onBadgeShown = onBadgeShown
    self.onFocusChanged = onFocusChanged
    self.onExit = onExit
    let transport = TVDirectTransport(wait: wait)
    transport.onAudioSwitchFailed = onAudioSwitchFailed
    transport.onSubtitlePicked = { [subtitleMemory] in subtitleMemory.remember($0) }
    _transport = State(initialValue: transport)
  }

  @State private var transport: TVDirectTransport
  @State private var visibility = PutioVideoControlsVisibility()
  @State private var menu: TVDirectMenu?
  @State private var skipBadge: TVDirectBadge?
  @State private var skipBadges: UInt64 = 0
  @FocusState private var focus: TVDirectFocus?
  @Namespace private var focusScope
  @Environment(\.resetFocus) private var resetFocus
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
        cues: transport.subtitleCues, size: transport.subtitleSize, picture: transport.picture,
        bottomInset: showsControls
          ? TVDirectControlsMetrics.captionLift : TVDirectControlsMetrics.captionInset)
      Button(action: playPause) { Color.clear.contentShape(Rectangle()) }
        .buttonStyle(TVDirectSurfaceStyle())
        .disabled(menu != nil || showsControls)
        .prefersDefaultFocus(!showsControls, in: focusScope)
        .focused($focus, equals: .surface)
        .onMoveCommand(perform: surfaceMoved)
        .accessibilityIdentifier("video.direct-player")
      if let badge {
        TVDirectBadgeView(badge: badge).transition(.opacity)
      }
      TVDirectControls(
        title: title, timeline: transport.timeline, dimmed: menu != nil, menu: { menuPanel }
      ) {
        TVDirectChipRow(
          speed: transport.speed, audioEnabled: transport.audioTracks.count > 1,
          showsNextFile: onNextFile != nil, openChip: menu?.chip, focus: $focus,
          focusScope: focusScope, select: chipSelected
        )
        .onMoveCommand { direction in
          if direction == .up, menu == nil { hideControls() }
        }
      }
      .opacity(showsControls ? 1 : 0)
      .disabled(!showsControls)
      .accessibilityHidden(!showsControls)
      if transport.wait.state.showsSpinner {
        PutioLoadingStateView(title: nil).allowsHitTesting(false)
      }
    }
    .animation(.easeInOut(duration: 0.2), value: showsControls)
    .animation(.easeInOut(duration: 0.2), value: badge)
    .focusScope(focusScope)
    .onAppear { focus = .surface }
    .onChange(of: isEnabled) { _, enabled in
      if enabled { focus = .surface }
    }
    .onPlayPauseCommand { playPause() }
    .onExitCommand(perform: exitPressed)
    .task(id: visibility.idleGeneration) {
      try? await Task.sleep(for: PutioVideoControlsVisibility.idleDelay)
      guard !Task.isCancelled else { return }
      visibility.idleElapsed(generation: visibility.idleGeneration, isPlaying: transport.isPlaying)
    }
    .task(id: skipBadges) {
      guard skipBadge != nil else { return }
      try? await Task.sleep(for: TVDirectControlsMetrics.skipBadgeDuration)
      guard !Task.isCancelled else { return }
      skipBadge = nil
    }
    .onChange(of: transport.isPlaying) { _, _ in visibility.interacted() }
    .onChange(of: pinsControls) { _, pinned in visibility.set(.menu, pinned) }
    .onChange(of: transport.isPlaying, initial: true) { _, playing in
      onRateChanged(playing ? transport.speed.rawValue : 0)
    }
    .onChange(of: transport.speed) { _, speed in
      if transport.isPlaying { onRateChanged(speed.rawValue) }
    }
    .onChange(of: showsControls, initial: true) { _, shown in
      onControlsShown(shown)
      Task { @MainActor in resetFocus(in: focusScope) }
    }
    .onChange(of: focus, initial: true) { _, focus in onFocusChanged(focus?.identifier ?? "none") }
    .onChange(of: badge) { _, badge in
      if let badge { onBadgeShown(badge) }
    }
  }

  private var showsControls: Bool {
    visibility.isVisible && !transport.wait.state.hidesControls
  }

  private var pinsControls: Bool { menu != nil }

  private func hideControls() {
    withAnimation {
      visibility.idleElapsed(generation: visibility.idleGeneration, isPlaying: true)
    }
  }

  private var badge: TVDirectBadge? {
    if let skipBadge { return skipBadge }
    let paused =
      transport.controlsEnabled && !transport.isPlaying && !transport.ended
      && !transport.wait.state.showsSpinner && menu == nil
    return paused ? .paused : nil
  }

  @ViewBuilder private var menuPanel: some View {
    if let menu {
      TVDirectMenuPanel(menu: menu, rows: rows(for: menu), focus: $focus, onMove: rowMoved)
    }
  }

  private func rows(for menu: TVDirectMenu) -> [TVDirectMenuRow] {
    TVDirectMenuRows.rows(
      for: menu, transport: transport,
      close: { closeMenu() }, open: { open($0) })
  }

  private func surfaceMoved(_ direction: MoveCommandDirection) {
    switch direction {
    case .left: skip(by: -PutioVideoTimeline.skipInterval)
    case .right: skip(by: PutioVideoTimeline.skipInterval)
    default:
      withAnimation { visibility.interacted() }
    }
  }

  private func rowMoved(_ id: String, _ direction: MoveCommandDirection) {
    guard id == TVDirectMenuRows.delayID else { return }
    switch direction {
    case .left: transport.moveSubtitlesEarlier()
    case .right: transport.moveSubtitlesLater()
    default: break
    }
  }

  private func chipSelected(_ chip: TVDirectChip) {
    switch chip {
    case .subtitles: open(.subtitles)
    case .audio: open(.audio)
    case .speed: open(.speed)
    case .nextFile: onNextFile?()
    }
  }

  private func open(_ menu: TVDirectMenu) {
    self.menu = menu
    let rows = rows(for: menu)
    focus = .row((rows.first(where: \.checked) ?? rows.first)?.id ?? "")
  }

  private func closeMenu() {
    guard let open = menu else { return }
    menu = nil
    focus = .chip(open.chip)
  }

  private func exitPressed() {
    if menu == .sizeAndTiming {
      menu = .subtitles
      focus = .row(TVDirectMenuRows.sizeAndTimingID)
    } else if menu != nil {
      closeMenu()
    } else if showsControls {
      hideControls()
    } else {
      onExit()
    }
  }

  private func playPause() {
    visibility.interacted()
    transport.togglePlayPause()
  }

  private func skip(by seconds: Double) {
    transport.skip(by: seconds)
    skipBadge = seconds < 0 ? .skippedBack : .skippedForward
    skipBadges &+= 1
  }
}

extension TVDirectMenu {
  var title: String {
    switch self {
    case .subtitles: String(localized: "Subtitles", bundle: .putioCore)
    case .sizeAndTiming: String(localized: "Size and timing", bundle: .putioCore)
    case .audio: String(localized: "Audio", bundle: .putioCore)
    case .speed: String(localized: "Speed", bundle: .putioCore)
    }
  }
}

/// The rows of each Direct play menu, in the order of the HLS menus.
@MainActor
enum TVDirectMenuRows {
  static let sizeAndTimingID = "video.subtitles.size-and-timing"
  static let delayID = "video.subtitle-timing"

  static func rows(
    for menu: TVDirectMenu, transport: TVDirectTransport,
    close: @escaping @MainActor () -> Void, open: @escaping @MainActor (TVDirectMenu) -> Void
  ) -> [TVDirectMenuRow] {
    switch menu {
    case .subtitles:
      let off = TVDirectMenuRow(
        id: "video.subtitles.off", title: String(localized: "Off", bundle: .putioCore),
        checked: transport.selectedSubtitle == nil
      ) {
        transport.pickSubtitle(nil)
        close()
      }
      let tracks = transport.subtitleMenu.rows.map { row in
        TVDirectMenuRow(
          id: "video.subtitles.\(row.track.id)", title: row.title,
          checked: transport.selectedSubtitle == row.track.id
        ) {
          transport.pickSubtitle(row.track.id)
          close()
        }
      }
      let sizeAndTiming = TVDirectMenuRow(
        id: sizeAndTimingID, title: String(localized: "Size and timing", bundle: .putioCore),
        icon: .textAa, startsSection: true
      ) { open(.sizeAndTiming) }
      return [off] + tracks + [sizeAndTiming]
    case .sizeAndTiming:
      return [
        TVDirectMenuRow(
          id: "video.subtitle-size", title: String(localized: "Text size", bundle: .putioCore),
          detail: transport.subtitleSize.title
        ) {
          let sizes = PutioSubtitleTextSize.allCases
          let next = sizes.firstIndex(of: transport.subtitleSize).map { ($0 + 1) % sizes.count }
          transport.setSubtitleSize(sizes[next ?? 0])
        },
        TVDirectMenuRow(
          id: delayID, title: String(localized: "Delay", bundle: .putioCore),
          detail: transport.subtitleTiming.text
        ) {},
        TVDirectMenuRow(
          id: "video.subtitle-timing.reset", title: String(localized: "Reset", bundle: .putioCore)
        ) { transport.resetSubtitleTiming() },
      ]
    case .audio:
      return transport.audioTracks.map { track in
        TVDirectMenuRow(
          id: "video.audio.\(track.id)",
          title: track.detail.map { "\(track.title) (\($0))" } ?? track.title,
          checked: transport.selectedAudio == track.id
        ) {
          transport.selectAudio(track.id)
          close()
        }
      }
    case .speed:
      return PutioAudioSpeed.tvMenu.map { speed in
        TVDirectMenuRow(
          id: "video.speed.\(speed.identifier)", title: speed.title,
          checked: transport.speed == speed
        ) {
          transport.setSpeed(speed)
          close()
        }
      }
    }
  }
}

enum TVDirectControlsMetrics {
  static let skipBadgeDuration = Duration.milliseconds(900)
  static let captionInset = PutioTheme.TV.Spacing.large
  static let captionLift: CGFloat = 280
  static let progressHeight: CGFloat = 10
  static let chipsToProgress: CGFloat = 38
  static let progressToTimes: CGFloat = 24
  static let bottomLift: CGFloat = 14
  static let scrimHeight: CGFloat = 480
}

/// The transport overlay of board `rd-tvos-dp-01-controls`: the file name and
/// chips, the progress bar, elapsed and remaining time over a bottom scrim,
/// with an open chip's menu above the row.
struct TVDirectControls<Menu: View, Chips: View>: View {
  let title: String
  let timeline: PutioVideoTimeline
  var dimmed = false
  @ViewBuilder let menu: Menu
  @ViewBuilder let chips: Chips

  private var shade: Color { dimmed ? TVDirectMenuMetrics.dimmed : .white }

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
        .allowsHitTesting(false)
      if dimmed {
        Color.black.opacity(TVDirectMenuMetrics.scrim).ignoresSafeArea().allowsHitTesting(false)
      }
      VStack(alignment: .leading, spacing: 0) {
        VStack(alignment: .trailing, spacing: TVDirectMenuMetrics.menuGap) {
          menu
          HStack(alignment: .center, spacing: PutioTheme.TV.Spacing.medium) {
            Text(title)
              .putioFont(PutioTheme.TV.Typography.body)
              .foregroundStyle(PutioTheme.TV.Colors.textPrimary)
              .lineLimit(1)
              .colorMultiply(shade)
              .accessibilityIdentifier("video.title")
            Spacer(minLength: 0)
            chips
          }
          .frame(maxWidth: .infinity)
        }
        TVDirectProgressBar(fraction: fraction)
          .frame(height: TVDirectControlsMetrics.progressHeight)
          .padding(.top, TVDirectControlsMetrics.chipsToProgress)
          .colorMultiply(shade)
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
        .colorMultiply(shade)
        .padding(.top, TVDirectControlsMetrics.progressToTimes)
      }
      .padding(.bottom, TVDirectControlsMetrics.bottomLift)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
      .tvOverscanPadding()
    }
  }
}

extension TVDirectControls where Menu == EmptyView, Chips == EmptyView {
  init(title: String, timeline: PutioVideoTimeline) {
    self.init(title: title, timeline: timeline, menu: { EmptyView() }, chips: { EmptyView() })
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
