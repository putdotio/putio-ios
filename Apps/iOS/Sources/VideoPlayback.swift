import AVFoundation
import AVKit
import Observation
import PutioCore
import SwiftUI

typealias PutioPlaybackResolve =
  @MainActor @Sendable (PutioFileID) async throws -> PutioPlaybackResolution

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
struct PutioVideoPlaybackView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var model: PutioVideoPlaybackModel
  @State private var retrySequence: UInt64 = 0
  @State private var playerIsReady = false
  private let reportsPlayerFailures: Bool
  private let showsHarnessReadiness: Bool

  init(
    route: PutioFileRoute,
    reportsPlayerFailures: Bool = true,
    showsHarnessReadiness: Bool = false,
    resolve: @escaping PutioPlaybackResolve
  ) {
    self.reportsPlayerFailures = reportsPlayerFailures
    self.showsHarnessReadiness = showsHarnessReadiness
    _model = State(
      initialValue: PutioVideoPlaybackModel(fileID: route.id, resolve: resolve)
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
      if showsHarnessReadiness, playerIsReady {
        Color.clear
          .frame(width: 1, height: 1)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("Video ready")
          .accessibilityIdentifier("video.ready")
          .allowsHitTesting(false)
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
        source: source,
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
  let source: PutioPlaybackSource
  let onReady: @MainActor @Sendable () -> Void
  let onFailure: @MainActor @Sendable () -> Void

  func makeCoordinator() -> PutioSystemVideoPlayerCoordinator {
    PutioSystemVideoPlayerCoordinator()
  }

  func makeUIViewController(context: Context) -> AVPlayerViewController {
    let controller = AVPlayerViewController()
    controller.allowsPictureInPicturePlayback = true
    controller.entersFullScreenWhenPlaybackBegins = false
    controller.exitsFullScreenWhenPlaybackEnds = false
    if context.coordinator.start(
      source: source,
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

  func play()
  func seek(to time: CMTime, completion: @escaping @Sendable (Bool) -> Void)
  func stop()
}

@MainActor
private final class PutioSystemVideoPlayerDriver: PutioVideoPlayerDriving {
  let player: AVPlayer

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
  typealias StatusObserverFactory =
    @MainActor (
      AVPlayerItem,
      @escaping @Sendable (AVPlayerItem.Status) -> Void
    ) -> any PutioPlayerItemStatusObservation

  private let makeDriver: DriverFactory
  private let observeItemStatus: StatusObserverFactory
  private let audioSession: any PutioPlaybackAudioSessioning
  private let notificationCenter: NotificationCenter
  private var statusObservation: (any PutioPlayerItemStatusObservation)?
  private var failedToEndObservation: NSObjectProtocol?
  private var driver: (any PutioVideoPlayerDriving)?
  private var onReady: (@MainActor () -> Void)?
  private var onFailure: (@MainActor () -> Void)?
  private var generation: UInt64 = 0
  private var readyReported = false
  private var failureReported = false
  private var audioSessionIsActive = false

  convenience init() {
    self.init(
      makeDriver: { PutioSystemVideoPlayerDriver(item: $0) },
      audioSession: PutioPlaybackAudioSession(),
      notificationCenter: .default
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
    notificationCenter: NotificationCenter
  ) {
    self.makeDriver = makeDriver
    self.observeItemStatus = observeItemStatus
    self.audioSession = audioSession
    self.notificationCenter = notificationCenter
  }

  @discardableResult
  func start(
    source: PutioPlaybackSource,
    in controller: AVPlayerViewController,
    onReady: @escaping @MainActor () -> Void = {},
    onFailure: @escaping @MainActor () -> Void
  ) -> Bool {
    generation &+= 1
    let playbackGeneration = generation
    readyReported = false
    failureReported = false
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

    guard source.startFromSeconds > 0 else {
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
        driver.play()
      }
    }
    return true
  }

  func stop(controller: AVPlayerViewController) {
    generation &+= 1
    statusObservation?.invalidate()
    statusObservation = nil
    if let failedToEndObservation {
      notificationCenter.removeObserver(failedToEndObservation)
      self.failedToEndObservation = nil
    }
    onReady = nil
    onFailure = nil
    driver?.stop()
    driver = nil
    controller.player = nil
    if audioSessionIsActive {
      audioSession.deactivate()
      audioSessionIsActive = false
    }
  }

  private func reportFailure(generation playbackGeneration: UInt64) {
    guard generation == playbackGeneration, !failureReported else { return }
    failureReported = true
    onFailure?()
  }

  private func reportReady(generation playbackGeneration: UInt64) {
    guard generation == playbackGeneration, !readyReported, !failureReported else { return }
    readyReported = true
    onReady?()
  }
}
