import AVFoundation
import AVKit
import Observation
import PutioCore
import SwiftUI
import UIKit

struct PutioVideoTrackSelection: Equatable {
  let audio: Int?
  let subtitle: Int?
}

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

  @ObservationIgnored private var controller: AVPictureInPictureController?
  @ObservationIgnored private var observations: [NSKeyValueObservation] = []

  func attach(to layer: AVPlayerLayer) {
    guard isSupported, controller?.playerLayer !== layer else { return }
    release()
    guard let controller = AVPictureInPictureController(playerLayer: layer) else { return }
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
    guard controller?.playerLayer === layer else { return }
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
    isActive = controller?.isPictureInPictureActive ?? false
  }

  private func release() {
    for observation in observations { observation.invalidate() }
    observations = []
    if let controller {
      if controller.isPictureInPictureActive { controller.stopPictureInPicture() }
      controller.delegate = nil
    }
    controller = nil
    refresh()
  }
}

struct PutioVideoAirPlay: Equatable {
  let deviceName: String?

  static func current(isActive: Bool) -> PutioVideoAirPlay? {
    #if DEBUG
      if let device = harnessDevice { return PutioVideoAirPlay(deviceName: device) }
    #endif
    guard isActive else { return nil }
    let output = AVAudioSession.sharedInstance().currentRoute.outputs.first {
      $0.portType == .airPlay
    }
    return PutioVideoAirPlay(deviceName: output?.portName)
  }

  var message: String? {
    deviceName.map { String(localized: "This video is playing on “\($0)”.") }
  }

  #if DEBUG
    private static let harnessDevice: String? = {
      let arguments = ProcessInfo.processInfo.arguments
      guard let index = arguments.firstIndex(of: "--putio-harness-airplay-device"),
        arguments.indices.contains(index + 1)
      else { return nil }
      return arguments[index + 1]
    }()
  #endif
}

@MainActor
@Observable
final class PutioVideoTransport {
  struct Track: Identifiable, Equatable {
    let id: Int
    let title: String
  }

  private(set) var isPlaying = false
  private var playhead = PutioVideoPlayhead()
  private(set) var speed: PutioAudioSpeed = .normal
  private(set) var controlsEnabled = false
  private(set) var audioTracks: [Track] = []
  private(set) var selectedAudio: Int?
  private(set) var subtitles: [Track] = []
  private(set) var selectedSubtitle: Int?
  private(set) var airPlay: PutioVideoAirPlay?
  let pictureInPicture = PutioVideoPictureInPicture()
  let wait: PutioVideoWaitModel

  @ObservationIgnored private var player: AVPlayer?
  @ObservationIgnored private var attachment: UInt64 = 0
  @ObservationIgnored private var timeObservation: Any?
  @ObservationIgnored private var statusObservation: NSKeyValueObservation?
  @ObservationIgnored private var externalPlaybackObservation: NSKeyValueObservation?
  @ObservationIgnored private var routeObservation: NSObjectProtocol?
  @ObservationIgnored private var selectionObservation: NSObjectProtocol?
  @ObservationIgnored private var audible:
    (group: AVMediaSelectionGroup, options: [AVMediaSelectionOption])?
  @ObservationIgnored private var legible:
    (group: AVMediaSelectionGroup, options: [AVMediaSelectionOption])?
  @ObservationIgnored private var trackLoad: Task<Void, Never>?
  @ObservationIgnored var onReload: (@MainActor (PutioVideoTrackSelection?) -> Void)?

  init() {
    wait = PutioVideoWaitModel()
  }

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
    wait.restart()
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
    externalPlaybackObservation = player.observe(
      \.isExternalPlaybackActive, options: [.initial, .new]
    ) { [weak self] _, _ in
      Task { @MainActor [weak self] in self?.refreshAirPlay() }
    }
    routeObservation = NotificationCenter.default.addObserver(
      forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.refreshAirPlay() }
    }
  }

  func setControlsEnabled(_ enabled: Bool, for player: AVPlayer?) {
    guard player === self.player else { return }
    controlsEnabled = enabled
    if enabled { loadTracks() }
  }

  func togglePlayPause() {
    guard controlsEnabled, let player else { return }
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

  func reload() {
    let tracks =
      audioTracks.isEmpty && subtitles.isEmpty
      ? nil : PutioVideoTrackSelection(audio: selectedAudio, subtitle: selectedSubtitle)
    onReload?(tracks)
  }

  func skip(by seconds: Double) {
    seek(to: timeline.target(skippingBy: seconds))
  }

  func seek(to seconds: Double) {
    guard controlsEnabled, let player else { return }
    let seek = playhead.seekStarted(to: seconds)
    let attachment = attachment
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
    player?.defaultRate = speed.rawValue
    if isPlaying { player?.rate = speed.rawValue }
  }

  func selectAudio(_ index: Int) {
    guard let item = player?.currentItem, let audible, audible.options.indices.contains(index)
    else { return }
    item.select(audible.options[index], in: audible.group)
    selectedAudio = index
  }

  func selectSubtitle(_ index: Int?) {
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
    externalPlaybackObservation?.invalidate()
    externalPlaybackObservation = nil
    if let routeObservation { NotificationCenter.default.removeObserver(routeObservation) }
    routeObservation = nil
    airPlay = nil
    if let selectionObservation { NotificationCenter.default.removeObserver(selectionObservation) }
    selectionObservation = nil
    player = nil
    audible = nil
    legible = nil
    audioTracks = []
    subtitles = []
    selectedAudio = nil
    selectedSubtitle = nil
    isPlaying = false
    controlsEnabled = false
    playhead = PutioVideoPlayhead()
  }

  private func refreshAirPlay() {
    guard let player else { return }
    airPlay = PutioVideoAirPlay.current(isActive: player.isExternalPlaybackActive)
  }

  private func refreshPlaying() {
    guard let player else { return }
    isPlaying = player.timeControlStatus != .paused
    wait.activityChanged(Self.activity(player.timeControlStatus))
  }

  private static func activity(_ status: AVPlayer.TimeControlStatus) -> PutioVideoPlayerActivity {
    switch status {
    case .playing: .playing
    case .waitingToPlayAtSpecifiedRate: .waiting
    case .paused: .paused
    @unknown default: .paused
    }
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
      audible = audibleGroup.map { ($0, $0.options) }
      legible = legibleGroup.map { group in
        (group, group.options.filter { !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) })
      }
      audioTracks = Self.tracks(audible?.options ?? [])
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
}

struct PutioVideoControls<Trailing: View>: View {
  let title: String
  let transport: PutioVideoTransport
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
      if let airPlay = transport.airPlay {
        airPlayCentre(showing: true, transport: false, airPlay: airPlay)
          .allowsHitTesting(false)
      }
      if visibility.isVisible {
        ZStack {
          VStack(spacing: 0) {
            PutioVideoTopBar(title: title, onClose: onClose) {
              if transport.airPlay == nil {
                PutioVideoPictureInPictureButton(transport: transport) { visibility.interacted() }
              }
              PutioVideoAirPlayButton(isActive: transport.airPlay != nil)
              if transport.airPlay == nil { trailing }
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
          if let airPlay = transport.airPlay {
            airPlayCentre(showing: false, transport: true, airPlay: airPlay)
          } else {
            centre
          }
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
    .onChange(of: transport.wait.state.showsSpinner, initial: true) { _, buffering in
      animate { visibility.set(.buffering, buffering) }
    }
    .onChange(of: voiceOverEnabled, initial: true) { _, enabled in
      visibility.set(.voiceOver, enabled)
    }
  }

  private var centre: some View {
    VStack(spacing: PutioTheme.Spacing.space4) {
      if transport.wait.state == .bufferingLong {
        bufferingLabel
          .hidden()
          .accessibilityHidden(true)
      }
      transportRow(circled: true)
      if transport.wait.state == .bufferingLong {
        bufferingLabel
          .accessibilityIdentifier("video.buffering")
      }
    }
  }

  private func airPlayCentre(
    showing placeholder: Bool, transport shown: Bool, airPlay: PutioVideoAirPlay
  )
    -> some View
  {
    VStack(spacing: PutioTheme.Spacing.space5) {
      PutioVideoAirPlayPlaceholder(airPlay: airPlay)
        .opacity(placeholder ? 1 : 0)
        .accessibilityHidden(!placeholder)
      transportRow(circled: false)
        .opacity(shown ? 1 : 0)
        .accessibilityHidden(!shown)
    }
    .padding(.horizontal, PutioTheme.Spacing.space4)
  }

  private var bufferingLabel: some View {
    Text(String(localized: "Buffering…"))
      .putioFont(PutioTheme.Typography.body)
      .foregroundStyle(.white.opacity(0.78))
  }

  private func transportRow(circled: Bool) -> some View {
    HStack(spacing: PutioTheme.Spacing.space4) {
      PutioVideoSkipButton(seconds: -PutioVideoTimeline.skipInterval, circled: circled) {
        transport.skip(by: -PutioVideoTimeline.skipInterval)
        visibility.interacted()
      }
      if transport.wait.state.showsSpinner {
        PutioVideoCircleLabel(diameter: PutioVideoMetrics.playPause, circled: circled) {
          ProgressView()
            .controlSize(.large)
            .tint(.white.opacity(0.78))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Buffering…"))
        .accessibilityIdentifier("video.buffering-spinner")
      } else {
        Button {
          transport.togglePlayPause()
          visibility.interacted()
        } label: {
          PutioVideoCircleLabel(diameter: PutioVideoMetrics.playPause, circled: circled) {
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
      }
      PutioVideoSkipButton(seconds: PutioVideoTimeline.skipInterval, circled: circled) {
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
    if pictureInPicture.isSupported {
      Button {
        pictureInPicture.toggle()
        onToggle()
      } label: {
        PutioRouteButtonLabel(icon: .pictureInPicture)
      }
      .buttonStyle(.plain)
      .disabled(!transport.controlsEnabled || !pictureInPicture.isPossible)
      .accessibilityLabel(String(localized: "Picture in Picture"))
      .accessibilityAddTraits(pictureInPicture.isActive ? .isSelected : [])
      .accessibilityIdentifier("video.picture-in-picture")
    }
  }
}

private struct PutioVideoAirPlayButton: View {
  let isActive: Bool

  var body: some View {
    PutioVideoRoutePicker(isActive: isActive)
      .frame(width: PutioRouteButtonMetrics.target, height: PutioRouteButtonMetrics.target)
      .accessibilityLabel(String(localized: "AirPlay"))
      .accessibilityAddTraits(isActive ? .isSelected : [])
      .accessibilityIdentifier("video.airplay")
  }
}

private struct PutioVideoRoutePicker: UIViewRepresentable {
  let isActive: Bool

  func makeUIView(context: Context) -> AVRoutePickerView {
    let picker = AVRoutePickerView()
    picker.prioritizesVideoDevices = true
    picker.activeTintColor = UIColor(PutioTheme.Colors.accent)
    return picker
  }

  func updateUIView(_ picker: AVRoutePickerView, context: Context) {
    picker.tintColor = isActive ? UIColor(PutioTheme.Colors.accent) : .white
  }
}

private struct PutioVideoAirPlayPlaceholder: View {
  let airPlay: PutioVideoAirPlay

  var body: some View {
    VStack(spacing: PutioTheme.Spacing.space2) {
      Image(putioIcon: .airplay)
        .resizable()
        .scaledToFit()
        .frame(width: PutioVideoMetrics.airPlayIcon, height: PutioVideoMetrics.airPlayIcon)
        .foregroundStyle(PutioTheme.Colors.accent)
        .padding(.bottom, PutioTheme.Spacing.space2)
        .accessibilityHidden(true)
      Text(String(localized: "AirPlay"))
        .putioFont(PutioTheme.Typography.heading)
        .foregroundStyle(.white)
        .accessibilityAddTraits(.isHeader)
      if let message = airPlay.message {
        Text(message)
          .putioFont(PutioTheme.Typography.body)
          .foregroundStyle(.white.opacity(0.78))
          .multilineTextAlignment(.center)
      }
    }
    .fixedSize(horizontal: false, vertical: true)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("video.airplay-placeholder")
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
              title: track.title, identifier: "video.audio.\(track.id)",
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
  let identifier: String
  let selected: Bool
  let select: @MainActor () -> Void

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.title == rhs.title && lhs.identifier == rhs.identifier && lhs.selected == rhs.selected
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
        let action = UIAction(title: choice.title, state: choice.selected ? .on : .off) { _ in
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
  var circled = true
  let action: () -> Void

  var body: some View {
    let step = Int(abs(seconds))
    let forward = seconds > 0
    Button(action: action) {
      PutioVideoCircleLabel(diameter: PutioVideoMetrics.skip, circled: circled) {
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
  static let airPlayIcon: CGFloat = 32
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
  var circled = true
  @ViewBuilder let glyph: Glyph

  var body: some View {
    glyph
      .foregroundStyle(.white)
      .frame(width: diameter, height: diameter)
      .background(Color.black.opacity(circled ? 0.75 : 0), in: Circle())
      .overlay {
        Circle().strokeBorder(
          Color.white.opacity(circled ? 0.07 : 0), lineWidth: PutioTheme.Border.width)
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
