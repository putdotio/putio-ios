import Foundation
import Observation
import PutioCore
import SwiftUI

typealias PutioCastResolve =
  @MainActor @Sendable (PutioFileID, PutioCastPlaybackType) async throws -> PutioCastResolution
typealias PutioCastPlaybackTypeLoad = @MainActor @Sendable () async throws -> PutioCastPlaybackType
typealias PutioCastPlaybackTypeSave =
  @MainActor @Sendable (PutioCastPlaybackType) async throws -> Void

/// The receiver connection as the shell sees it. `unavailable` hides Cast
/// entry points: no receiver is on the network.
enum PutioCastConnection: Equatable, Sendable {
  case unavailable
  case disconnected
  case connecting(deviceName: String)
  case connected(deviceName: String)

  var deviceName: String? {
    switch self {
    case .connecting(let name), .connected(let name): name
    case .unavailable, .disconnected: nil
    }
  }

  var isConnected: Bool {
    if case .connected = self { return true }
    return false
  }
}

enum PutioCastPlayerState: Equatable, Sendable {
  case idle
  case loading
  case buffering
  case playing
  case paused
}

/// The receiver's last reported media status, mapped to app-owned values.
struct PutioCastMediaStatus: Equatable, Sendable {
  let fileID: PutioFileID
  let playerState: PutioCastPlayerState
  let positionSeconds: Double
  let durationSeconds: Double
  let activeSubtitleKey: String?
}

/// The Cast SDK behind a seam so the model's state machine is testable and
/// the harness can drive a deterministic receiver without a network.
@MainActor
protocol PutioCastControlling: AnyObject {
  var connection: PutioCastConnection { get }
  var onConnectionChanged: ((PutioCastConnection) -> Void)? { get set }
  var onMediaStatusChanged: ((PutioCastMediaStatus?) -> Void)? { get set }
  /// True when the controller renders Google's own Cast button; the harness
  /// controller renders a plain button that opens its stub picker.
  var providesSystemCastButton: Bool { get }
  func presentDevicePicker()
  func load(_ media: PutioCastMedia, subtitleKey: String?) async throws
  func play() async throws
  func pause() async throws
  func seek(toSeconds seconds: Double) async throws
  func setSubtitle(key: String?) async throws
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
  let title: String
  let message: String
  let canRetry: Bool

  static func resolving(_ error: Error) -> PutioCastFailure? {
    switch error as? PutioRuntimeError {
    case .authenticationRequired, .sessionExpired:
      return nil
    case .notFound:
      return Self(
        kind: .notFound, title: "File not found", message: "It may have been moved or deleted.",
        canRetry: false)
    case .rateLimited:
      return Self(
        kind: .rateLimited, title: "Could not cast",
        message: "put.io is receiving too many requests. Try again shortly.", canRetry: true)
    case .transient:
      return Self(
        kind: .transient, title: "Could not cast",
        message: "Check your connection and try again.", canRetry: true)
    case .invalidResponse:
      return Self(
        kind: .invalidResponse, title: "Could not cast",
        message: "put.io returned an invalid response. Try again.", canRetry: true)
    case .unknown, nil:
      return Self(
        kind: .unknown, title: "Could not cast",
        message: "Something went wrong while casting. Try again.", canRetry: true)
    }
  }

  static let receiver = Self(
    kind: .receiver, title: "Could not cast",
    message: "The Chromecast did not accept the video. Try again.", canRetry: true)
  static let conversion = Self(
    kind: .conversion, title: "Conversion failed",
    message: "put.io could not convert this video for Chromecast. Try again.", canRetry: true)
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

  var fileID: PutioFileID? {
    switch self {
    case .idle: nil
    case .resolving(let id), .conversionRequired(let id), .conversionQueued(let id),
      .converting(let id, _), .loading(let id), .failed(let id, _):
      id
    }
  }
}

/// Owns the Cast session as the user sees it: connection, the file being
/// cast, receiver status, subtitle selection, and throttled position reports.
/// Every await re-checks its generation so a session end, a stop, or a newer
/// cast request wins over a stale response.
@MainActor
@Observable
final class PutioCastModel {
  private(set) var connection: PutioCastConnection
  private(set) var activity: PutioCastActivity = .idle
  private(set) var media: PutioCastMedia?
  private(set) var status: PutioCastMediaStatus?
  private(set) var playbackType: PutioCastPlaybackType?
  private(set) var playbackTypeFailure: String?
  private(set) var isSavingPlaybackType = false
  /// Rendered position reports; the harness probe re-renders on it.
  private(set) var reportedPosition: (fileID: PutioFileID, seconds: Int)?
  private(set) var presentsControls = false

  @ObservationIgnored private let controller: PutioCastControlling
  @ObservationIgnored private let resolve: PutioCastResolve
  @ObservationIgnored private let loadPlaybackType: PutioCastPlaybackTypeLoad
  @ObservationIgnored private let savePlaybackType: PutioCastPlaybackTypeSave
  @ObservationIgnored private let startConversion: PutioVideoConversionStart
  @ObservationIgnored private let loadConversionStatus: PutioVideoConversionStatusLoad
  @ObservationIgnored private let reportPosition: PutioPlaybackPositionReport
  @ObservationIgnored private let positionReportInterval: Duration
  @ObservationIgnored private let conversionPollInterval: Duration
  @ObservationIgnored private var generation: UInt64 = 0
  @ObservationIgnored private var castTask: Task<Void, Never>?
  @ObservationIgnored private var reportTask: Task<Void, Never>?
  @ObservationIgnored private var lastReportedSeconds: Int?
  @ObservationIgnored private var pendingRoute: PutioVideoRoute?

  init(
    controller: PutioCastControlling,
    positionReportInterval: Duration = .seconds(15),
    conversionPollInterval: Duration = .seconds(3),
    resolve: @escaping PutioCastResolve,
    loadPlaybackType: @escaping PutioCastPlaybackTypeLoad,
    savePlaybackType: @escaping PutioCastPlaybackTypeSave,
    startConversion: @escaping PutioVideoConversionStart,
    loadConversionStatus: @escaping PutioVideoConversionStatusLoad,
    reportPosition: @escaping PutioPlaybackPositionReport
  ) {
    self.controller = controller
    self.connection = controller.connection
    self.positionReportInterval = positionReportInterval
    self.conversionPollInterval = conversionPollInterval
    self.resolve = resolve
    self.loadPlaybackType = loadPlaybackType
    self.savePlaybackType = savePlaybackType
    self.startConversion = startConversion
    self.loadConversionStatus = loadConversionStatus
    self.reportPosition = reportPosition
    controller.onConnectionChanged = { [weak self] connection in
      self?.connectionChanged(connection)
    }
    controller.onMediaStatusChanged = { [weak self] status in
      self?.statusChanged(status)
    }
  }

  var isConnected: Bool { connection.isConnected }

  #if DEBUG
    var harnessController: PutioHarnessCastController? {
      controller as? PutioHarnessCastController
    }
  #endif
  var providesSystemCastButton: Bool { controller.providesSystemCastButton }
  /// Google's button stays mounted before discovery: with discovery starting
  /// on the first tap, hiding it would leave no way to find a receiver. The
  /// stub button hides when its controller reports no devices.
  var showsCastButton: Bool { providesSystemCastButton || connection != .unavailable }

  /// A bar or sheet has something to show once a file is being prepared,
  /// is loaded on the receiver, or failed on the way there.
  var hasSession: Bool {
    isConnected && (media != nil || activity != .idle)
  }

  var currentTitle: String? {
    media?.title
  }

  var isPlaying: Bool {
    status?.playerState == .playing || status?.playerState == .buffering
  }

  // MARK: Session

  func presentDevicePicker() {
    controller.presentDevicePicker()
  }

  func showControls() {
    guard hasSession else { return }
    presentsControls = true
  }

  func hideControls() {
    presentsControls = false
  }

  func disconnect() {
    flushPositionReport()
    controller.endSession()
  }

  private func connectionChanged(_ connection: PutioCastConnection) {
    let wasConnected = self.connection.isConnected
    self.connection = connection
    if wasConnected, !connection.isConnected {
      flushPositionReport()
      clearSession()
    }
  }

  private func clearSession() {
    generation &+= 1
    castTask?.cancel()
    castTask = nil
    stopReporting()
    activity = .idle
    media = nil
    status = nil
    presentsControls = false
    pendingRoute = nil
  }

  // MARK: Casting

  /// Casts a video to the connected receiver. Conversion-gated files are
  /// converted first; the activity states mirror the local player's.
  func cast(_ route: PutioVideoRoute) {
    guard isConnected else { return }
    flushPositionReport()
    generation &+= 1
    let request = generation
    castTask?.cancel()
    stopReporting()
    pendingRoute = route
    media = nil
    status = nil
    activity = .resolving(route.id)
    presentsControls = true
    castTask = Task { @MainActor [weak self] in
      await self?.run(route, generation: request)
    }
  }

  func retry() {
    guard case .failed = activity, let pendingRoute else { return }
    cast(pendingRoute)
  }

  private func run(_ route: PutioVideoRoute, generation request: UInt64) async {
    do {
      let playbackType = try await currentPlaybackType()
      guard request == generation else { return }
      var resolution = try await resolve(route.id, playbackType)
      guard request == generation else { return }
      if case .conversionRequired = resolution {
        try await convert(route.id, generation: request)
        guard request == generation else { return }
        resolution = try await resolve(route.id, playbackType)
        guard request == generation else { return }
        guard case .ready = resolution else { throw PutioRuntimeError.invalidResponse }
      }
      guard case .ready(let media) = resolution else { return }
      activity = .loading(route.id)
      self.media = media
      try await controller.load(media, subtitleKey: media.defaultSubtitleKey)
      guard request == generation else { return }
      activity = .idle
      lastReportedSeconds = media.startFromSeconds
      startReporting()
    } catch {
      guard request == generation, !Task.isCancelled, !(error is CancellationError) else {
        return
      }
      media = nil
      if let castFailure = error as? PutioCastControllerError {
        activity = .failed(route.id, castFailure.failure)
      } else if let conversion = error as? PutioCastConversionError {
        guard let failure = PutioCastFailure.resolvingConversion(conversion.underlying) else {
          activity = .idle
          presentsControls = false
          return
        }
        activity = .failed(route.id, failure)
      } else if let failure = PutioCastFailure.resolving(error) {
        activity = .failed(route.id, failure)
      } else {
        // The session expired; the shell signs out and the bar goes with it.
        activity = .idle
        presentsControls = false
      }
    }
  }

  private func currentPlaybackType() async throws -> PutioCastPlaybackType {
    if let playbackType { return playbackType }
    let loaded = try await loadPlaybackType()
    if playbackType == nil { playbackType = loaded }
    return playbackType ?? loaded
  }

  private func convert(_ fileID: PutioFileID, generation request: UInt64) async throws {
    activity = .conversionRequired(fileID)
    do {
      try await startConversion(fileID)
    } catch {
      throw PutioCastConversionError(error)
    }
    guard request == generation else { return }
    activity = .conversionQueued(fileID)
    while true {
      try await Task.sleep(for: conversionPollInterval)
      guard request == generation else { return }
      let status: PutioVideoConversionStatus
      do {
        status = try await loadConversionStatus(fileID)
      } catch {
        throw PutioCastConversionError(error)
      }
      guard request == generation else { return }
      switch status {
      case .queued:
        activity = .conversionQueued(fileID)
      case .converting(let progress):
        activity = .converting(fileID, progress: progress)
      case .completed:
        return
      case .failed:
        throw PutioCastControllerError(failure: .conversion)
      }
    }
  }

  // MARK: Playback type

  func loadPlaybackTypeIfNeeded(force: Bool = false) async {
    guard force || playbackType == nil else { return }
    playbackTypeFailure = nil
    do {
      let loaded = try await loadPlaybackType()
      playbackType = loaded
    } catch {
      guard !(error is CancellationError) else { return }
      playbackTypeFailure = Self.preferenceMessage(for: error)
    }
  }

  /// Saves through the server; the local value flips only on acknowledgement
  /// so a failed save shows the authoritative type with a retryable message.
  func savePlaybackType(_ newValue: PutioCastPlaybackType) async {
    guard !isSavingPlaybackType, newValue != playbackType else { return }
    isSavingPlaybackType = true
    playbackTypeFailure = nil
    defer { isSavingPlaybackType = false }
    do {
      try await savePlaybackType(newValue)
      playbackType = newValue
    } catch {
      guard !(error is CancellationError) else { return }
      playbackTypeFailure = Self.preferenceMessage(for: error)
    }
  }

  private static func preferenceMessage(for error: Error) -> String? {
    switch error as? PutioRuntimeError {
    case .authenticationRequired, .sessionExpired: return nil
    case .transient: return "Check your connection and try again."
    case .rateLimited: return "put.io is receiving too many requests. Try again shortly."
    case .invalidResponse: return "put.io returned an invalid response. Try again."
    case .notFound, .unknown, nil: return "Could not save the Chromecast setting. Try again."
    }
  }

  // MARK: Controls

  func togglePlayback() {
    guard let status else { return }
    let request = generation
    Task { @MainActor [weak self] in
      guard let self else { return }
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

  func seek(toSeconds seconds: Double) {
    guard media != nil else { return }
    let request = generation
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        try await controller.seek(toSeconds: max(0, seconds))
      } catch {
        guard request == generation else { return }
        self.reportControlFailure(error)
      }
    }
  }

  func selectSubtitle(key: String?) {
    guard let media, key == nil || media.subtitles.contains(where: { $0.key == key }) else {
      return
    }
    let request = generation
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        try await controller.setSubtitle(key: key)
      } catch {
        guard request == generation else { return }
        self.reportControlFailure(error)
      }
    }
  }

  /// Stops receiver playback but keeps the device connected.
  func stopCasting() {
    flushPositionReport()
    let request = generation
    generation &+= 1
    castTask?.cancel()
    castTask = nil
    stopReporting()
    let hadMedia = media != nil
    media = nil
    status = nil
    activity = .idle
    presentsControls = false
    pendingRoute = nil
    guard hadMedia else { return }
    // A cast that starts while this stop is in flight supersedes it inside
    // the controller, so the stop cannot idle the newer media.
    Task { @MainActor [weak self] in
      guard let self, request &+ 1 == generation else { return }
      try? await controller.stop()
    }
  }

  private func reportControlFailure(_ error: Error) {
    guard let fileID = media?.id else { return }
    if let castFailure = error as? PutioCastControllerError {
      activity = .failed(fileID, castFailure.failure)
    } else {
      activity = .failed(fileID, .receiver)
    }
  }

  private func statusChanged(_ status: PutioCastMediaStatus?) {
    guard let media else {
      self.status = nil
      return
    }
    guard let status, status.fileID == media.id else {
      // The receiver moved on (another sender, or playback ended).
      if self.status != nil, status == nil || status?.playerState == .idle {
        flushPositionReport()
        stopReporting()
        self.status = nil
        self.media = nil
        activity = .idle
        presentsControls = false
      }
      return
    }
    if case .failed = activity { activity = .idle }
    if status.playerState == .idle {
      // Flush against the last playing/paused status; idle carries no
      // trusted position.
      flushPositionReport()
      stopReporting()
      self.status = nil
      self.media = nil
      presentsControls = false
      return
    }
    self.status = status
  }

  // MARK: Position reports

  private func startReporting() {
    stopReporting()
    let request = generation
    reportTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: self?.positionReportInterval ?? .seconds(15))
        guard let self, !Task.isCancelled, request == generation else { return }
        self.reportPositionIfNeeded()
      }
    }
  }

  private func stopReporting() {
    reportTask?.cancel()
    reportTask = nil
  }

  private func reportPositionIfNeeded() {
    guard let media, let status, status.playerState == .playing || status.playerState == .paused
    else { return }
    let seconds = Int(status.positionSeconds.rounded(.down))
    guard seconds > 0, seconds != lastReportedSeconds else { return }
    lastReportedSeconds = seconds
    reportedPosition = (media.id, seconds)
    let report = reportPosition
    // Not generation-guarded on purpose: the report names its own file and
    // second, so a session end or a newer cast never makes it wrong, and the
    // final flush must outlive the session that produced it.
    Task { @MainActor in
      try? await report(media.id, seconds)
    }
  }

  private func flushPositionReport() {
    reportPositionIfNeeded()
  }
}

/// A controller failure the model shows as-is instead of mapping.
struct PutioCastControllerError: Error {
  let failure: PutioCastFailure
}

/// Conversion errors keep their runtime mapping but the copy names conversion.
private struct PutioCastConversionError: Error {
  let underlying: Error
  init(_ underlying: Error) { self.underlying = underlying }
}

extension PutioCastFailure {
  fileprivate static func resolvingConversion(_ error: Error) -> PutioCastFailure? {
    guard let mapped = resolving(error) else { return nil }
    return PutioCastFailure(
      kind: mapped.kind, title: "Conversion failed", message: mapped.message,
      canRetry: mapped.canRetry)
  }
}

/// The receiver app identifier. It is a build setting because iOS scopes
/// Cast discovery to the `_<id>._googlecast._tcp` Bonjour service declared
/// in Info.plist, which cannot change at runtime.
enum PutioCastReceiver {
  static let fallbackAppID = "CC1AD845"

  /// Receiver IDs are eight uppercase hexadecimal characters; anything else
  /// (including an unexpanded build-setting placeholder) falls back.
  static func appID(bundle: Bundle = .main) -> String {
    let configured = bundle.object(forInfoDictionaryKey: "PUTIO_CHROMECAST_RECEIVER_APP_ID")
    let trimmed = (configured as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return isValid(trimmed) ? trimmed : fallbackAppID
  }

  static func isValid(_ candidate: String) -> Bool {
    candidate.count == 8
      && candidate.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isUppercase) }
  }
}
