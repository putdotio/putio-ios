import AVFoundation
import AVKit
import Observation
import PutioCore
import SwiftUI

typealias PutioPlaybackResolve =
  @MainActor @Sendable (PutioFileID) async throws -> PutioPlaybackResolution
typealias PutioPlaybackPositionReport =
  @MainActor @Sendable (PutioFileID, Int) async throws -> Void

enum PutioVideoPlaybackState: Equatable {
  case loading
  case ready(PutioPlaybackSource)
  case conversionRequired
  case failed(PutioVideoPlaybackFailure)
}

struct PutioVideoPlaybackFailure: Equatable {
  enum Kind: Equatable {
    case notFound
    case rateLimited
    case transient
    case invalidResponse
    case playback
    case unknown
  }

  let kind: Kind
  let title: String
  let message: String

  static func resolving(_ error: Error) -> PutioVideoPlaybackFailure? {
    switch error as? PutioRuntimeError {
    case .authenticationRequired, .sessionExpired:
      return nil
    case .notFound:
      return PutioVideoPlaybackFailure(
        kind: .notFound,
        title: "Video not found",
        message: "It may have been moved or deleted."
      )
    case .rateLimited:
      return PutioVideoPlaybackFailure(
        kind: .rateLimited,
        title: "Could not open video",
        message: "put.io is receiving too many requests. Try again shortly."
      )
    case .transient:
      return PutioVideoPlaybackFailure(
        kind: .transient,
        title: "Could not open video",
        message: "Check your connection and try again."
      )
    case .invalidResponse:
      return PutioVideoPlaybackFailure(
        kind: .invalidResponse,
        title: "Could not open video",
        message: "put.io returned an invalid response. Try again."
      )
    case .unknown, nil:
      return PutioVideoPlaybackFailure(
        kind: .unknown,
        title: "Could not open video",
        message: "put.io could not prepare this video. Try again."
      )
    }
  }

  static let playback = PutioVideoPlaybackFailure(
    kind: .playback,
    title: "Could not play video",
    message: "The video could not be played. Try again."
  )
}

@MainActor
@Observable
final class PutioVideoPlaybackModel {
  private(set) var state: PutioVideoPlaybackState = .loading

  @ObservationIgnored private let fileID: PutioFileID
  @ObservationIgnored private let resolve: PutioPlaybackResolve
  @ObservationIgnored private var generation: UInt64 = 0
  @ObservationIgnored private var attemptedLoad = false

  init(fileID: PutioFileID, resolve: @escaping PutioPlaybackResolve) {
    self.fileID = fileID
    self.resolve = resolve
  }

  func loadIfNeeded() async {
    guard !attemptedLoad else { return }
    attemptedLoad = true
    await resolveSource()
  }

  func retry() async {
    attemptedLoad = true
    await resolveSource()
  }

  func playerFailed() {
    guard case .ready = state else { return }
    generation &+= 1
    state = .failed(.playback)
  }

  private func resolveSource() async {
    generation &+= 1
    let requestGeneration = generation
    state = .loading

    do {
      try Task.checkCancellation()
      let resolution = try await resolve(fileID)
      try Task.checkCancellation()
      guard requestGeneration == generation else { return }

      switch resolution {
      case .ready(let source):
        state = .ready(source)
      case .conversionRequired:
        state = .conversionRequired
      }
    } catch {
      guard requestGeneration == generation else { return }
      if Task.isCancelled {
        attemptedLoad = false
        return
      }
      guard let failure = PutioVideoPlaybackFailure.resolving(error) else {
        attemptedLoad = false
        return
      }
      state = .failed(failure)
    }
  }
}

@MainActor
final class PutioPlaybackPositionPipeline {
  private struct PendingReport {
    let sequence: UInt64
    let task: Task<Void, Never>
  }

  private var pendingReports: [PutioFileID: PendingReport] = [:]
  private var nextSequence: UInt64 = 0

  func enqueue(
    fileID: PutioFileID,
    position: Int,
    report: @escaping PutioPlaybackPositionReport
  ) {
    nextSequence &+= 1
    let sequence = nextSequence
    let previousReport = pendingReports[fileID]?.task
    let task = Task { @MainActor [weak self] in
      await previousReport?.value
      try? await report(fileID, position)
      guard self?.pendingReports[fileID]?.sequence == sequence else { return }
      self?.pendingReports[fileID] = nil
    }
    pendingReports[fileID] = PendingReport(sequence: sequence, task: task)
  }

  func waitForPendingReports(fileID: PutioFileID) async {
    await pendingReports[fileID]?.task.value
  }
}

@MainActor
struct PutioVideoPlaybackView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var model: PutioVideoPlaybackModel
  @State private var retrySequence: UInt64 = 0
  @State private var playerIsReady = false
  private let fileID: PutioFileID
  private let remembersPlaybackPosition: Bool
  private let reportsPlayerFailures: Bool
  private let showsHarnessReadiness: Bool
  private let positionPipeline: PutioPlaybackPositionPipeline
  private let reportPosition: PutioPlaybackPositionReport

  init(
    route: PutioFileRoute,
    remembersPlaybackPosition: Bool = true,
    reportsPlayerFailures: Bool = true,
    showsHarnessReadiness: Bool = false,
    positionPipeline: PutioPlaybackPositionPipeline,
    reportPosition: @escaping PutioPlaybackPositionReport = { _, _ in },
    resolve: @escaping PutioPlaybackResolve
  ) {
    self.fileID = route.id
    self.remembersPlaybackPosition = remembersPlaybackPosition
    self.reportsPlayerFailures = reportsPlayerFailures
    self.showsHarnessReadiness = showsHarnessReadiness
    self.positionPipeline = positionPipeline
    self.reportPosition = reportPosition
    _model = State(
      initialValue: PutioVideoPlaybackModel(fileID: route.id) { fileID in
        await positionPipeline.waitForPendingReports(fileID: fileID)
        return try await resolve(fileID)
      }
    )
  }

  var body: some View {
    ZStack(alignment: .topTrailing) {
      content
      PutioButton("Done", tier: .primary) {
        dismiss()
      }
      .padding(PutioTheme.Spacing.space4)
      .accessibilityIdentifier("video.done")
    }
    .background(Color.black)
    .task {
      await model.loadIfNeeded()
    }
    .task(id: retrySequence) {
      guard retrySequence > 0 else { return }
      playerIsReady = false
      await model.retry()
    }
    .overlay {
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
        }
      }
    }
  }

  @ViewBuilder
  private var content: some View {
    switch model.state {
    case .loading:
      PutioLoadingStateView(title: "Preparing video")
        .accessibilityIdentifier("video.loading")
    case .ready(let source):
      PutioSystemVideoPlayer(
        fileID: fileID,
        source: source,
        remembersPlaybackPosition: remembersPlaybackPosition,
        positionPipeline: positionPipeline,
        reportPosition: reportPosition,
        onReady: { playerIsReady = true }
      ) {
        playerIsReady = false
        if reportsPlayerFailures {
          model.playerFailed()
        }
      }
      .ignoresSafeArea()
    case .conversionRequired:
      PutioErrorStateView(
        title: "Video needs conversion",
        message: "Convert this video before playing it. Conversion support is coming next."
      )
      .accessibilityIdentifier("video.conversion-required")
    case .failed(let failure):
      PutioErrorStateView(
        title: failure.title,
        message: failure.message,
        retryTitle: "Try again"
      ) {
        retrySequence &+= 1
      }
      .accessibilityIdentifier("video.error")
    }
  }
}

private struct PutioSystemVideoPlayer: UIViewControllerRepresentable {
  let fileID: PutioFileID
  let source: PutioPlaybackSource
  let remembersPlaybackPosition: Bool
  let positionPipeline: PutioPlaybackPositionPipeline
  let reportPosition: PutioPlaybackPositionReport
  let onReady: @MainActor @Sendable () -> Void
  let onFailure: @MainActor @Sendable () -> Void

  func makeCoordinator() -> PutioSystemVideoPlayerCoordinator {
    PutioSystemVideoPlayerCoordinator(positionPipeline: positionPipeline)
  }

  func makeUIViewController(context: Context) -> AVPlayerViewController {
    let controller = AVPlayerViewController()
    controller.allowsPictureInPicturePlayback = true
    controller.entersFullScreenWhenPlaybackBegins = false
    controller.exitsFullScreenWhenPlaybackEnds = false
    if context.coordinator.start(
      fileID: fileID,
      source: source,
      remembersPlaybackPosition: remembersPlaybackPosition,
      reportPosition: { try await reportPosition($0, $1) },
      in: controller,
      onReady: onReady,
      onFailure: onFailure
    ) {
      controller.view.accessibilityIdentifier = "video.system-player"
    }
    return controller
  }

  func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}

  static func dismantleUIViewController(
    _ controller: AVPlayerViewController,
    coordinator: PutioSystemVideoPlayerCoordinator
  ) {
    coordinator.stop(controller: controller)
  }
}

@MainActor
protocol PutioVideoPlayerDriving: AnyObject {
  var player: AVPlayer { get }
  var currentTime: CMTime { get }

  func play()
  func seek(to time: CMTime, completion: @escaping @Sendable (Bool) -> Void)
  func observeTime(
    every interval: CMTime,
    using callback: @escaping @MainActor @Sendable (CMTime) -> Void
  ) -> any PutioPlayerTimeObservation
  func stop()
}

@MainActor
protocol PutioPlayerTimeObservation: AnyObject {
  func invalidate()
}

@MainActor
private final class PutioSystemPlayerTimeObservation: PutioPlayerTimeObservation {
  private weak var player: AVPlayer?
  private var token: Any?

  init(player: AVPlayer, token: Any) {
    self.player = player
    self.token = token
  }

  func invalidate() {
    guard let token else { return }
    player?.removeTimeObserver(token)
    self.token = nil
  }

  deinit {
    MainActor.assumeIsolated {
      invalidate()
    }
  }
}

@MainActor
private final class PutioSystemVideoPlayerDriver: PutioVideoPlayerDriving {
  let player: AVPlayer

  var currentTime: CMTime {
    player.currentTime()
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

  func observeTime(
    every interval: CMTime,
    using callback: @escaping @MainActor @Sendable (CMTime) -> Void
  ) -> any PutioPlayerTimeObservation {
    let token = player.addPeriodicTimeObserver(
      forInterval: interval,
      queue: .main
    ) { time in
      Task { @MainActor in
        callback(time)
      }
    }
    return PutioSystemPlayerTimeObservation(player: player, token: token)
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
final class PutioSystemVideoPlayerCoordinator {
  typealias DriverFactory = @MainActor (AVPlayerItem) -> any PutioVideoPlayerDriving
  typealias PositionReportNow = @MainActor () -> ContinuousClock.Instant
  typealias StatusObserverFactory =
    @MainActor (
      AVPlayerItem,
      @escaping @Sendable (AVPlayerItem.Status) -> Void
    ) -> any PutioPlayerItemStatusObservation

  private let makeDriver: DriverFactory
  private let observeItemStatus: StatusObserverFactory
  private let audioSession: any PutioPlaybackAudioSessioning
  private let notificationCenter: NotificationCenter
  private let positionPipeline: PutioPlaybackPositionPipeline
  private let positionReportNow: PositionReportNow
  private var statusObservation: (any PutioPlayerItemStatusObservation)?
  private var timeObservation: (any PutioPlayerTimeObservation)?
  private var failedToEndObservation: NSObjectProtocol?
  private var playedToEndObservation: NSObjectProtocol?
  private var driver: (any PutioVideoPlayerDriving)?
  private var onReady: (@MainActor () -> Void)?
  private var onFailure: (@MainActor () -> Void)?
  private var generation: UInt64 = 0
  private var readyReported = false
  private var failureReported = false
  private var remembersPlaybackPosition = false
  private var fileID: PutioFileID?
  private var reportPosition: PutioPlaybackPositionReport?
  private var finalPositionEnqueued = false
  private var positionIsEstablished = false
  private var lastPeriodicPositionReportAt: ContinuousClock.Instant?
  private var audioSessionIsActive = false

  convenience init() {
    self.init(
      makeDriver: { PutioSystemVideoPlayerDriver(item: $0) },
      audioSession: PutioPlaybackAudioSession(),
      notificationCenter: .default,
      positionPipeline: PutioPlaybackPositionPipeline()
    )
  }

  convenience init(positionPipeline: PutioPlaybackPositionPipeline) {
    self.init(
      makeDriver: { PutioSystemVideoPlayerDriver(item: $0) },
      audioSession: PutioPlaybackAudioSession(),
      notificationCenter: .default,
      positionPipeline: positionPipeline
    )
  }

  init(
    makeDriver: @escaping DriverFactory,
    observeItemStatus: @escaping StatusObserverFactory = { item, statusChanged in
      item.observe(\.status, options: [.initial, .new]) { item, _ in
        statusChanged(item.status)
      }
    },
    audioSession: any PutioPlaybackAudioSessioning,
    notificationCenter: NotificationCenter,
    positionPipeline: PutioPlaybackPositionPipeline,
    positionReportNow: @escaping PositionReportNow = { ContinuousClock.now }
  ) {
    self.makeDriver = makeDriver
    self.observeItemStatus = observeItemStatus
    self.audioSession = audioSession
    self.notificationCenter = notificationCenter
    self.positionPipeline = positionPipeline
    self.positionReportNow = positionReportNow
  }

  @discardableResult
  func start(
    fileID: PutioFileID = .root,
    source: PutioPlaybackSource,
    remembersPlaybackPosition: Bool = true,
    reportPosition: @escaping PutioPlaybackPositionReport = { _, _ in },
    in controller: AVPlayerViewController,
    onReady: @escaping @MainActor () -> Void = {},
    onFailure: @escaping @MainActor () -> Void
  ) -> Bool {
    generation &+= 1
    let playbackGeneration = generation
    readyReported = false
    failureReported = false
    finalPositionEnqueued = false
    positionIsEstablished = false
    lastPeriodicPositionReportAt = nil
    self.fileID = fileID
    self.remembersPlaybackPosition = remembersPlaybackPosition
    self.reportPosition = reportPosition
    self.onReady = onReady
    self.onFailure = onFailure

    let item = AVPlayerItem(url: source.url)
    statusObservation = observeItemStatus(item) { [weak self] status in
      Task { @MainActor [weak self] in
        switch status {
        case .readyToPlay:
          self?.reportReady(generation: playbackGeneration)
        case .failed:
          self?.reportFailure(generation: playbackGeneration)
        case .unknown:
          break
        @unknown default:
          break
        }
      }
    }
    failedToEndObservation = notificationCenter.addObserver(
      forName: AVPlayerItem.failedToPlayToEndTimeNotification,
      object: item,
      queue: nil
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.reportFailure(generation: playbackGeneration)
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

    let driver = makeDriver(item)
    self.driver = driver
    controller.player = driver.player

    do {
      try audioSession.activate()
      audioSessionIsActive = true
    } catch {
      Task { @MainActor [weak self] in
        self?.reportFailure(generation: playbackGeneration)
      }
      return false
    }

    guard remembersPlaybackPosition, source.startFromSeconds > 0 else {
      positionIsEstablished = true
      driver.play()
      return true
    }

    let startTime = CMTime(
      seconds: Double(source.startFromSeconds),
      preferredTimescale: 600
    )
    driver.seek(to: startTime) { [weak self] finished in
      Task { @MainActor [weak self] in
        guard let self, generation == playbackGeneration, self.driver === driver else { return }
        guard !failureReported else { return }
        guard finished else {
          reportFailure(generation: playbackGeneration)
          return
        }
        positionIsEstablished = true
        startPositionObservation(generation: playbackGeneration)
        driver.play()
      }
    }
    return true
  }

  func stop(controller: AVPlayerViewController) {
    let stoppedDriver = driver
    enqueueFinalPositionIfNeeded(from: stoppedDriver)
    generation &+= 1
    statusObservation?.invalidate()
    statusObservation = nil
    timeObservation?.invalidate()
    timeObservation = nil
    if let failedToEndObservation {
      notificationCenter.removeObserver(failedToEndObservation)
      self.failedToEndObservation = nil
    }
    if let playedToEndObservation {
      notificationCenter.removeObserver(playedToEndObservation)
      self.playedToEndObservation = nil
    }
    onReady = nil
    onFailure = nil
    stoppedDriver?.stop()
    driver = nil
    controller.player = nil
    if audioSessionIsActive {
      audioSession.deactivate()
      audioSessionIsActive = false
    }
  }

  func waitForPendingPositionReports() async {
    guard let fileID else { return }
    await positionPipeline.waitForPendingReports(fileID: fileID)
  }

  private func reportFailure(generation playbackGeneration: UInt64) {
    guard generation == playbackGeneration, !failureReported else { return }
    failureReported = true
    onFailure?()
  }

  private func reportReady(generation playbackGeneration: UInt64) {
    guard generation == playbackGeneration, !readyReported, !failureReported else { return }
    readyReported = true
    startPositionObservation(generation: playbackGeneration)
    onReady?()
  }

  private func reportPlaybackEnded(generation playbackGeneration: UInt64) {
    guard
      generation == playbackGeneration,
      remembersPlaybackPosition,
      readyReported,
      positionIsEstablished,
      !failureReported,
      !finalPositionEnqueued
    else { return }
    finalPositionEnqueued = true
    enqueuePosition(0)
  }

  private func startPositionObservation(generation playbackGeneration: UInt64) {
    guard
      remembersPlaybackPosition,
      positionIsEstablished,
      timeObservation == nil,
      let driver
    else { return }
    let interval = CMTime(seconds: 15, preferredTimescale: 600)
    lastPeriodicPositionReportAt = positionReportNow()
    timeObservation = driver.observeTime(every: interval) { [weak self, weak driver] time in
      guard
        let self,
        let driver,
        generation == playbackGeneration,
        self.driver === driver,
        readyReported,
        !finalPositionEnqueued,
        let position = Self.normalizedPosition(time),
        shouldReportPeriodicPosition()
      else { return }
      enqueuePosition(position)
    }
  }

  private func shouldReportPeriodicPosition() -> Bool {
    let current = positionReportNow()
    guard let lastPeriodicPositionReportAt else {
      self.lastPeriodicPositionReportAt = current
      return false
    }
    guard lastPeriodicPositionReportAt.duration(to: current) >= .seconds(15) else {
      return false
    }
    self.lastPeriodicPositionReportAt = current
    return true
  }

  private func enqueueFinalPositionIfNeeded(from driver: (any PutioVideoPlayerDriving)?) {
    guard
      !finalPositionEnqueued,
      remembersPlaybackPosition,
      readyReported,
      positionIsEstablished,
      let driver,
      let position = Self.normalizedPosition(driver.currentTime)
    else { return }
    finalPositionEnqueued = true
    enqueuePosition(position)
  }

  private func enqueuePosition(_ position: Int) {
    guard let fileID, let reportPosition else { return }
    positionPipeline.enqueue(fileID: fileID, position: position, report: reportPosition)
  }

  private static func normalizedPosition(_ time: CMTime) -> Int? {
    let seconds = CMTimeGetSeconds(time)
    guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return nil }
    return Int(seconds.rounded(.down))
  }
}
