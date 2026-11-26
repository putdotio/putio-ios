import Foundation
import Observation
import PutioCore
import SwiftUI
import UIKit

typealias PutioCastResolve = @MainActor @Sendable (PutioFileID) async throws -> PutioCastResolution

/// The receiver connection as the shell sees it. `unavailable` hides Cast
/// entry points: no receiver is on the network.
enum PutioCastConnection: Equatable, Sendable {
  case unavailable
  case localNetworkDenied
  case disconnected
  case connecting(deviceName: String)
  case connected(deviceName: String, audioOnly: Bool = false)

  var deviceName: String? {
    switch self {
    case .connecting(let name), .connected(let name, _): name
    case .unavailable, .localNetworkDenied, .disconnected: nil
    }
  }

  var isConnected: Bool {
    if case .connected = self { return true }
    return false
  }

  var playsVideo: Bool {
    if case .connected(_, audioOnly: false) = self { return true }
    return false
  }
}

enum PutioCastPlayerState: Equatable, Sendable {
  case idle
  case loading
  case buffering
  case playing
  case paused
  /// The receiver stopped the media on an error.
  case failed

  var waitActivity: PutioVideoPlayerActivity {
    switch self {
    case .playing: .playing
    case .paused: .paused
    case .idle, .loading, .buffering, .failed: .waiting
    }
  }
}

struct PutioCastAudioTrack: Equatable, Sendable {
  let id: Int
  let languageCode: String?
  let name: String?
}

/// The receiver's last reported media status, mapped to app-owned values.
struct PutioCastMediaStatus: Equatable, Sendable {
  let fileID: PutioFileID
  let playerState: PutioCastPlayerState
  let positionSeconds: Double
  let durationSeconds: Double
  var audioTracks: [PutioCastAudioTrack] = []
  var textTracks: [PutioCastTextTrack] = []
  var activeTrackIDs: [Int] = []
}

struct PutioCastTextTrack: Equatable, Sendable {
  let id: Int
  let languageCode: String?
  let name: String?
}

struct PutioCastDevice: Identifiable, Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    case tv
    case speaker
    case other
  }

  let id: String
  let name: String
  let model: String?
  let kind: Kind
  let audioOnly: Bool
  let isSelected: Bool
}

struct PutioCastDiscovery: Equatable, Sendable {
  var devices: [PutioCastDevice] = []
  var isSearching = false
}

/// The Cast SDK behind a seam so the model's state machine is testable and
/// the harness can drive a deterministic receiver without a network.
@MainActor
protocol PutioCastControlling: AnyObject {
  var connection: PutioCastConnection { get }
  var discovery: PutioCastDiscovery { get }
  var approximatePositionSeconds: Double? { get }
  var onConnectionChanged: ((PutioCastConnection) -> Void)? { get set }
  var onDiscoveryChanged: ((PutioCastDiscovery) -> Void)? { get set }
  var onMediaStatusChanged: ((PutioCastMediaStatus?) -> Void)? { get set }
  func startDiscovery()
  func connect(toDevice id: PutioCastDevice.ID)
  func load(_ media: PutioCastMedia, startSeconds: Int, autoplay: Bool, activeTrackIDs: [Int])
    async throws
  func setActiveTrackIDs(_ ids: [Int]) async throws
  func refreshStatus()
  func play() async throws
  func pause() async throws
  func seek(toSeconds seconds: Double) async throws
  func stop() async throws
  func endSession()
}

struct PutioCastFailure: Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    case notFound
    case rateLimited
    case transient
    case invalidResponse
    case conversion
    case receiver
    case unknown
  }

  let kind: Kind

  var canRetry: Bool { kind != .notFound }

  static func resolving(_ error: Error) -> PutioCastFailure? {
    if let failure = (error as? PutioCastControllerError)?.failure { return failure }
    switch error as? PutioRuntimeError {
    case .authenticationRequired, .sessionExpired: return nil
    case .notFound: return Self(kind: .notFound)
    case .rateLimited: return Self(kind: .rateLimited)
    case .transient: return Self(kind: .transient)
    case .invalidResponse: return Self(kind: .invalidResponse)
    case .unknown, nil: return Self(kind: .unknown)
    }
  }

  static let receiver = Self(kind: .receiver)
  static let conversion = Self(kind: .conversion)
}

/// What the shell is doing on the model's behalf for one file.
enum PutioCastActivity: Equatable, Sendable {
  case idle
  case resolving(PutioFileID)
  case conversionRequired(PutioFileID)
  case conversionQueued(PutioFileID)
  case converting(PutioFileID, progress: Double)
  case loading(PutioFileID)
  case failed(PutioFileID, PutioCastFailure)
}

/// Owns the Cast session as the user sees it: connection, the video being
/// cast, receiver status, and its position saves. Every await re-checks its
/// generation so a session end, a stop, or a newer cast request wins over a
/// stale response.
@MainActor
@Observable
final class PutioCastModel {
  private(set) var connection: PutioCastConnection
  private(set) var activity: PutioCastActivity = .idle
  private(set) var media: PutioCastMedia?
  private(set) var status: PutioCastMediaStatus?
  private(set) var route: PutioVideoRoute?
  private(set) var handback: PutioCastHandback?
  private(set) var reportedPosition: (fileID: PutioFileID, seconds: Int)?
  private(set) var discovery: PutioCastDiscovery
  private(set) var pendingTrackIDs: [Int]?
  var toast: PutioToast?
  var presentsPicker = false
  var presentsLocalNetworkAlert = false

  @ObservationIgnored private var connectionsMade = 0
  @ObservationIgnored private let controller: PutioCastControlling
  @ObservationIgnored private let resolve: PutioCastResolve
  @ObservationIgnored private let startConversion: PutioVideoConversionStart
  @ObservationIgnored private let loadConversionStatus: PutioVideoConversionStatusLoad
  @ObservationIgnored private let conversionPollInterval: Duration
  @ObservationIgnored private let schedulePositionSaves: PutioVideoPositionReporter.Scheduler
  @ObservationIgnored private let subtitleMemory: PutioSubtitleMemory?
  @ObservationIgnored private var foregroundObservation: NSObjectProtocol?
  @ObservationIgnored private var trackSwitch: UInt64 = 0
  @ObservationIgnored private var subtitleSwitch: UInt64 = 0
  @ObservationIgnored private var generation: UInt64 = 0
  @ObservationIgnored private var castTask: Task<Void, Never>?
  @ObservationIgnored private var saves: PutioCastPositionSaves?
  @ObservationIgnored private var requestedStart: Int?
  @ObservationIgnored private var requestedSubtitle: PutioRememberedSubtitle?
  @ObservationIgnored private var startsSubtitle = false
  @ObservationIgnored private var carriedAudioLanguage: String?
  @ObservationIgnored private var reporter: PutioVideoPositionReporter?
  @ObservationIgnored private var backgroundObservation: NSObjectProtocol?
  @ObservationIgnored private var statusReceivedAt: ContinuousClock.Instant?
  @ObservationIgnored private weak var audioReceiver: PutioCastAudioEngine?
  @ObservationIgnored private let wait: PutioVideoWaitModel

  init(
    controller: PutioCastControlling,
    conversionPollInterval: Duration = .seconds(3),
    resolve: @escaping PutioCastResolve,
    startConversion: @escaping PutioVideoConversionStart,
    loadConversionStatus: @escaping PutioVideoConversionStatusLoad,
    subtitleMemory: PutioSubtitleMemory? = nil,
    waitSleep: @escaping PutioVideoWaitSleep = { try await Task.sleep(for: $0) },
    schedulePositionSaves: @escaping PutioVideoPositionReporter.Scheduler = { interval, callback in
      PutioMonotonicPositionReportSchedule(interval: interval, callback: callback)
    }
  ) {
    self.controller = controller
    self.connection = controller.connection
    self.discovery = controller.discovery
    self.conversionPollInterval = conversionPollInterval
    self.resolve = resolve
    self.startConversion = startConversion
    self.loadConversionStatus = loadConversionStatus
    self.schedulePositionSaves = schedulePositionSaves
    self.subtitleMemory = subtitleMemory
    self.wait = PutioVideoWaitModel(sleep: waitSleep)
    controller.onConnectionChanged = { [weak self] connection in
      self?.connectionChanged(connection)
    }
    controller.onDiscoveryChanged = { [weak self] discovery in
      self?.discovery = discovery
    }
    controller.onMediaStatusChanged = { [weak self] status in
      self?.statusChanged(status)
    }
    backgroundObservation = NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.reporter?.savePosition() }
    }
    foregroundObservation = NotificationCenter.default.addObserver(
      forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.media != nil else { return }
        self.controller.refreshStatus()
      }
    }
  }

  isolated deinit {
    for observation in [backgroundObservation, foregroundObservation].compactMap({ $0 }) {
      NotificationCenter.default.removeObserver(observation)
    }
  }

  var isConnected: Bool { connection.isConnected }

  var castsVideo: Bool { connection.playsVideo }

  var connectionID: Int? { castsVideo ? connectionsMade : nil }

  #if DEBUG
    var harnessController: PutioHarnessCastController? {
      controller as? PutioHarnessCastController
    }
  #endif
  var showsCastButton: Bool { connection != .unavailable }

  var castingRoute: PutioVideoRoute? {
    guard isConnected, media != nil || activity != .idle else { return nil }
    return route
  }

  var hasSession: Bool { castingRoute != nil }

  var currentTitle: String? {
    media?.title ?? route?.title
  }

  var isPlaying: Bool {
    status?.playerState == .playing || status?.playerState == .buffering
  }

  var phase: PutioCastPhase? {
    guard hasSession else { return nil }
    switch activity {
    case .failed(_, let failure): return .failed(canRetry: failure.canRetry)
    case .resolving, .conversionRequired, .conversionQueued, .converting, .loading:
      return .loading
    case .idle:
      if wait.state == .stalled { return .failed(canRetry: true) }
      switch status?.playerState {
      case .playing, .paused, .buffering: return .playing
      case .loading, .idle, .failed, nil: return .loading
      }
    }
  }

  var positionSeconds: Double {
    guard let status else { return 0 }
    if let approximate = controller.approximatePositionSeconds { return approximate }
    guard status.playerState == .playing, let statusReceivedAt else {
      return status.positionSeconds
    }
    let elapsed = statusReceivedAt.duration(to: .now)
    let seconds =
      status.positionSeconds + Double(elapsed.components.seconds)
      + Double(elapsed.components.attoseconds) / 1e18
    return durationSeconds.map { min(seconds, $0) } ?? seconds
  }

  var durationSeconds: Double? {
    let reported = status?.durationSeconds ?? 0
    let duration = reported > 0 ? reported : media?.durationSeconds ?? 0
    return duration > 0 ? duration : nil
  }

  // MARK: Tracks

  var subtitleTracks: [PutioSubtitleTrack] {
    guard let media, let received = status?.textTracks, !received.isEmpty else { return [] }
    let renditions =
      media.subtitleRenditions.count == received.count ? media.subtitleRenditions : []
    return received.enumerated().map { index, track in
      let rendition = renditions.indices.contains(index) ? renditions[index] : nil
      let name = (rendition?.name ?? track.name)?.trimmingCharacters(in: .whitespaces)
      return PutioSubtitleTrack(
        id: track.id,
        title: name.flatMap { $0.isEmpty ? nil : $0 }
          ?? PutioTrackLabel.subtitleTitle(language: track.languageCode, name: nil, index: index),
        languageTag: track.languageCode ?? rendition?.languageTag,
        isDefault: rendition?.isDefault ?? false)
    }
  }

  var audioTracks: [PutioVideoTransport.Track] {
    guard let tracks = status?.audioTracks else { return [] }
    let titles = PutioTrackLabel.distinct(
      tracks.enumerated().map { index, track in
        PutioTrackLabel.audioTitle(language: track.languageCode, name: track.name, index: index)
      })
    return zip(tracks, titles).map { PutioVideoTransport.Track(id: $0.id, title: $1) }
  }

  private var activeTrackIDs: [Int] {
    pendingTrackIDs ?? status?.activeTrackIDs ?? []
  }

  var selectedAudio: Int? {
    let ids = Set(audioTracks.map(\.id))
    return activeTrackIDs.first(where: ids.contains)
  }

  var selectedSubtitle: Int? {
    let ids = Set(subtitleTracks.map(\.id))
    return activeTrackIDs.first(where: ids.contains)
  }

  var chipTracks: PutioVideoChipTracks {
    PutioVideoChipTracks(
      audioTracks: audioTracks, selectedAudio: selectedAudio,
      selectAudio: { [weak self] in self?.selectAudio($0) },
      subtitleMenu: PutioSubtitleMenu(tracks: subtitleTracks),
      selectedSubtitle: selectedSubtitle,
      pickSubtitle: { [weak self] in self?.pickSubtitle($0) },
      enabled: phase == .playing)
  }

  @discardableResult
  func pickSubtitle(_ id: Int?) -> Task<Void, Never>? {
    let tracks = subtitleTracks
    let track = id.flatMap { id in tracks.first { $0.id == id } }
    guard id == nil || track != nil, id != selectedSubtitle else { return nil }
    let textIDs = Set(tracks.map(\.id))
    let ids = activeTrackIDs.filter { !textIDs.contains($0) } + [id].compactMap { $0 }
    subtitleSwitch &+= 1
    let pick = subtitleSwitch
    return switchTracks(to: ids) { [weak self] succeeded, latest in
      guard let self else { return }
      if succeeded {
        guard pick == subtitleSwitch else { return }
        requestedSubtitle = nil
        subtitleMemory?.remember(track)
      } else if latest {
        if let track { subtitleMemory?.forget(track) }
        toast = PutioToast(
          String(localized: "Couldn’t load subtitles"), icon: .warning, width: .fit)
      }
    }
  }

  @discardableResult
  func selectAudio(_ id: Int) -> Task<Void, Never>? {
    let audioIDs = Set(audioTracks.map(\.id))
    guard audioIDs.contains(id), id != selectedAudio else { return nil }
    let ids = [id] + activeTrackIDs.filter { !audioIDs.contains($0) }
    return switchTracks(to: ids) { [weak self] succeeded, latest in
      guard !succeeded, latest else { return }
      self?.toast = PutioToast(
        String(localized: "Couldn’t switch audio track"), icon: .warning, width: .fit)
    }
  }

  private func switchTracks(
    to ids: [Int], finished: @escaping @MainActor (_ succeeded: Bool, _ latest: Bool) -> Void
  ) -> Task<Void, Never>? {
    guard media != nil, status != nil else { return nil }
    let request = generation
    trackSwitch &+= 1
    let attempt = trackSwitch
    pendingTrackIDs = ids
    return Task { @MainActor [weak self] in
      guard let self, request == generation else { return }
      let succeeded: Bool
      do {
        try await controller.setActiveTrackIDs(ids)
        succeeded = true
      } catch {
        succeeded = false
      }
      guard request == generation else { return }
      let latest = attempt == trackSwitch
      if latest { pendingTrackIDs = nil }
      finished(succeeded, latest)
    }
  }

  /// The receiver lists the manifest's subtitles only after it loads them.
  private func startSubtitle() {
    guard startsSubtitle else { return }
    let tracks = subtitleTracks
    guard !tracks.isEmpty else { return }
    startsSubtitle = false
    let policy = PutioSubtitleStartupPolicy(showsSubtitles: true, autoSelects: true)
    let remembered = requestedSubtitle ?? subtitleMemory?.remembered
    let track = policy.startingTrack(in: tracks, remembered: remembered)
    let knowsDefault = media?.subtitleRenditions.count == tracks.count
    guard track?.id != selectedSubtitle, track != nil || knowsDefault || remembered == .off
    else { return }
    let textIDs = Set(tracks.map(\.id))
    let ids = activeTrackIDs.filter { !textIDs.contains($0) } + [track?.id].compactMap { $0 }
    switchTracks(to: ids) { _, _ in }
  }

  private func carryOverAudio() {
    guard let language = carriedAudioLanguage, let status, !status.audioTracks.isEmpty else {
      return
    }
    carriedAudioLanguage = nil
    guard
      let track = status.audioTracks.first(where: {
        PutioSubtitleLanguage.matches($0.languageCode, language)
      })
    else { return }
    selectAudio(track.id)
  }

  // MARK: Session

  func startDiscovery() {
    controller.startDiscovery()
  }

  func castButtonTapped() {
    if connection == .localNetworkDenied {
      presentsLocalNetworkAlert = true
    } else {
      controller.startDiscovery()
      presentsPicker = true
    }
  }

  func choose(_ device: PutioCastDevice) {
    presentsPicker = false
    guard !device.isSelected else { return }
    controller.connect(toDevice: device.id)
  }

  func stopCastingFromPicker() {
    presentsPicker = false
    disconnect()
  }

  func disconnect() {
    handBack()
    clearSession()
    if connection != .unavailable { connection = .disconnected }
    controller.endSession()
  }

  func clearHandback() {
    handback = nil
  }

  private func connectionChanged(_ connection: PutioCastConnection) {
    let lostSession = self.connection.isConnected && !connection.isConnected
    if lostSession { handBack() }
    if connection.isConnected, !self.connection.isConnected { connectionsMade &+= 1 }
    self.connection = connection
    if connection == .unavailable || connection == .localNetworkDenied { presentsPicker = false }
    if lostSession { clearSession() }
  }

  private func handBack() {
    guard let route, castingRoute != nil else { return }
    let seconds = receiverPosition()
    reporter?.stop()
    handback = PutioCastHandback(route: route, seconds: seconds)
  }

  private func clearSession() {
    generation &+= 1
    castTask?.cancel()
    castTask = nil
    reporter?.cancel()
    reporter = nil
    saves = nil
    activity = .idle
    media = nil
    status = nil
    route = nil
    requestedSubtitle = nil
    carriedAudioLanguage = nil
    pendingTrackIDs = nil
    startsSubtitle = false
    toast = nil
    wait.restart()
  }

  // MARK: Casting

  func makeAudioReceiver(resolve: @escaping PutioCastAudioResolve) -> PutioCastAudioEngine {
    let receiver = PutioCastAudioEngine(controller: controller, resolve: resolve)
    audioReceiver = receiver
    return receiver
  }

  func cast(
    _ route: PutioVideoRoute, saves: PutioCastPositionSaves, startingAt startSeconds: Int? = nil,
    tracks: PutioVideoTrackChoice? = nil
  ) {
    guard castsVideo else { return }
    audioReceiver = nil
    reporter?.stop()
    reporter = nil
    generation &+= 1
    let request = generation
    castTask?.cancel()
    self.route = route
    self.saves = saves
    requestedStart = startSeconds
    requestedSubtitle = tracks?.subtitle
    carriedAudioLanguage = tracks?.audioLanguage
    handback = nil
    media = nil
    status = nil
    pendingTrackIDs = nil
    startsSubtitle = false
    toast = nil
    wait.restart()
    activity = .resolving(route.id)
    castTask = Task { @MainActor [weak self] in
      await Task.yield()
      await saves.pipeline.waitForPendingReports(fileID: route.id)
      await self?.run(route, startingAt: startSeconds, generation: request)
    }
  }

  func retry() {
    guard case .failed = phase, let route, let saves else { return }
    let start = wait.state == .stalled ? receiverPosition() : requestedStart
    let audio =
      carriedAudioLanguage
      ?? selectedAudio.flatMap { id in
        status?.audioTracks.first { $0.id == id }?.languageCode
      }
    cast(
      route, saves: saves, startingAt: start,
      tracks: PutioVideoTrackChoice(audioLanguage: audio, subtitle: requestedSubtitle))
  }

  private func run(
    _ route: PutioVideoRoute, startingAt startSeconds: Int?, generation request: UInt64
  ) async {
    guard request == generation else { return }
    do {
      var resolution = try await resolve(route.id)
      guard request == generation else { return }
      if case .conversionRequired = resolution {
        try await convert(route.id, generation: request)
        guard request == generation else { return }
        resolution = try await resolve(route.id)
        guard request == generation else { return }
        guard case .ready = resolution else { throw PutioRuntimeError.invalidResponse }
      }
      guard case .ready(let media) = resolution else { return }
      activity = .loading(route.id)
      self.media = media
      startsSubtitle = true
      try await controller.load(
        media, startSeconds: startSeconds ?? media.startFromSeconds, autoplay: true,
        activeTrackIDs: [])
      guard request == generation else { return }
      requestedStart = nil
      activity = .idle
      armStallDetection()
      startSaving(media)
    } catch {
      guard request == generation, !Task.isCancelled, !(error is CancellationError) else {
        return
      }
      media = nil
      if let failure = PutioCastFailure.resolving(error) {
        activity = .failed(route.id, failure)
      } else {
        activity = .idle
      }
    }
  }

  private func convert(_ fileID: PutioFileID, generation request: UInt64) async throws {
    activity = .conversionRequired(fileID)
    try await startConversion(fileID)
    guard request == generation else { return }
    activity = .conversionQueued(fileID)
    while true {
      try await Task.sleep(for: conversionPollInterval)
      guard request == generation else { return }
      let status = try await loadConversionStatus(fileID)
      guard request == generation else { return }
      switch status {
      case .queued:
        activity = .conversionQueued(fileID)
      case .converting(let progress):
        activity = .converting(fileID, progress: progress)
      case .completed:
        return
      case .failed, .unavailable:
        throw PutioCastControllerError(failure: .conversion)
      }
    }
  }

  // MARK: Controls

  @discardableResult
  func togglePlayback() -> Task<Void, Never>? {
    guard let status else { return nil }
    let request = generation
    return Task { @MainActor [weak self] in
      guard let self, request == generation else { return }
      do {
        if status.playerState == .playing || status.playerState == .buffering {
          try await controller.pause()
        } else {
          try await controller.play()
        }
      } catch {
        guard request == generation else { return }
        self.reportControlFailure(error)
      }
    }
  }

  @discardableResult
  func skip(by seconds: Double) -> Task<Void, Never>? {
    seek(toSeconds: positionSeconds + seconds)
  }

  @discardableResult
  func seek(toSeconds seconds: Double) -> Task<Void, Never>? {
    guard media != nil, status != nil else { return nil }
    let target = durationSeconds.map { min(max(0, seconds), $0) } ?? max(0, seconds)
    let request = generation
    return Task { @MainActor [weak self] in
      guard let self, request == generation else { return }
      do {
        try await controller.seek(toSeconds: target)
        guard request == generation else { return }
        reporter?.savePosition()
      } catch {
        guard request == generation else { return }
        self.reportControlFailure(error)
      }
    }
  }

  func stopCasting() {
    let hadMedia = media != nil
    handBack()
    clearSession()
    let request = generation
    guard hadMedia else { return }
    // A cast that starts while this stop is in flight supersedes it inside
    // the controller, so the stop cannot idle the newer media.
    Task { @MainActor [weak self] in
      guard let self, request == generation else { return }
      try? await controller.stop()
    }
  }

  private func reportControlFailure(_ error: Error) {
    guard let fileID = media?.id else { return }
    activity = .failed(fileID, (error as? PutioCastControllerError)?.failure ?? .receiver)
  }

  private func statusChanged(_ status: PutioCastMediaStatus?) {
    guard let media else {
      self.status = nil
      audioReceiver?.receive(status)
      return
    }
    guard let status, status.fileID == media.id else {
      // The receiver moved on (another sender, or playback ended).
      if self.status != nil,
        status == nil || status?.playerState == .idle || status?.playerState == .failed
      {
        endOnReceiver()
      }
      return
    }
    if status.playerState == .failed {
      receiverFailed(media.id)
      return
    }
    if status.playerState == .idle {
      endOnReceiver()
      return
    }
    if case .failed = activity { activity = .idle }
    let wasPlaying = isPlaying
    self.status = status
    statusReceivedAt = .now
    wait.activityChanged(status.playerState.waitActivity)
    if wasPlaying, status.playerState == .paused { reporter?.savePosition() }
    startSubtitle()
    carryOverAudio()
  }

  /// The receiver gave up on this file, as Android shows it: the failed
  /// layout stays, and Try again reloads from the last position it played.
  private func receiverFailed(_ fileID: PutioFileID) {
    if case .failed = activity { return }
    requestedStart = receiverPosition()
    reporter?.stop()
    reporter = nil
    activity = .failed(fileID, .receiver)
  }

  private func armStallDetection() {
    wait.activityChanged(.playing)
    if let status { wait.activityChanged(status.playerState.waitActivity) }
  }

  private func endOnReceiver() {
    if let status, let reporter {
      if PutioVideoPositionReporter.isAtEnd(
        positionSeconds: max(status.positionSeconds, positionSeconds),
        durationSeconds: durationSeconds ?? 0)
      {
        _ = reporter.playbackEnded()
        reporter.cancel()
      } else {
        reporter.stop()
      }
    }
    clearSession()
  }

  private func startSaving(_ media: PutioCastMedia) {
    guard let saves else { return }
    let report = saves.report
    let reporter = PutioVideoPositionReporter(
      fileID: media.id,
      remembersPosition: saves.remembersPosition,
      pipeline: saves.pipeline,
      report: { [weak self] fileID, seconds in
        try await report(fileID, seconds)
        self?.reportedPosition = (fileID, seconds)
      },
      currentPosition: { [weak self] in self?.receiverPosition() },
      savedPosition: media.startFromSeconds,
      endOfPlayback: .keepsPosition,
      schedule: schedulePositionSaves
    )
    self.reporter = reporter
    reporter.positionEstablished()
    reporter.ready()
  }

  private func receiverPosition() -> Int? {
    guard let status, status.playerState != .idle, status.playerState != .loading else {
      return nil
    }
    return PutioVideoPositionReporter.normalizedPosition(seconds: positionSeconds)
  }
}

enum PutioCastPhase: Equatable {
  case loading
  case playing
  case failed(canRetry: Bool)
}

struct PutioCastPositionSaves {
  let remembersPosition: Bool
  let pipeline: PutioPlaybackPositionPipeline
  let report: PutioPlaybackPositionReport
}

struct PutioCastHandback: Equatable {
  let route: PutioVideoRoute
  let seconds: Int?
}

/// A controller failure the model shows as-is instead of mapping.
struct PutioCastControllerError: Error {
  let failure: PutioCastFailure
}

/// The receiver app identifier. It is a build setting because iOS scopes
/// Cast discovery to the `_<id>._googlecast._tcp` Bonjour service declared
/// in Info.plist, which cannot change at runtime.
enum PutioCastReceiver {
  static let fallbackAppID = "CC1AD845"
  static let putioFallbackAppID = "E3A4ADFA"
  private static let choiceKey = "cast.usesPutioReceiver"

  /// Receiver IDs are eight uppercase hexadecimal characters; anything else
  /// (including an unexpanded build-setting placeholder) falls back.
  static func appID(bundle: Bundle = .main) -> String {
    configuredID(bundle: bundle, key: "PUTIO_CHROMECAST_RECEIVER_APP_ID") ?? fallbackAppID
  }

  static func putioAppID(bundle: Bundle = .main) -> String {
    configuredID(bundle: bundle, key: "PUTIO_CAST_RECEIVER_APP_ID") ?? putioFallbackAppID
  }

  /// The account's beta switch picks the receiver. The Cast context is set
  /// once per process, so the app remembers the switch for its next launch.
  static func appID(usesPutioReceiver: Bool, bundle: Bundle = .main) -> String {
    usesPutioReceiver ? putioAppID(bundle: bundle) : appID(bundle: bundle)
  }

  static func rememberedChoice(in defaults: UserDefaults = .standard) -> Bool {
    defaults.bool(forKey: choiceKey)
  }

  static func remember(usesPutioReceiver: Bool, in defaults: UserDefaults = .standard) {
    defaults.set(usesPutioReceiver, forKey: choiceKey)
  }

  private static func configuredID(bundle: Bundle, key: String) -> String? {
    let configured = bundle.object(forInfoDictionaryKey: key)
    let trimmed = (configured as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return isValid(trimmed) ? trimmed : nil
  }

  static func isValid(_ candidate: String) -> Bool {
    candidate.count == 8
      && candidate.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isUppercase) }
  }
}
