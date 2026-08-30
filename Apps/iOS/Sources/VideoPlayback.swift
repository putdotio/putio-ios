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
    message: "The stream stopped before playback could begin. Try again."
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
  private let reportsPlayerFailures: Bool

  init(
    route: PutioFileRoute,
    reportsPlayerFailures: Bool = true,
    resolve: @escaping PutioPlaybackResolve
  ) {
    self.reportsPlayerFailures = reportsPlayerFailures
    _model = State(
      initialValue: PutioVideoPlaybackModel(fileID: route.id, resolve: resolve)
    )
  }

  var body: some View {
    ZStack(alignment: .topTrailing) {
      content
      Button("Done") {
        dismiss()
      }
      .buttonStyle(.borderedProminent)
      .padding(PutioTheme.Spacing.space4)
      .accessibilityIdentifier("video.done")
    }
    .background(Color.black)
    .task {
      await model.loadIfNeeded()
    }
    .task(id: retrySequence) {
      guard retrySequence > 0 else { return }
      await model.retry()
    }
  }

  @ViewBuilder
  private var content: some View {
    switch model.state {
    case .loading:
      PutioLoadingStateView(title: "Preparing video")
        .accessibilityIdentifier("video.loading")
    case .ready(let source):
      PutioSystemVideoPlayer(source: source) {
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
  let onFailure: @MainActor @Sendable () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeUIViewController(context: Context) -> AVPlayerViewController {
    let controller = AVPlayerViewController()
    controller.allowsPictureInPicturePlayback = true
    controller.entersFullScreenWhenPlaybackBegins = false
    controller.exitsFullScreenWhenPlaybackEnds = false
    context.coordinator.start(source: source, in: controller, onFailure: onFailure)
    return controller
  }

  func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}

  static func dismantleUIViewController(
    _ controller: AVPlayerViewController,
    coordinator: Coordinator
  ) {
    coordinator.stop(controller: controller)
  }

  @MainActor
  final class Coordinator {
    private var statusObservation: NSKeyValueObservation?
    private var onFailure: (@MainActor () -> Void)?

    func start(
      source: PutioPlaybackSource,
      in controller: AVPlayerViewController,
      onFailure: @escaping @MainActor () -> Void
    ) {
      self.onFailure = onFailure
      let item = AVPlayerItem(url: source.url)
      statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
        guard item.status == .failed else { return }
        Task { @MainActor [weak self] in self?.reportFailure() }
      }

      let player = AVPlayer(playerItem: item)
      controller.player = player
      guard source.startFromSeconds > 0 else {
        player.play()
        return
      }

      let startTime = CMTime(
        seconds: Double(source.startFromSeconds),
        preferredTimescale: 600
      )
      player.seek(to: startTime, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
        guard finished else { return }
        player.play()
      }
    }

    func stop(controller: AVPlayerViewController) {
      statusObservation = nil
      onFailure = nil
      controller.player?.pause()
      controller.player?.replaceCurrentItem(with: nil)
      controller.player = nil
    }

    private func reportFailure() {
      onFailure?()
    }
  }
}
