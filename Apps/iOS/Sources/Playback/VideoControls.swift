import AVFoundation
import Observation
import PutioCore
import SwiftUI
import UIKit

final class PutioVideoSurfaceView: UIView {
  var onPlayerChange: (@MainActor (AVPlayer?) -> Void)?
  var onPlaybackControlsChange: (@MainActor (Bool) -> Void)?

  override class var layerClass: AnyClass { AVPlayerLayer.self }

  var player: AVPlayer? {
    get { playerLayer?.player }
    set {
      guard playerLayer?.player !== newValue else { return }
      playerLayer?.player = newValue
      onPlayerChange?(newValue)
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

  @ObservationIgnored private var player: AVPlayer?
  @ObservationIgnored private var timeObservation: Any?
  @ObservationIgnored private var statusObservation: NSKeyValueObservation?
  @ObservationIgnored private var selectionObservation: NSObjectProtocol?
  @ObservationIgnored private var audible:
    (group: AVMediaSelectionGroup, options: [AVMediaSelectionOption])?
  @ObservationIgnored private var legible:
    (group: AVMediaSelectionGroup, options: [AVMediaSelectionOption])?
  @ObservationIgnored private var trackLoad: Task<Void, Never>?

  var timeline: PutioVideoTimeline { playhead.timeline }

  var selectedAudioTitle: String? {
    selectedAudio.flatMap { index in audioTracks.first { $0.id == index }?.title }
  }

  var selectedSubtitleTitle: String {
    selectedSubtitle.flatMap { index in subtitles.first { $0.id == index }?.title }
      ?? String(localized: "Off")
  }

  func attach(_ player: AVPlayer?) {
    detach()
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
    if controlsEnabled { loadTracks() }
  }

  func setControlsEnabled(_ enabled: Bool) {
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

  func skip(by seconds: Double) {
    seek(to: timeline.target(skippingBy: seconds))
  }

  func seek(to seconds: Double) {
    guard controlsEnabled, let player else { return }
    let seek = playhead.seekStarted(to: seconds)
    player.seek(
      to: CMTime(seconds: playhead.timeline.elapsedSeconds, preferredTimescale: 600),
      toleranceBefore: .zero,
      toleranceAfter: .zero
    ) { [weak self] _ in
      Task { @MainActor [weak self] in self?.playhead.seekFinished(seek) }
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

  private func refreshPlaying() {
    guard let player else { return }
    isPlaying = player.timeControlStatus != .paused
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
        .accessibilityHidden(true)
      VStack(spacing: 0) {
        PutioVideoTopBar(title: title, onClose: onClose) {
          trailing
          PutioVideoOptionsMenu(transport: transport) { visibility.interacted() }
        }
        Spacer(minLength: PutioTheme.Spacing.space3)
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
    .opacity(visibility.isVisible ? 1 : 0)
    .allowsHitTesting(visibility.isVisible)
    .accessibilityHidden(!visibility.isVisible)
    .statusBarHidden(!visibility.isVisible)
    .persistentSystemOverlays(visibility.isVisible ? .automatic : .hidden)
    .overlay {
      if !visibility.isVisible {
        Color.clear
          .contentShape(Rectangle())
          .onTapGesture { animate { visibility.toggled() } }
          .accessibilityHidden(true)
      }
    }
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

struct PutioVideoOptionsMenu: View {
  let transport: PutioVideoTransport
  let onChange: () -> Void

  var body: some View {
    Menu {
      if transport.audioTracks.count > 1 {
        Menu {
          ForEach(transport.audioTracks) { track in
            choice(track.title, selected: transport.selectedAudio == track.id) {
              transport.selectAudio(track.id)
            }
          }
        } label: {
          Text("Audio")
          if let title = transport.selectedAudioTitle { Text(title) }
        }
      }
      if !transport.subtitles.isEmpty {
        Menu {
          choice(String(localized: "Off"), selected: transport.selectedSubtitle == nil) {
            transport.selectSubtitle(nil)
          }
          ForEach(transport.subtitles) { track in
            choice(track.title, selected: transport.selectedSubtitle == track.id) {
              transport.selectSubtitle(track.id)
            }
          }
        } label: {
          Text("Subtitles")
          Text(transport.selectedSubtitleTitle)
        }
      }
      Menu {
        ForEach(PutioAudioSpeed.allCases, id: \.self) { speed in
          choice(speed.title, selected: transport.speed == speed) {
            transport.setSpeed(speed)
          }
        }
      } label: {
        Text("Playback speed")
        Text(transport.speed.title)
      }
    } label: {
      Image(putioIcon: .dotsThree)
        .resizable()
        .scaledToFit()
        .frame(width: 22, height: 22)
        .foregroundStyle(.white)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }
    .disabled(!transport.controlsEnabled)
    .accessibilityLabel(String(localized: "More"))
    .accessibilityIdentifier("video.options")
  }

  private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
    Button {
      action()
      onChange()
    } label: {
      if selected {
        Label(title, systemImage: "checkmark")
      } else {
        Text(title)
      }
    }
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
