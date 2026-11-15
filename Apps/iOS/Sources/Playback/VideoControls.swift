import AVFoundation
import AVKit
import AetherEngine
import Combine
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
      showsFirstFrame = false
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

  private(set) var showsFirstFrame = false
  private var readyForDisplayObservation: NSKeyValueObservation?

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .black
    playerLayer?.videoGravity = .resizeAspect
    readyForDisplayObservation = playerLayer?.observe(\.isReadyForDisplay, options: [.new]) {
      [weak self] layer, _ in
      guard layer.isReadyForDisplay else { return }
      Task { @MainActor [weak self] in
        guard self?.player != nil else { return }
        self?.showsFirstFrame = true
      }
    }
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
    var detail: String?
  }

  private(set) var isPlaying = false
  private var playhead = PutioVideoPlayhead()
  private(set) var speed: PutioAudioSpeed
  private(set) var controlsEnabled = false
  private(set) var audioTracks: [Track] = []
  private(set) var selectedAudio: Int?
  private(set) var subtitles: [PutioSubtitleTrack] = []
  private(set) var selectedSubtitle: Int?
  private(set) var airPlay: PutioVideoAirPlay?
  private(set) var subtitleCues: [PutioVideoCue] = []
  private(set) var subtitleSize: PutioSubtitleTextSize
  private(set) var subtitleTiming = PutioSubtitleTiming()
  #if DEBUG
    private(set) var shownCaption: String?
  #endif
  private(set) var supportsAirPlay = true
  var subtitleListings: [PutioSubtitleListing] = []
  var toast: PutioToast?
  let pictureInPicture = PutioVideoPictureInPicture()
  let wait: PutioVideoWaitModel
  @ObservationIgnored var originalAudioStreams: [PutioOriginalAudioStream] = []
  @ObservationIgnored var onEngineRestart: (@MainActor (Double) -> Void)?

  @ObservationIgnored private var player: AVPlayer?
  @ObservationIgnored private var engine: AetherEngine?
  @ObservationIgnored private var engineObservations: Set<AnyCancellable> = []
  @ObservationIgnored private var engineRoute: (VideoRoute, ObjectIdentifier?)?
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
  @ObservationIgnored private let speedStore: PutioAudioSpeedStore
  @ObservationIgnored private var audioRenditions: [PutioAudioRendition] = []
  @ObservationIgnored private var audioSwitch: PutioVideoAudioSwitch?
  @ObservationIgnored private var audioErrorObservation: NSObjectProtocol?
  @ObservationIgnored private var errorLogObservation: NSObjectProtocol?
  @ObservationIgnored private var renditionLoad: Task<Void, Never>?
  @ObservationIgnored private var subtitleRenditions: [URL] = []
  @ObservationIgnored private var checkedErrorEvents = 0
  @ObservationIgnored private var subtitleSelectedAt: Date?
  @ObservationIgnored private let sizeMemory: PutioSubtitleSizeMemory
  @ObservationIgnored private let captionFeed = PutioVideoCaptionFeed()
  @ObservationIgnored private var captionObservation: Any?
  @ObservationIgnored private var engineCues: (cues: [SubtitleCue], time: Double) = ([], 0)
  @ObservationIgnored var onReload: (@MainActor (PutioVideoTrackSelection?) -> Void)?
  @ObservationIgnored var onSubtitlePicked: (@MainActor (PutioSubtitleTrack?) -> Void)?
  @ObservationIgnored var onSubtitleFailed: (@MainActor (PutioSubtitleTrack) -> Void)?

  init(speedStore: PutioAudioSpeedStore? = nil, sizeMemory: PutioSubtitleSizeMemory? = nil) {
    wait = PutioVideoWaitModel()
    let speedStore = speedStore ?? .video()
    self.speedStore = speedStore
    speed = speedStore.load()
    let sizeMemory = sizeMemory ?? .video()
    self.sizeMemory = sizeMemory
    subtitleSize = sizeMemory.size
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

  var subtitleMenu: PutioSubtitleMenu {
    PutioSubtitleMenu(tracks: subtitles, listings: engine == nil ? subtitleListings : [])
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
    captionObservation = player.addPeriodicTimeObserver(
      forInterval: CMTime(value: 1, timescale: 20), queue: .main
    ) { [weak self] time in
      MainActor.assumeIsolated { self?.refreshCaptions(at: time.seconds) }
    }
    pictureInPicture.onActiveChange = { [weak self] _ in self?.refreshCaptionRendering() }
    if let item = player.currentItem {
      captionFeed.attach(to: item)
      watchSubtitleFailures(of: item)
    }
    refreshCaptionRendering()
  }

  func engineChanged(to engine: AetherEngine) {
    detach()
    attachment &+= 1
    wait.restart()
    self.engine = engine
    engine.setSoftwareSubtitleDelay(subtitleTiming.seconds)
    engine.$state
      .sink { [weak self] state in self?.engineStateChanged(state) }
      .store(in: &engineObservations)
    engine.$playbackPhase
      .sink { [weak self] phase in self?.wait.activityChanged(Self.activity(phase)) }
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
          PutioSubtitleTrack(
            id: track.id,
            title: PutioTrackLabel.subtitleTitle(
              language: track.language, name: track.name, index: index),
            languageTag: track.language)
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
    pictureInPicture.onActiveChange = { [weak self, weak engine] active in
      guard let engine else { return }
      engine.pictureInPictureActive = active
      self?.showNativeSubtitle(in: engine, active: active)
    }
  }

  func setControlsEnabled(_ enabled: Bool, for player: AVPlayer?) {
    guard player === self.player else { return }
    controlsEnabled = enabled
    if enabled { loadTracks() }
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
    guard controlsEnabled else { return }
    if let engine {
      if engine.state == .ended {
        let elapsed = timeline.elapsedSeconds
        let duration = timeline.durationSeconds ?? 0
        onEngineRestart?(elapsed >= duration - 0.5 ? 0 : elapsed)
      } else if isPlaying {
        engine.pause()
      } else {
        engine.play()
      }
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
    captionFeed.clear()
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
    speedStore.save(speed)
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
    guard let item = player?.currentItem, let audible, audible.options.indices.contains(index),
      index != selectedAudio
    else { return }
    let rendition = Self.rendition(
      of: audible.options[index], at: index, count: audible.options.count, in: audioRenditions)
    let now = Date()
    let pending = audioSwitch.flatMap { $0.isOver(at: now) ? nil : $0 }
    audioSwitch = (pending?.previous ?? selectedAudio).map {
      PutioVideoAudioSwitch(previous: $0, playlist: rendition?.uri, startedAt: now)
    }
    item.select(audible.options[index], in: audible.group)
    selectedAudio = index
  }

  private func watchAudioFailures(of item: AVPlayerItem) {
    audioErrorObservation = NotificationCenter.default.addObserver(
      forName: AVPlayerItem.newErrorLogEntryNotification, object: item, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.checkAudioFailure(of: item) }
    }
  }

  private func checkAudioFailure(of item: AVPlayerItem) {
    guard player?.currentItem === item, let audible, let events = item.errorLog()?.events else {
      return
    }
    guard var audioSwitch else { return }
    if audioSwitch.playlist == nil, let selectedAudio,
      audible.options.indices.contains(selectedAudio),
      let playlist = Self.rendition(
        of: audible.options[selectedAudio], at: selectedAudio, count: audible.options.count,
        in: audioRenditions)?.uri
    {
      audioSwitch = PutioVideoAudioSwitch(
        previous: audioSwitch.previous, playlist: playlist, startedAt: audioSwitch.startedAt)
      self.audioSwitch = audioSwitch
    }
    guard events.contains(where: { audioSwitch.failed(by: PutioVideoErrorEvent($0)) }) else {
      if audioSwitch.isOver(at: Date()) { self.audioSwitch = nil }
      return
    }
    self.audioSwitch = nil
    guard audible.options.indices.contains(audioSwitch.previous) else { return }
    item.select(audible.options[audioSwitch.previous], in: audible.group)
    selectedAudio = audioSwitch.previous
    toast = PutioToast(
      String(localized: "Couldn’t switch audio track"), icon: .warning, width: .fit)
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
    if let engine {
      engine.setSoftwareSubtitleDelay(subtitleTiming.seconds)
      showCues(engineCues.cues, at: engineCues.time)
    } else if let player {
      refreshCaptions(at: player.currentTime().seconds)
    }
  }

  private func refreshCaptionRendering() {
    guard let player else { return }
    captionFeed.rendersNatively = pictureInPicture.isActive || player.isExternalPlaybackActive
    refreshCaptions(at: player.currentTime().seconds)
  }

  private func refreshCaptions(at seconds: Double) {
    guard engine == nil, seconds.isFinite else { return }
    let cues =
      captionFeed.rendersNatively
      ? [] : captionFeed.cues(at: seconds, offset: subtitleTiming.seconds)
    showCaption(cues, at: seconds)
  }

  private func showCaption(_ cues: [PutioVideoCue], at seconds: Double) {
    guard cues != subtitleCues else { return }
    subtitleCues = cues
    #if DEBUG
      let text = cues.compactMap { $0.text.map { String($0.characters) } }
        .joined(separator: "\n")
      if !text.isEmpty { shownCaption = text + "@" + String(format: "%.1f", seconds) }
    #endif
  }

  func pickSubtitle(_ index: Int?) {
    guard selectSubtitle(index) else { return }
    onSubtitlePicked?(index.flatMap { index in subtitles.first { $0.id == index } })
  }

  @discardableResult
  private func selectSubtitle(_ index: Int?) -> Bool {
    if let engine {
      if let index {
        guard subtitles.contains(where: { $0.id == index }) else { return false }
        engine.selectSubtitleTrack(index: index)
      } else {
        engine.clearSubtitle()
      }
      selectedSubtitle = index
      return true
    }
    guard let item = player?.currentItem, let legible else { return false }
    if let index {
      guard legible.options.indices.contains(index) else { return false }
      item.select(legible.options[index], in: legible.group)
      subtitleSelectedAt = Date()
    } else {
      item.select(nil, in: legible.group)
    }
    if index != selectedSubtitle { restartCaptions() }
    selectedSubtitle = index
    return true
  }

  private func restartCaptions() {
    captionFeed.clear()
    guard let player else { return }
    refreshCaptions(at: player.currentTime().seconds)
  }

  private func watchSubtitleFailures(of item: AVPlayerItem) {
    errorLogObservation = NotificationCenter.default.addObserver(
      forName: AVPlayerItem.newErrorLogEntryNotification, object: item, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.checkSubtitleFailures(of: item) }
    }
    guard let master = (item.asset as? AVURLAsset)?.url,
      master.scheme == "http" || master.scheme == "https",
      master.pathExtension.lowercased() == "m3u8"
    else { return }
    renditionLoad = Task { @MainActor [weak self] in
      guard let (data, _) = try? await URLSession.shared.data(from: master),
        let text = String(data: data, encoding: .utf8)
      else { return }
      guard let self, !Task.isCancelled, player?.currentItem === item else { return }
      subtitleRenditions = PutioSubtitleRenditions.uris(inMasterPlaylist: text, relativeTo: master)
      checkSubtitleFailures(of: item)
    }
  }

  private func checkSubtitleFailures(of item: AVPlayerItem) {
    guard player?.currentItem === item, !subtitleRenditions.isEmpty, let legible,
      let events = item.errorLog()?.events
    else { return }
    let selectedAt = subtitleSelectedAt
    let fresh = events.dropFirst(checkedErrorEvents).filter { event in
      guard event.errorComment?.contains(#/HTTP [45]\d\d/#) == true else { return false }
      guard let selectedAt, let date = event.date else { return true }
      return date >= selectedAt
    }
    checkedErrorEvents = events.count
    guard let selected = item.currentMediaSelection.selectedMediaOption(in: legible.group)
    else { return }
    let failing = Set(fresh.compactMap { $0.uri.flatMap(URL.init(string:))?.absoluteURL })
    let selectedRendition = legible.group.options.firstIndex(of: selected).flatMap {
      subtitleRenditions.count == legible.group.options.count ? subtitleRenditions[$0] : nil
    }
    let failedPlaylist =
      selectedRendition.map(failing.contains)
      ?? !failing.isDisjoint(with: subtitleRenditions)
    let failedSegment = fresh.contains { event in
      if let uri = event.uri { return URL(string: uri)?.pathExtension.lowercased() == "vtt" }
      guard let subtitleSelectedAt, let date = event.date else { return false }
      return (0..<Self.subtitleLoadWindow).contains(
        date.timeIntervalSince(subtitleSelectedAt))
    }
    let failed = failedPlaylist || failedSegment
    let failedTrack = legible.options.firstIndex(of: selected).flatMap { index in
      subtitles.first { $0.id == index }
    }
    guard failed, selectSubtitle(nil) else { return }
    if let failedTrack { onSubtitleFailed?(failedTrack) }
    toast = PutioToast(String(localized: "Couldn’t load subtitles"), icon: .warning, width: .fit)
  }

  private func detach() {
    trackLoad?.cancel()
    trackLoad = nil
    if let audioErrorObservation {
      NotificationCenter.default.removeObserver(audioErrorObservation)
    }
    audioErrorObservation = nil
    audioRenditions = []
    audioSwitch = nil
    toast = nil
    if let timeObservation, let player { player.removeTimeObserver(timeObservation) }
    timeObservation = nil
    if let captionObservation, let player { player.removeTimeObserver(captionObservation) }
    captionObservation = nil
    captionFeed.detach()
    engineCues = ([], 0)
    statusObservation?.invalidate()
    statusObservation = nil
    externalPlaybackObservation?.invalidate()
    externalPlaybackObservation = nil
    if let routeObservation { NotificationCenter.default.removeObserver(routeObservation) }
    routeObservation = nil
    airPlay = nil
    if let selectionObservation { NotificationCenter.default.removeObserver(selectionObservation) }
    selectionObservation = nil
    if let errorLogObservation { NotificationCenter.default.removeObserver(errorLogObservation) }
    errorLogObservation = nil
    renditionLoad?.cancel()
    renditionLoad = nil
    subtitleRenditions = []
    checkedErrorEvents = 0
    subtitleSelectedAt = nil
    if player != nil { pictureInPicture.onActiveChange = nil }
    player = nil
    if engine != nil {
      engineObservations.removeAll()
      pictureInPicture.onActiveChange = nil
      pictureInPicture.detachEngine()
      engineRoute = nil
      supportsAirPlay = true
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

  private func refreshAirPlay() {
    guard let player else { return }
    airPlay = PutioVideoAirPlay.current(isActive: player.isExternalPlaybackActive)
    refreshCaptionRendering()
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

  private static func activity(_ phase: PlaybackPhase) -> PutioVideoPlayerActivity {
    switch phase {
    case .playing: .playing
    case .loading, .seeking, .rebuffering, .stalled: .waiting
    case .idle, .paused, .ended, .error: .paused
    }
  }

  private func engineAudioChanged(_ tracks: [TrackInfo], active: Int?) {
    let decodable = tracks.enumerated().filter {
      PutioDirectPlayDecoders.canDecodeAudio(codec: $0.element.codec)
    }
    let titles = PutioTrackLabel.distinct(
      decodable.map { index, track in
        PutioTrackLabel.audioTitle(language: track.language, name: track.name, index: index)
      })
    audioTracks = zip(decodable, titles).map { entry, title in
      Track(
        id: entry.element.id, title: title,
        detail: PutioTrackLabel.audioDetail(
          codec: entry.element.codec, profile: entry.element.profile,
          channels: entry.element.channels))
    }
    selectedAudio = active.flatMap { id in audioTracks.contains { $0.id == id } ? id : nil }
  }

  private func engineRouteChanged(
    _ route: VideoRoute, source: SoftwarePiPSource?, engine: AetherEngine
  ) {
    supportsAirPlay = route == .loopback || route == .remoteBypass
    let key = (route, source.map(ObjectIdentifier.init))
    if let engineRoute, engineRoute.0 == key.0, engineRoute.1 == key.1 { return }
    engineRoute = key
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

  private func showNativeSubtitle(in engine: AetherEngine, active: Bool) {
    let language = engine.subtitleTracks.first { $0.id == selectedSubtitle }?.language
    let native =
      active
      ? language.flatMap { language in
        engine.nativeSubtitleTracks.first { $0.language == language }?.ordinal
      } : nil
    engine.setNativeSubtitleSelected(track: native)
  }

  private func showCues(_ cues: [SubtitleCue], at time: Double) {
    engineCues = (cues, time)
    let shifted = time - subtitleTiming.seconds
    let showing = cues.filter { $0.startTime <= shifted && shifted < $0.endTime }
    guard showing.map(\.id) != subtitleCues.map(\.id) else { return }
    showCaption(showing.map(PutioVideoCue.init), at: time)
  }

  private func update(time: CMTime) {
    guard let item = player?.currentItem else { return }
    playhead.observed(
      elapsedSeconds: time.isNumeric ? time.seconds : 0,
      durationSeconds: item.duration.isNumeric ? item.duration.seconds : nil)
  }

  private func loadTracks() {
    guard let item = player?.currentItem, trackLoad == nil else { return }
    captionFeed.attach(to: item)
    trackLoad = Task { @MainActor [weak self] in
      async let renditions = Self.audioRenditions(of: item)
      let audibleGroup = try? await item.asset.loadMediaSelectionGroup(for: .audible)
      let legibleGroup = try? await item.asset.loadMediaSelectionGroup(for: .legible)
      guard let self, !Task.isCancelled, player?.currentItem === item else { return }
      let details = Self.details(for: audibleGroup?.options ?? [], streams: originalAudioStreams)
      let playable = (audibleGroup?.options ?? []).filter(\.isPlayable)
      audible = audibleGroup.map { ($0, playable) }
      legible = legibleGroup.map { group in
        (group, group.options.filter { !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) })
      }
      audioTracks = Self.audioTracks(playable, details: details, renditions: [])
      watchAudioFailures(of: item)
      subtitles = Self.subtitleTracks(
        legible?.options ?? [], defaultOption: legibleGroup?.defaultOption)
      selectionObservation = NotificationCenter.default.addObserver(
        forName: AVPlayerItem.mediaSelectionDidChangeNotification, object: item, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.refreshSelection() }
      }
      refreshSelection(stampsSubtitle: false)
      checkSubtitleFailures(of: item)
      let loaded = await renditions
      guard !Task.isCancelled, player?.currentItem === item, !loaded.isEmpty else { return }
      audioRenditions = loaded
      audioTracks = Self.audioTracks(playable, details: details, renditions: loaded)
      checkAudioFailure(of: item)
    }
  }

  private func refreshSelection(stampsSubtitle: Bool = true) {
    guard let item = player?.currentItem else { return }
    let selection = item.currentMediaSelection
    selectedAudio = audible.flatMap { audible in
      selection.selectedMediaOption(in: audible.group).flatMap {
        audible.options.firstIndex(of: $0)
      }
    }
    let subtitle = legible.flatMap { legible in
      selection.selectedMediaOption(in: legible.group).flatMap {
        legible.options.firstIndex(of: $0)
      }
    }
    if stampsSubtitle, subtitle != selectedSubtitle, subtitle != nil { subtitleSelectedAt = Date() }
    if subtitle != selectedSubtitle { restartCaptions() }
    selectedSubtitle = subtitle
  }

  private static let subtitleLoadWindow: TimeInterval = 10

  private static func tracks(_ options: [AVMediaSelectionOption]) -> [Track] {
    options.enumerated().map { Track(id: $0.offset, title: $0.element.displayName) }
  }

  static func subtitleTracks(
    _ options: [AVMediaSelectionOption], defaultOption: AVMediaSelectionOption?
  ) -> [PutioSubtitleTrack] {
    options.enumerated().map { index, option in
      PutioSubtitleTrack(
        id: index, title: option.displayName,
        languageTag: option.extendedLanguageTag ?? option.locale?.identifier,
        isDefault: option == defaultOption)
    }
  }

  private static func audioTracks(
    _ options: [AVMediaSelectionOption], details: [AVMediaSelectionOption: String],
    renditions: [PutioAudioRendition]
  ) -> [Track] {
    let renditions = options.enumerated().map { index, option in
      rendition(of: option, at: index, count: options.count, in: renditions)
    }
    let titles = PutioTrackLabel.distinct(
      options.enumerated().map { index, option in
        PutioTrackLabel.audioTitle(
          language: option.extendedLanguageTag ?? option.locale?.identifier
            ?? renditions[index]?.languageTag,
          name: nil, index: index)
      })
    return options.enumerated().map { index, option in
      Track(
        id: index, title: titles[index],
        detail: details[option]
          ?? renditions[index].flatMap {
            PutioTrackLabel.audioDetail(codec: $0.codec, profile: nil, channels: $0.channels)
          })
    }
  }

  private static func rendition(
    of option: AVMediaSelectionOption, at index: Int, count: Int,
    in renditions: [PutioAudioRendition]
  ) -> PutioAudioRendition? {
    let named = renditions.filter { $0.name == option.displayName }
    if named.count == 1 { return named[0] }
    return renditions.count == count ? renditions[index] : nil
  }

  private static let masterPlaylistLimit = 256 * 1024

  private static func audioRenditions(of item: AVPlayerItem) async -> [PutioAudioRendition] {
    guard let master = (item.asset as? AVURLAsset)?.url,
      master.scheme == "http" || master.scheme == "https",
      master.pathExtension.lowercased() == "m3u8",
      let (bytes, _) = try? await URLSession.shared.bytes(
        for: URLRequest(url: master, timeoutInterval: 10))
    else { return [] }
    var data = Data()
    do {
      for try await byte in bytes {
        data.append(byte)
        guard data.count <= masterPlaylistLimit else { return [] }
      }
    } catch {
      return []
    }
    guard let text = String(data: data, encoding: .utf8) else { return [] }
    return PutioAudioRendition.parse(masterPlaylist: text, relativeTo: master)
  }

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

extension PutioVideoErrorEvent {
  init(_ event: AVPlayerItemErrorLogEvent) {
    self.init(uri: event.uri.flatMap(URL.init(string:)), date: event.date)
  }
}

extension EnvironmentValues {
  @Entry var putioVideoControlsHold: @MainActor @Sendable (Bool) -> Void = { _ in }
}

struct PutioVideoControls<Trailing: View>: View {
  let title: String
  let transport: PutioVideoTransport
  let onClose: () -> Void
  var upNext: PutioVideoUpNext?
  @ViewBuilder let trailing: Trailing

  @State private var visibility = PutioVideoControlsVisibility()
  @State private var airPlayInsets: EdgeInsets?
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
        airPlayCentre(airPlay, placeholderLayer: true)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .padding(airPlayInsets ?? EdgeInsets())
          .allowsHitTesting(false)
      }
      if visibility.isVisible {
        ZStack {
          VStack(spacing: 0) {
            PutioVideoTopBar(title: title, onClose: onClose) {
              if transport.airPlay == nil {
                PutioVideoPictureInPictureButton(transport: transport) { visibility.interacted() }
              }
              if transport.supportsAirPlay {
                PutioVideoAirPlayButton(isActive: transport.airPlay != nil)
              }
              if transport.airPlay == nil {
                trailing.environment(\.putioVideoControlsHold) { held in
                  animate { visibility.set(.routePicker, held) }
                }
              }
            }
            if let airPlay = transport.airPlay {
              airPlayCentre(airPlay, placeholderLayer: false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .putioToast(toast)
                .onGeometryChange(for: EdgeInsets.self) { proxy in
                  let area = proxy.frame(in: .named(Self.coordinateSpace))
                  let bounds =
                    proxy.bounds(of: .named(Self.coordinateSpace)).map {
                      CGRect(origin: .zero, size: $0.size)
                    } ?? area
                  return EdgeInsets(
                    top: area.minY - bounds.minY, leading: area.minX - bounds.minX,
                    bottom: bounds.maxY - area.maxY, trailing: bounds.maxX - area.maxX)
                } action: {
                  airPlayInsets = $0
                }
            } else {
              Color.clear
                .frame(minHeight: PutioTheme.Spacing.space3, maxHeight: .infinity)
                .putioToast(toast)
                .offset(y: PutioTheme.Spacing.space2)
            }
            PutioVideoChipRow(transport: transport, upNext: upNext) {
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
          if transport.airPlay == nil { centre }
        }
        .background { PutioVideoScrim().allowsHitTesting(false) }
        .transition(.opacity)
      }
    }
    .coordinateSpace(.named(Self.coordinateSpace))
    .statusBarHidden(!visibility.isVisible)
    .persistentSystemOverlays(visibility.isVisible ? .automatic : .hidden)
    .task(id: visibility.idleGeneration) {
      let generation = visibility.idleGeneration
      try? await Task.sleep(for: PutioVideoControlsVisibility.idleDelay)
      guard !Task.isCancelled else { return }
      animate { visibility.idleElapsed(generation: generation, isPlaying: transport.isPlaying) }
    }
    .onChange(of: transport.isPlaying) { _, _ in animate { visibility.interacted() } }
    .onChange(of: transport.toast != nil) { _, shown in
      animate { visibility.set(.notice, shown) }
    }
    .onChange(of: transport.airPlay) { _, _ in animate { visibility.interacted() } }
    .onChange(of: transport.wait.state.showsSpinner, initial: true) { _, buffering in
      animate { visibility.set(.buffering, buffering) }
    }
    .onChange(of: voiceOverEnabled, initial: true) { _, enabled in
      visibility.set(.voiceOver, enabled)
    }
    .onChange(of: upNext?.showsCard == true, initial: true) { _, shown in
      animate { visibility.set(.upNext, shown) }
    }
  }

  private var toast: Binding<PutioToast?> {
    Binding(get: { transport.toast }, set: { transport.toast = $0 })
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

  private static var coordinateSpace: String { "video.controls" }

  private func airPlayCentre(_ airPlay: PutioVideoAirPlay, placeholderLayer: Bool) -> some View {
    VStack(spacing: PutioTheme.Spacing.space3) {
      if placeholderLayer {
        PutioVideoAirPlayPlaceholder(airPlay: airPlay)
        transportRow(circled: false).hidden()
      } else {
        PutioVideoAirPlayPlaceholder(airPlay: airPlay).hidden()
        transportRow(circled: false)
      }
    }
    .padding(.horizontal, PutioTheme.Spacing.space4)
    .padding(.vertical, PutioTheme.Spacing.space2)
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
        PutioVideoCircleLabel(diameter: PutioVideoMetrics.playPause(circled), circled: circled) {
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
          PutioVideoCircleLabel(diameter: PutioVideoMetrics.playPause(circled), circled: circled) {
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
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.verticalSizeClass) private var verticalSizeClass

  private var isUpright: Bool {
    horizontalSizeClass == .compact && verticalSizeClass == .regular
  }

  var body: some View {
    let layout =
      isUpright
      ? AnyLayout(VStackLayout(spacing: PutioTheme.Spacing.space3))
      : AnyLayout(ZStackLayout())
    layout {
      buttons
      Text(title)
        .putioFont(PutioVideoMetrics.titleFont)
        .foregroundStyle(.white)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: .infinity)
        .padding(
          .horizontal,
          isUpright
            ? PutioVideoMetrics.close + PutioTheme.Spacing.space2
            : max(trailingWidth, PutioVideoMetrics.close) + PutioTheme.Spacing.space3
        )
        .allowsHitTesting(false)
        .accessibilityAddTraits(.isHeader)
        .accessibilitySortPriority(1)
        .accessibilityIdentifier("video.title")
    }
    .accessibilityElement(children: .contain)
  }

  private var buttons: some View {
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
  let upNext: PutioVideoUpNext?
  let onChange: () -> Void
  let onMenu: (Bool) -> Void

  @State private var openMenus: Set<ObjectIdentifier> = []
  @State private var showsSizeAndTiming = false
  @State private var subtitlesChipFrame = CGRect.zero

  var body: some View {
    ViewThatFits(in: .horizontal) {
      row(iconOnly: false)
      row(iconOnly: true)
      if let upNext {
        VStack(alignment: .trailing, spacing: PutioVideoMetrics.chipGap) {
          PutioVideoUpNextAccessory(upNext: upNext, iconOnly: false)
          ViewThatFits(in: .horizontal) {
            chips(iconOnly: false)
            chips(iconOnly: true)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .coordinateSpace(.named(Self.coordinateSpace))
    .popover(
      isPresented: $showsSizeAndTiming,
      attachmentAnchor: .rect(.rect(subtitlesChipFrame)), arrowEdge: .bottom
    ) {
      PutioSubtitleSizeAndTimingPanel(transport: transport)
        .presentationCompactAdaptation(.sheet)
    }
    .onChange(of: openMenus.isEmpty && !showsSizeAndTiming) { _, closed in onMenu(!closed) }
  }

  private func row(iconOnly: Bool) -> some View {
    HStack(alignment: .bottom, spacing: PutioTheme.Spacing.space2) {
      chips(iconOnly: iconOnly)
        .layoutPriority(2)
      if let upNext {
        Spacer(minLength: PutioTheme.Spacing.space2)
        PutioVideoUpNextAccessory(upNext: upNext, iconOnly: iconOnly)
          .layoutPriority(1)
      }
    }
  }

  private static let coordinateSpace = "video.chips"

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
          enabled: transport.audioTracks.count > 1,
          sections: [
            PutioVideoChipSection(
              items: transport.audioTracks.map { track in
                .choice(
                  PutioVideoChipChoice(
                    title: track.title, detail: track.detail,
                    identifier: "video.audio.\(track.id)",
                    selected: transport.selectedAudio == track.id
                  ) { transport.selectAudio(track.id) })
              })
          ])
      }
      let subtitle = transport.selectedSubtitleTitle
      chip(
        icon: .closedCaptioning, title: subtitle, iconOnly: iconOnly,
        label: String(localized: "Subtitles: \(subtitle)"), identifier: "video.chip.subtitles",
        sections: subtitleSections
      )
      .onGeometryChange(for: CGRect.self) {
        $0.frame(in: .named(Self.coordinateSpace))
      } action: {
        subtitlesChipFrame = $0
      }
      let speed = transport.speed.title
      chip(
        icon: .gauge, title: speed, iconOnly: iconOnly,
        label: String(localized: "Playback speed \(speed)"), identifier: "video.chip.speed",
        sections: [
          PutioVideoChipSection(
            items: PutioAudioSpeed.allCases.map { option in
              .choice(
                PutioVideoChipChoice(
                  title: option.title, identifier: "video.speed.\(option.identifier)",
                  selected: transport.speed == option
                ) { transport.setSpeed(option) })
            })
        ])
    }
  }

  private var subtitleSections: [PutioVideoChipSection] {
    let menu = transport.subtitleMenu
    let off = PutioVideoChipItem.choice(
      PutioVideoChipChoice(
        title: String(localized: "Off"), identifier: "video.subtitles.off",
        selected: transport.selectedSubtitle == nil
      ) { transport.pickSubtitle(nil) })
    guard !menu.isEmpty else {
      return [
        PutioVideoChipSection(
          items: [
            off,
            .unavailable(
              title: String(localized: "No captions available"),
              identifier: "video.subtitles.none"),
          ])
      ]
    }
    let groups: [(String?, [PutioSubtitleMenu.Row])] = [
      (String(localized: "In this file"), menu.inFile),
      (String(localized: "Found by put.io"), menu.found),
      (nil, menu.unsourced),
    ]
    return [PutioVideoChipSection(items: [off])]
      + groups.filter { !$0.1.isEmpty }.map { title, rows in
        PutioVideoChipSection(title: title, items: rows.map(subtitleItem))
      }
      + [
        PutioVideoChipSection(items: [
          .action(
            PutioVideoChipAction(
              title: String(localized: "Size and timing"),
              detail: "\(transport.subtitleSize.title) · \(transport.subtitleTiming.text)",
              icon: .textAa, identifier: "video.subtitles.size-and-timing"
            ) { showsSizeAndTiming = true })
        ])
      ]
  }

  private func subtitleItem(_ row: PutioSubtitleMenu.Row) -> PutioVideoChipItem {
    let track = row.track
    return .choice(
      PutioVideoChipChoice(
        title: track.title, detail: row.source.map(Self.sourceTitle),
        identifier: "video.subtitles.\(track.id)",
        selected: transport.selectedSubtitle == track.id
      ) { transport.pickSubtitle(track.id) })
  }

  private static func sourceTitle(_ source: PutioSubtitleSource) -> String {
    switch source {
    case .embedded: String(localized: "Embedded")
    case .folder: String(localized: "This folder")
    case .openSubtitles: String(localized: "OpenSubtitles")
    }
  }

  private func chip(
    icon: PutioIcon, title: String, iconOnly: Bool, label: String, identifier: String,
    enabled: Bool = true, sections: [PutioVideoChipSection]
  ) -> some View {
    let enabled = enabled && transport.controlsEnabled
    return PutioVideoChipLabel(icon: icon, title: title, iconOnly: iconOnly)
      .opacity(enabled ? 1 : 0.5)
      .accessibilityHidden(true)
      .overlay {
        PutioVideoChipMenu(
          sections: sections, label: label, identifier: identifier,
          enabled: enabled, onChange: onChange,
          onPresentation: menuPresented)
      }
  }
}

struct PutioVideoChipLabel: View {
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

private struct PutioVideoChipAction: Equatable {
  let title: String
  let detail: String
  let icon: PutioIcon
  let identifier: String
  let perform: @MainActor () -> Void

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.title == rhs.title && lhs.detail == rhs.detail && lhs.icon == rhs.icon
      && lhs.identifier == rhs.identifier
  }
}

private enum PutioVideoChipItem: Equatable {
  case choice(PutioVideoChipChoice)
  case action(PutioVideoChipAction)
  case unavailable(title: String, identifier: String)

  var isChoice: Bool {
    if case .action = self { return false }
    return true
  }
}

private struct PutioVideoChipSection: Equatable {
  var title: String?
  let items: [PutioVideoChipItem]
}

private struct PutioVideoChipMenu: UIViewRepresentable {
  let sections: [PutioVideoChipSection]
  let label: String
  let identifier: String
  let enabled: Bool
  let onChange: () -> Void
  let onPresentation: (ObjectIdentifier, Bool) -> Void

  func makeUIView(context: Context) -> PutioVideoMenuButton {
    let button = PutioVideoMenuButton(type: .custom)
    button.showsMenuAsPrimaryAction = true
    button.preferredMenuElementOrder = .fixed
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
    guard button.sections != sections else { return }
    button.sections = sections
    let onChange = onChange
    let menus = sections.map { section in
      UIMenu(
        title: section.title ?? "",
        options: section.items.allSatisfy(\.isChoice)
          ? [.displayInline, .singleSelection] : .displayInline,
        children: section.items.map { Self.element($0, onChange: onChange) })
    }
    if let only = menus.first, menus.count == 1, sections[0].title == nil {
      button.menu = UIMenu(options: .singleSelection, children: only.children)
    } else {
      button.menu = UIMenu(children: menus)
    }
  }

  private static func element(
    _ item: PutioVideoChipItem, onChange: @escaping () -> Void
  ) -> UIMenuElement {
    switch item {
    case .choice(let choice):
      let action = UIAction(title: choice.title, state: choice.selected ? .on : .off) { _ in
        choice.select()
        onChange()
      }
      action.subtitle = choice.detail
      action.accessibilityIdentifier = choice.identifier
      return action
    case .action(let item):
      let action = UIAction(title: item.title, image: UIImage(putioIcon: item.icon)) { _ in
        item.perform()
        onChange()
      }
      action.subtitle = item.detail
      action.accessibilityIdentifier = item.identifier
      return action
    case .unavailable(let title, let identifier):
      let action = UIAction(title: title, attributes: .disabled) { _ in }
      action.accessibilityIdentifier = identifier
      return action
    }
  }

  static func dismantleUIView(_ button: PutioVideoMenuButton, coordinator: ()) {
    guard button.isPresentingMenu, let onPresentation = button.onPresentation else { return }
    let id = ObjectIdentifier(button)
    Task { @MainActor in onPresentation(id, false) }
  }
}

private final class PutioVideoMenuButton: UIButton {
  var onPresentation: ((ObjectIdentifier, Bool) -> Void)?
  var sections: [PutioVideoChipSection] = []
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
      PutioVideoCircleLabel(
        diameter: circled ? PutioVideoMetrics.skip : PutioVideoMetrics.close, circled: circled
      ) {
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

enum PutioVideoMetrics {
  static let close: CGFloat = 44
  static let airPlayIcon: CGFloat = 32
  static let chipHeight: CGFloat = 34
  static let chipPadding: CGFloat = 14
  static let chipGap: CGFloat = 12
  static let chipIcon = PutioMetricRole(value: PutioTheme.Typography.sizeBase, relativeTo: .caption)
  static let skip: CGFloat = 56
  static func playPause(_ circled: Bool) -> CGFloat { circled ? 72 : 56 }
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
