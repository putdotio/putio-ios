import AVFoundation
import AVKit
import AetherEngine
import Combine
import Observation
import PutioCore
import SwiftUI
import UIKit

final class PutioVideoSurfaceView: UIView {
  var onPlayerChange: (@MainActor (_ old: AVPlayer?, _ new: AVPlayer?) -> Void)?
  var onPlaybackControlsChange: (@MainActor (Bool) -> Void)?

  override class var layerClass: AnyClass { AVPlayerLayer.self }

  var pictureInPicture: PutioVideoPictureInPicture?

  var player: AVPlayer? {
    get { playerLayer?.player }
    set {
      let old = playerLayer?.player
      guard old !== newValue else { return }
      playerLayer?.player = newValue
      if let playerLayer {
        if newValue == nil {
          pictureInPicture?.detach(from: playerLayer)
        } else {
          pictureInPicture?.attach(to: playerLayer)
        }
      }
      onPlayerChange?(old, newValue)
    }
  }

  var showsPlaybackControls = false {
    didSet {
      guard oldValue != showsPlaybackControls else { return }
      onPlaybackControlsChange?(showsPlaybackControls)
    }
  }

  private var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .black
    playerLayer?.videoGravity = .resizeAspect
  }

  required init?(coder: NSCoder) { nil }
}

@MainActor
@Observable
final class PutioVideoPictureInPicture: NSObject, AVPictureInPictureControllerDelegate {
  let isSupported: Bool = {
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("--putio-harness-picture-in-picture") {
        return true
      }
    #endif
    return AVPictureInPictureController.isPictureInPictureSupported()
  }()
  private(set) var isPossible = false
  private(set) var isActive = false
  /// Whether the playing route offers a picture to put in the window. AVPlayer
  /// always does; the Direct play engine only on the routes its controller covers.
  private(set) var hasRoute = false

  @ObservationIgnored private var controller: AVPictureInPictureController?
  @ObservationIgnored private var observations: [NSKeyValueObservation] = []
  @ObservationIgnored var onActiveChange: (@MainActor (Bool) -> Void)?

  var isShown: Bool { isSupported && hasRoute }

  func attach(to layer: AVPlayerLayer) {
    guard isSupported, controller?.playerLayer !== layer else { return }
    release()
    hasRoute = true
    guard let controller = AVPictureInPictureController(playerLayer: layer) else { return }
    adopt(controller)
  }

  /// The Direct play engine's route: its own controller, or none where the
  /// route has no picture the window can show.
  func attach(engineController controller: AVPictureInPictureController?, hasRoute: Bool) {
    if let controller, self.controller === controller { return }
    release()
    self.hasRoute = hasRoute
    guard let controller else { return }
    adopt(controller)
  }

  private func adopt(_ controller: AVPictureInPictureController) {
    controller.delegate = self
    self.controller = controller
    observations = [
      controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) {
        [weak self] _, _ in
        Task { @MainActor [weak self] in self?.refresh() }
      },
      controller.observe(\.isPictureInPictureActive, options: [.initial, .new]) {
        [weak self] _, _ in
        Task { @MainActor [weak self] in self?.refresh() }
      },
    ]
  }

  func detach(from layer: AVPlayerLayer) {
    guard controller?.playerLayer === layer || (controller == nil && hasRoute) else { return }
    release()
  }

  func detachEngine() {
    release()
  }

  func toggle() {
    guard let controller else { return }
    if controller.isPictureInPictureActive {
      controller.stopPictureInPicture()
    } else if controller.isPictureInPicturePossible {
      controller.startPictureInPicture()
    }
  }

  nonisolated func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler:
      @escaping (Bool) -> Void
  ) {
    completionHandler(true)
  }

  private func refresh() {
    isPossible = controller?.isPictureInPicturePossible ?? false
    let active = controller?.isPictureInPictureActive ?? false
    guard active != isActive else { return }
    isActive = active
    onActiveChange?(active)
  }

  private func release() {
    for observation in observations { observation.invalidate() }
    observations = []
    if let controller {
      if controller.isPictureInPictureActive { controller.stopPictureInPicture() }
      controller.delegate = nil
    }
    controller = nil
    hasRoute = false
    refresh()
  }
}

@MainActor
@Observable
final class PutioVideoTransport {
  struct Track: Identifiable, Equatable {
    let id: Int
    let title: String
    var detail: String?
  }

  private(set) var isPlaying = false
  private var playhead = PutioVideoPlayhead()
  private(set) var speed: PutioAudioSpeed = .normal
  private(set) var controlsEnabled = false
  private(set) var audioTracks: [Track] = []
  private(set) var selectedAudio: Int?
  private(set) var subtitles: [Track] = []
  private(set) var selectedSubtitle: Int?
  /// The Direct play engine's cues on screen now; AVPlayer draws its own.
  private(set) var subtitleCues: [PutioVideoCue] = []
  let pictureInPicture = PutioVideoPictureInPicture()
  /// An MP4 original's audio streams in file order, for the Audio menu's
  /// codec and layout under Direct play on AVPlayer.
  @ObservationIgnored var originalAudioStreams: [PutioOriginalAudioStream] = []
  /// Plays an ended Direct play session again from the start; the engine
  /// cannot resume a session that reached its end.
  @ObservationIgnored var onEngineRestart: (@MainActor () -> Void)?

  @ObservationIgnored private var player: AVPlayer?
  @ObservationIgnored private var engine: AetherEngine?
  @ObservationIgnored private var engineObservations: Set<AnyCancellable> = []
  @ObservationIgnored private var attachment: UInt64 = 0
  @ObservationIgnored private var timeObservation: Any?
  @ObservationIgnored private var statusObservation: NSKeyValueObservation?
  @ObservationIgnored private var selectionObservation: NSObjectProtocol?
  @ObservationIgnored private var audible:
    (group: AVMediaSelectionGroup, options: [AVMediaSelectionOption])?
  @ObservationIgnored private var legible:
    (group: AVMediaSelectionGroup, options: [AVMediaSelectionOption])?
  @ObservationIgnored private var trackLoad: Task<Void, Never>?

  var timeline: PutioVideoTimeline { playhead.timeline }

  var selectedAudioTitle: String {
    selectedAudio.flatMap { index in audioTracks.first { $0.id == index }?.title }
      ?? String(localized: "Audio")
  }

  var selectedSubtitleTitle: String {
    selectedSubtitle.flatMap { index in subtitles.first { $0.id == index }?.title }
      ?? String(localized: "Off")
  }

  func playerChanged(from old: AVPlayer?, to new: AVPlayer?) {
    guard new != nil || old === player else { return }
    attach(new)
  }

  private func attach(_ player: AVPlayer?) {
    detach()
    attachment &+= 1
    guard let player else { return }
    self.player = player
    player.defaultRate = speed.rawValue
    timeObservation = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
    ) { [weak self] time in
      MainActor.assumeIsolated { self?.update(time: time) }
    }
    statusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) {
      [weak self] _, _ in
      Task { @MainActor [weak self] in self?.refreshPlaying() }
    }
  }

  /// Follows the Direct play engine's session: state, time, tracks, cues and
  /// Picture in Picture. `nil` lets go of the engine this transport follows.
  func engineChanged(to engine: AetherEngine?) {
    guard engine != nil || self.engine != nil else { return }
    detach()
    attachment &+= 1
    guard let engine else { return }
    self.engine = engine
    engine.$state
      .sink { [weak self] state in self?.engineStateChanged(state) }
      .store(in: &engineObservations)
    engine.clock.$currentTime.combineLatest(engine.$duration)
      .sink { [weak self] elapsed, duration in
        self?.playhead.observed(elapsedSeconds: elapsed, durationSeconds: duration)
      }
      .store(in: &engineObservations)
    engine.$audioTracks.combineLatest(engine.$activeAudioTrackIndex)
      .sink { [weak self] tracks, active in self?.engineAudioChanged(tracks, active: active) }
      .store(in: &engineObservations)
    engine.$subtitleTracks.combineLatest(engine.$activeSubtitleTrackIndex)
      .sink { [weak self] tracks, active in
        self?.subtitles = tracks.enumerated().map { index, track in
          Track(
            id: track.id,
            title: PutioTrackLabel.subtitleTitle(
              language: track.language, name: track.name, index: index))
        }
        self?.selectedSubtitle = active
      }
      .store(in: &engineObservations)
    engine.$subtitleCues.combineLatest(engine.clock.$sourceTime)
      .sink { [weak self] cues, time in self?.showCues(cues, at: time) }
      .store(in: &engineObservations)
    engine.$videoRoute.combineLatest(engine.$softwarePiPSource)
      .sink { [weak self, weak engine] route, source in
        guard let self, let engine else { return }
        self.engineRouteChanged(route, source: source, engine: engine)
      }
      .store(in: &engineObservations)
    pictureInPicture.onActiveChange = { [weak engine] active in
      engine?.pictureInPictureActive = active
    }
  }

  func setControlsEnabled(_ enabled: Bool, for player: AVPlayer?) {
    guard player === self.player else { return }
    controlsEnabled = enabled
    if enabled { loadTracks() }
  }

  func setControlsEnabled(_ enabled: Bool, for engine: AetherEngine) {
    guard engine === self.engine else { return }
    controlsEnabled = enabled
  }

  func togglePlayPause() {
    guard controlsEnabled else { return }
    if let engine {
      if engine.state == .ended {
        onEngineRestart?()
      } else if isPlaying {
        engine.pause()
      } else {
        engine.play()
      }
      isPlaying.toggle()
      return
    }
    guard let player else { return }
    if isPlaying {
      player.pause()
    } else {
      if let duration = timeline.durationSeconds, timeline.elapsedSeconds >= duration - 0.5 {
        seek(to: 0)
      }
      player.play()
    }
    isPlaying.toggle()
  }

  func skip(by seconds: Double) {
    seek(to: timeline.target(skippingBy: seconds))
  }

  func seek(to seconds: Double) {
    guard controlsEnabled else { return }
    let attachment = attachment
    if let engine {
      let seek = playhead.seekStarted(to: seconds)
      let target = playhead.timeline.elapsedSeconds
      Task { @MainActor [weak self, weak engine] in
        await engine?.seek(to: target)
        guard let self, self.attachment == attachment else { return }
        playhead.seekFinished(seek)
      }
      return
    }
    guard let player else { return }
    let seek = playhead.seekStarted(to: seconds)
    player.seek(
      to: CMTime(seconds: playhead.timeline.elapsedSeconds, preferredTimescale: 600),
      toleranceBefore: .zero,
      toleranceAfter: .zero
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self, self.attachment == attachment else { return }
        playhead.seekFinished(seek)
      }
    }
  }

  func setSpeed(_ speed: PutioAudioSpeed) {
    self.speed = speed
    if let engine {
      engine.setRate(speed.rawValue)
      return
    }
    player?.defaultRate = speed.rawValue
    if isPlaying { player?.rate = speed.rawValue }
  }

  func selectAudio(_ index: Int) {
    if let engine {
      guard audioTracks.contains(where: { $0.id == index }) else { return }
      engine.selectAudioTrack(index: index)
      selectedAudio = index
      return
    }
    guard let item = player?.currentItem, let audible, audible.options.indices.contains(index)
    else { return }
    item.select(audible.options[index], in: audible.group)
    selectedAudio = index
  }

  func selectSubtitle(_ index: Int?) {
    if let engine {
      if let index {
        guard subtitles.contains(where: { $0.id == index }) else { return }
        engine.selectSubtitleTrack(index: index)
      } else {
        engine.clearSubtitle()
      }
      selectedSubtitle = index
      return
    }
    guard let item = player?.currentItem, let legible else { return }
    if let index {
      guard legible.options.indices.contains(index) else { return }
      item.select(legible.options[index], in: legible.group)
    } else {
      item.select(nil, in: legible.group)
    }
    selectedSubtitle = index
  }

  private func detach() {
    trackLoad?.cancel()
    trackLoad = nil
    if let timeObservation, let player { player.removeTimeObserver(timeObservation) }
    timeObservation = nil
    statusObservation?.invalidate()
    statusObservation = nil
    if let selectionObservation { NotificationCenter.default.removeObserver(selectionObservation) }
    selectionObservation = nil
    player = nil
    if engine != nil {
      engineObservations.removeAll()
      pictureInPicture.onActiveChange = nil
      pictureInPicture.detachEngine()
      engine = nil
    }
    audible = nil
    legible = nil
    audioTracks = []
    subtitles = []
    subtitleCues = []
    selectedAudio = nil
    selectedSubtitle = nil
    isPlaying = false
    controlsEnabled = false
    playhead = PutioVideoPlayhead()
  }

  private func refreshPlaying() {
    guard let player else { return }
    isPlaying = player.timeControlStatus != .paused
  }

  private func engineStateChanged(_ state: PlaybackState) {
    switch state {
    case .playing:
      isPlaying = true
    case .paused, .ended, .idle, .error:
      isPlaying = false
    case .loading, .seeking:
      break
    }
  }

  /// Tracks the device cannot decode are left out of the menu.
  private func engineAudioChanged(_ tracks: [TrackInfo], active: Int?) {
    audioTracks = tracks.enumerated().compactMap { index, track in
      guard PutioDirectPlayDecoders.canDecodeAudio(codec: track.codec) else { return nil }
      return Track(
        id: track.id,
        title: PutioTrackLabel.audioTitle(
          language: track.language, name: track.name, index: index),
        detail: PutioTrackLabel.audioDetail(
          codec: track.codec, profile: track.profile, channels: track.channels))
    }
    selectedAudio = active.flatMap { id in audioTracks.contains { $0.id == id } ? id : nil }
  }

  private func engineRouteChanged(
    _ route: VideoRoute, source: SoftwarePiPSource?, engine: AetherEngine
  ) {
    switch route {
    case .software:
      pictureInPicture.attach(
        engineController: source?.makePictureInPictureController(), hasRoute: source != nil)
    case .loopback, .remoteBypass:
      let layer = engine.nativePlayerLayer
      pictureInPicture.attach(
        engineController: layer.flatMap(AVPictureInPictureController.init(playerLayer:)),
        hasRoute: layer != nil)
    default:
      pictureInPicture.attach(engineController: nil, hasRoute: false)
    }
  }

  private func showCues(_ cues: [SubtitleCue], at time: Double) {
    let showing = cues.filter { $0.startTime <= time && time < $0.endTime }
    guard showing.map(\.id) != subtitleCues.map(\.id) else { return }
    subtitleCues = showing.map(PutioVideoCue.init)
  }

  private func update(time: CMTime) {
    guard let item = player?.currentItem else { return }
    playhead.observed(
      elapsedSeconds: time.isNumeric ? time.seconds : 0,
      durationSeconds: item.duration.isNumeric ? item.duration.seconds : nil)
  }

  private func loadTracks() {
    guard let item = player?.currentItem, trackLoad == nil else { return }
    trackLoad = Task { @MainActor [weak self] in
      let audibleGroup = try? await item.asset.loadMediaSelectionGroup(for: .audible)
      let legibleGroup = try? await item.asset.loadMediaSelectionGroup(for: .legible)
      guard let self, !Task.isCancelled, player?.currentItem === item else { return }
      let details = Self.details(for: audibleGroup?.options ?? [], streams: originalAudioStreams)
      let playable = (audibleGroup?.options ?? []).filter(\.isPlayable)
      audible = audibleGroup.map { ($0, playable) }
      legible = legibleGroup.map { group in
        (group, group.options.filter { !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) })
      }
      audioTracks = playable.enumerated().map { index, option in
        Track(id: index, title: option.displayName, detail: details[option])
      }
      subtitles = Self.tracks(legible?.options ?? [])
      selectionObservation = NotificationCenter.default.addObserver(
        forName: AVPlayerItem.mediaSelectionDidChangeNotification, object: item, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.refreshSelection() }
      }
      refreshSelection()
    }
  }

  private func refreshSelection() {
    guard let item = player?.currentItem else { return }
    let selection = item.currentMediaSelection
    selectedAudio = audible.flatMap { audible in
      selection.selectedMediaOption(in: audible.group).flatMap {
        audible.options.firstIndex(of: $0)
      }
    }
    selectedSubtitle = legible.flatMap { legible in
      selection.selectedMediaOption(in: legible.group).flatMap {
        legible.options.firstIndex(of: $0)
      }
    }
  }

  private static func tracks(_ options: [AVMediaSelectionOption]) -> [Track] {
    options.enumerated().map { Track(id: $0.offset, title: $0.element.displayName) }
  }

  /// An original's audio options follow its audio streams in file order.
  private static func details(
    for options: [AVMediaSelectionOption], streams: [PutioOriginalAudioStream]
  ) -> [AVMediaSelectionOption: String] {
    guard !streams.isEmpty, options.count == streams.count else { return [:] }
    var details: [AVMediaSelectionOption: String] = [:]
    for (option, stream) in zip(options, streams) {
      details[option] = PutioTrackLabel.audioDetail(
        codec: stream.codec, profile: stream.profile, channels: stream.channels)
    }
    return details
  }
}

/// One subtitle cue the Direct play engine hands the app to draw.
struct PutioVideoCue: Identifiable, Equatable {
  let id: Int
  let text: String?
  let image: CGImage?
  let position: CGRect?

  init(_ cue: SubtitleCue) {
    id = cue.id
    text = cue.text
    if case .image(let image) = cue.body {
      self.image = image.cgImage
      position = image.position
    } else {
      image = nil
      position = nil
    }
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.id == rhs.id && lhs.text == rhs.text
  }
}

struct PutioVideoControls<Trailing: View>: View {
  let title: String
  let transport: PutioVideoTransport
  var showsCast = false
  let onClose: () -> Void
  @ViewBuilder let trailing: Trailing

  @State private var visibility = PutioVideoControlsVisibility()
  @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ZStack {
      Color.clear
        .contentShape(Rectangle())
        .onTapGesture { animate { visibility.toggled() } }
        .ignoresSafeArea()
        .accessibilityHidden(true)
      if visibility.isVisible {
        ZStack {
          VStack(spacing: 0) {
            PutioVideoTopBar(
              title: title,
              showsTrailing: transport.pictureInPicture.isShown || showsCast,
              onClose: onClose
            ) {
              PutioVideoPictureInPictureButton(transport: transport) { visibility.interacted() }
              trailing
            }
            Spacer(minLength: PutioTheme.Spacing.space3)
            PutioVideoChipRow(transport: transport) {
              visibility.interacted()
            } onMenu: {
              visibility.set(.menu, $0)
            }
            .padding(.bottom, PutioVideoMetrics.chipGap)
            PutioVideoScrubber(transport: transport) {
              visibility.interacted()
            } onScrubbing: {
              visibility.set(.scrubbing, $0)
            }
          }
          .padding(PutioTheme.Spacing.space3)
          centre
        }
        .background { PutioVideoScrim().allowsHitTesting(false) }
        .transition(.opacity)
      }
    }
    .statusBarHidden(!visibility.isVisible)
    .persistentSystemOverlays(visibility.isVisible ? .automatic : .hidden)
    .task(id: visibility.idleGeneration) {
      let generation = visibility.idleGeneration
      try? await Task.sleep(for: PutioVideoControlsVisibility.idleDelay)
      guard !Task.isCancelled else { return }
      animate { visibility.idleElapsed(generation: generation, isPlaying: transport.isPlaying) }
    }
    .onChange(of: transport.isPlaying) { _, _ in animate { visibility.interacted() } }
    .onChange(of: voiceOverEnabled, initial: true) { _, enabled in
      visibility.set(.voiceOver, enabled)
    }
  }

  private var centre: some View {
    HStack(spacing: PutioTheme.Spacing.space4) {
      PutioVideoSkipButton(seconds: -PutioVideoTimeline.skipInterval) {
        transport.skip(by: -PutioVideoTimeline.skipInterval)
        visibility.interacted()
      }
      Button {
        transport.togglePlayPause()
        visibility.interacted()
      } label: {
        PutioVideoCircleLabel(diameter: PutioVideoMetrics.playPause) {
          Image(putioIcon: transport.isPlaying ? .pauseFill : .playFill)
            .resizable()
            .scaledToFit()
            .frame(width: 30, height: 30)
        }
      }
      .buttonStyle(.plain)
      .accessibilityLabel(
        transport.isPlaying ? String(localized: "Pause") : String(localized: "Play")
      )
      .accessibilityIdentifier("video.play-pause")
      PutioVideoSkipButton(seconds: PutioVideoTimeline.skipInterval) {
        transport.skip(by: PutioVideoTimeline.skipInterval)
        visibility.interacted()
      }
    }
    .disabled(!transport.controlsEnabled)
  }

  private func animate(_ change: () -> Void) {
    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2), change)
  }
}

private struct PutioVideoScrubber: View {
  let transport: PutioVideoTransport
  let onInteract: () -> Void
  let onScrubbing: (Bool) -> Void

  @State private var scrubSeconds: Double?

  var body: some View {
    let shown = PutioVideoTimeline(
      elapsedSeconds: scrubSeconds ?? transport.timeline.elapsedSeconds,
      durationSeconds: transport.timeline.durationSeconds)
    return HStack(spacing: PutioTheme.Spacing.space3) {
      Text(shown.elapsedText)
        .accessibilityIdentifier("video.elapsed")
      Slider(
        value: Binding(
          get: { shown.elapsedSeconds },
          set: { seconds in
            if scrubSeconds == nil {
              transport.seek(to: seconds)
              onInteract()
            } else {
              scrubSeconds = seconds
            }
          }
        ),
        in: 0...max(shown.durationSeconds ?? 0, 1),
        onEditingChanged: { editing in
          if editing {
            scrubSeconds = transport.timeline.elapsedSeconds
          } else if let scrubSeconds {
            transport.seek(to: scrubSeconds)
            self.scrubSeconds = nil
          }
          onScrubbing(editing)
        }
      )
      .sliderThumbVisibility(.hidden)
      .tint(PutioTheme.Colors.accent)
      .disabled(!transport.controlsEnabled || shown.durationSeconds == nil)
      .accessibilityLabel(String(localized: "Playback position"))
      .accessibilityValue(shown.elapsedText)
      .accessibilityIdentifier("video.scrubber")
      Text(shown.remainingText)
        .accessibilityIdentifier("video.remaining")
    }
    .putioFont(PutioTheme.Typography.numeric)
    .foregroundStyle(.white.opacity(0.78))
  }
}

struct PutioVideoTopBar<Trailing: View>: View {
  let title: String
  var showsTrailing = true
  let onClose: () -> Void
  @ViewBuilder let trailing: Trailing

  @State private var trailingWidth: CGFloat = 0

  var body: some View {
    ZStack {
      Text(title)
        .putioFont(PutioVideoMetrics.titleFont)
        .foregroundStyle(.white)
        .lineLimit(1)
        .truncationMode(.middle)
        .padding(
          .horizontal,
          max(trailingWidth, PutioVideoMetrics.close) + PutioTheme.Spacing.space3
        )
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("video.title")
      HStack(spacing: PutioTheme.Spacing.space3) {
        Button(action: onClose) {
          PutioVideoCircleLabel(diameter: PutioVideoMetrics.close) {
            Image(putioIcon: .x)
              .resizable()
              .scaledToFit()
              .frame(width: 16, height: 16)
          }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Close"))
        .accessibilityIdentifier("video.close")
        Spacer(minLength: 0)
        if showsTrailing {
          HStack(spacing: 0) { trailing }
            .padding(.horizontal, PutioTheme.Spacing.space1)
            .background(Color.black.opacity(0.75), in: Capsule())
            .overlay {
              Capsule().strokeBorder(Color.white.opacity(0.07), lineWidth: PutioTheme.Border.width)
            }
            .onGeometryChange(for: CGFloat.self) {
              $0.size.width
            } action: {
              trailingWidth = $0
            }
        }
      }
    }
  }
}

private struct PutioVideoPictureInPictureButton: View {
  let transport: PutioVideoTransport
  let onToggle: () -> Void

  var body: some View {
    let pictureInPicture = transport.pictureInPicture
    if pictureInPicture.isShown {
      Button {
        pictureInPicture.toggle()
        onToggle()
      } label: {
        PutioVideoRouteLabel(icon: .pictureInPicture)
      }
      .buttonStyle(.plain)
      .disabled(!transport.controlsEnabled || !pictureInPicture.isPossible)
      .accessibilityLabel(String(localized: "Picture in Picture"))
      .accessibilityAddTraits(pictureInPicture.isActive ? .isSelected : [])
      .accessibilityIdentifier("video.picture-in-picture")
    }
  }
}

private struct PutioVideoRouteLabel: View {
  let icon: PutioIcon

  var body: some View {
    Image(putioIcon: icon)
      .resizable()
      .scaledToFit()
      .frame(width: PutioVideoMetrics.routeIcon, height: PutioVideoMetrics.routeIcon)
      .foregroundStyle(.white)
      .frame(width: PutioVideoMetrics.close, height: PutioVideoMetrics.close)
      .contentShape(Rectangle())
  }
}

private struct PutioVideoChipRow: View {
  let transport: PutioVideoTransport
  let onChange: () -> Void
  let onMenu: (Bool) -> Void

  @State private var openMenus: Set<ObjectIdentifier> = []

  var body: some View {
    ViewThatFits(in: .horizontal) {
      chips(iconOnly: false)
      chips(iconOnly: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .onChange(of: openMenus.isEmpty) { _, closed in onMenu(!closed) }
  }

  private func menuPresented(_ button: ObjectIdentifier, _ presented: Bool) {
    if presented {
      openMenus.insert(button)
    } else {
      openMenus.remove(button)
    }
  }

  private func chips(iconOnly: Bool) -> some View {
    HStack(spacing: PutioTheme.Spacing.space2) {
      if !transport.audioTracks.isEmpty {
        let title = transport.selectedAudioTitle
        chip(
          icon: .speakerHigh, title: title, iconOnly: iconOnly,
          label: String(localized: "Audio: \(title)"), identifier: "video.chip.audio",
          choices: transport.audioTracks.map { track in
            PutioVideoChipChoice(
              title: track.title, detail: track.detail, identifier: "video.audio.\(track.id)",
              selected: transport.selectedAudio == track.id
            ) { transport.selectAudio(track.id) }
          })
      }
      if !transport.subtitles.isEmpty {
        let title = transport.selectedSubtitleTitle
        chip(
          icon: .closedCaptioning, title: title, iconOnly: iconOnly,
          label: String(localized: "Subtitles: \(title)"), identifier: "video.chip.subtitles",
          choices: [
            PutioVideoChipChoice(
              title: String(localized: "Off"), identifier: "video.subtitles.off",
              selected: transport.selectedSubtitle == nil
            ) { transport.selectSubtitle(nil) }
          ]
            + transport.subtitles.map { track in
              PutioVideoChipChoice(
                title: track.title, identifier: "video.subtitles.\(track.id)",
                selected: transport.selectedSubtitle == track.id
              ) { transport.selectSubtitle(track.id) }
            })
      }
      let speed = transport.speed.title
      chip(
        icon: .gauge, title: speed, iconOnly: iconOnly,
        label: String(localized: "Playback speed \(speed)"), identifier: "video.chip.speed",
        choices: PutioAudioSpeed.allCases.map { option in
          PutioVideoChipChoice(
            title: option.title, identifier: "video.speed.\(option.identifier)",
            selected: transport.speed == option
          ) { transport.setSpeed(option) }
        })
    }
  }

  private func chip(
    icon: PutioIcon, title: String, iconOnly: Bool, label: String, identifier: String,
    choices: [PutioVideoChipChoice]
  ) -> some View {
    PutioVideoChipLabel(icon: icon, title: title, iconOnly: iconOnly)
      .opacity(transport.controlsEnabled ? 1 : 0.5)
      .accessibilityHidden(true)
      .overlay {
        PutioVideoChipMenu(
          choices: choices, label: label, identifier: identifier,
          enabled: transport.controlsEnabled, onChange: onChange,
          onPresentation: menuPresented)
      }
  }
}

private struct PutioVideoChipLabel: View {
  let icon: PutioIcon
  let title: String
  let iconOnly: Bool

  var body: some View {
    HStack(spacing: PutioTheme.Spacing.space2) {
      PutioIconView(icon, size: PutioVideoMetrics.chipIcon)
      if !iconOnly {
        Text(title)
          .lineLimit(1)
          .fixedSize()
      }
    }
    .putioFont(PutioTheme.Components.Button.label)
    .foregroundStyle(.white)
    .padding(.horizontal, iconOnly ? 0 : PutioVideoMetrics.chipPadding)
    .frame(minWidth: PutioVideoMetrics.chipHeight, minHeight: PutioVideoMetrics.chipHeight)
    .background(Color.black.opacity(0.75), in: Capsule())
    .overlay {
      Capsule().strokeBorder(Color.white.opacity(0.07), lineWidth: PutioTheme.Border.width)
    }
  }
}

private struct PutioVideoChipChoice: Equatable {
  let title: String
  var detail: String?
  let identifier: String
  let selected: Bool
  let select: @MainActor () -> Void

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.title == rhs.title && lhs.detail == rhs.detail && lhs.identifier == rhs.identifier
      && lhs.selected == rhs.selected
  }
}

private struct PutioVideoChipMenu: UIViewRepresentable {
  let choices: [PutioVideoChipChoice]
  let label: String
  let identifier: String
  let enabled: Bool
  let onChange: () -> Void
  let onPresentation: (ObjectIdentifier, Bool) -> Void

  func makeUIView(context: Context) -> PutioVideoMenuButton {
    let button = PutioVideoMenuButton(type: .custom)
    button.showsMenuAsPrimaryAction = true
    return button
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize, uiView: PutioVideoMenuButton, context: Context
  ) -> CGSize? {
    proposal.replacingUnspecifiedDimensions()
  }

  func updateUIView(_ button: PutioVideoMenuButton, context: Context) {
    button.onPresentation = onPresentation
    button.isEnabled = enabled
    button.accessibilityLabel = label
    button.accessibilityIdentifier = identifier
    guard button.choices != choices else { return }
    button.choices = choices
    let onChange = onChange
    button.menu = UIMenu(
      options: .singleSelection,
      children: choices.map { choice in
        let action = UIAction(
          title: choice.title, subtitle: choice.detail, state: choice.selected ? .on : .off
        ) { _ in
          choice.select()
          onChange()
        }
        action.accessibilityIdentifier = choice.identifier
        return action
      })
  }

  static func dismantleUIView(_ button: PutioVideoMenuButton, coordinator: ()) {
    guard button.isPresentingMenu, let onPresentation = button.onPresentation else { return }
    let id = ObjectIdentifier(button)
    Task { @MainActor in onPresentation(id, false) }
  }
}

private final class PutioVideoMenuButton: UIButton {
  var onPresentation: ((ObjectIdentifier, Bool) -> Void)?
  var choices: [PutioVideoChipChoice] = []
  private(set) var isPresentingMenu = false

  override func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    willDisplayMenuFor configuration: UIContextMenuConfiguration,
    animator: (any UIContextMenuInteractionAnimating)?
  ) {
    super.contextMenuInteraction(
      interaction, willDisplayMenuFor: configuration, animator: animator)
    isPresentingMenu = true
    onPresentation?(ObjectIdentifier(self), true)
  }

  override func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    willEndFor configuration: UIContextMenuConfiguration,
    animator: (any UIContextMenuInteractionAnimating)?
  ) {
    super.contextMenuInteraction(interaction, willEndFor: configuration, animator: animator)
    isPresentingMenu = false
    onPresentation?(ObjectIdentifier(self), false)
  }
}

private struct PutioVideoSkipButton: View {
  let seconds: Double
  let action: () -> Void

  var body: some View {
    let step = Int(abs(seconds))
    let forward = seconds > 0
    Button(action: action) {
      PutioVideoCircleLabel(diameter: PutioVideoMetrics.skip) {
        Image(systemName: forward ? "goforward.\(step)" : "gobackward.\(step)")
          .font(.system(size: 24))
      }
    }
    .buttonStyle(.plain)
    .accessibilityLabel(
      forward
        ? String(localized: "Forward \(step) seconds") : String(localized: "Back \(step) seconds")
    )
    .accessibilityIdentifier(forward ? "video.skip-forward" : "video.skip-back")
  }
}

private enum PutioVideoMetrics {
  static let close: CGFloat = 44
  static let routeIcon: CGFloat = 20
  static let chipHeight: CGFloat = 34
  static let chipPadding: CGFloat = 14
  static let chipGap: CGFloat = 12
  static let chipIcon = PutioMetricRole(value: PutioTheme.Typography.sizeBase, relativeTo: .caption)
  static let skip: CGFloat = 56
  static let playPause: CGFloat = 72
  static let titleFont = PutioFontRole(
    fontName: PutioTheme.Components.Button.label.fontName,
    size: PutioTheme.Typography.sizeBase,
    lineHeight: PutioTheme.Components.Button.label.lineHeight,
    textStyle: .body
  )
}

struct PutioVideoCircleLabel<Glyph: View>: View {
  let diameter: CGFloat
  @ViewBuilder let glyph: Glyph

  var body: some View {
    glyph
      .foregroundStyle(.white)
      .frame(width: diameter, height: diameter)
      .background(Color.black.opacity(0.75), in: Circle())
      .overlay {
        Circle().strokeBorder(Color.white.opacity(0.07), lineWidth: PutioTheme.Border.width)
      }
      .contentShape(Circle())
  }
}

private struct PutioVideoScrim: View {
  var body: some View {
    LinearGradient(
      stops: [
        .init(color: .black.opacity(0.45), location: 0),
        .init(color: .clear, location: 0.3),
        .init(color: .clear, location: 0.7),
        .init(color: .black.opacity(0.45), location: 1),
      ],
      startPoint: .top,
      endPoint: .bottom
    )
    .ignoresSafeArea()
  }
}
