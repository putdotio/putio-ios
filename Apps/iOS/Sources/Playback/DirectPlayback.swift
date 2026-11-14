import AVFoundation
import AetherEngine
import Combine
import PutioCore
import SwiftUI
import UIKit
import VideoToolbox

enum PutioDirectPlayback {
  /// AVPlayer's answer for an MP4 original's codecs; AV1 counts only with a
  /// hardware decoder.
  nonisolated static func isPlayableInAVPlayer(_ type: String) -> Bool {
    guard AVURLAsset.isPlayableExtendedMIMEType(type) else { return false }
    guard type.contains("av01") else { return true }
    return VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
  }
}

/// The app's one Direct play engine. The player that claimed it last owns it;
/// a player that let go of it after a newer one claimed it leaves it playing.
@MainActor
final class PutioDirectPlayEngine {
  static let shared = PutioDirectPlayEngine()

  private var engine: AetherEngine?
  private var owner: ObjectIdentifier?

  func claim(by owner: AnyObject) throws -> AetherEngine {
    let engine = try engine ?? AetherEngine()
    if self.engine == nil {
      engine.maximumSubtitleOffsetSeconds = 0
    }
    self.engine = engine
    self.owner = ObjectIdentifier(owner)
    return engine
  }

  func release(by owner: AnyObject) {
    guard self.owner == ObjectIdentifier(owner) else { return }
    self.owner = nil
    engine?.stop()
  }
}

/// Plays an original in the Direct play engine behind the same controls,
/// resume and position saving as AVPlayer.
struct PutioDirectPlayerView: UIViewRepresentable {
  let fileID: PutioFileID
  let source: PutioPlaybackSource
  let transport: PutioVideoTransport
  let remembersPlaybackPosition: Bool
  let positionPipeline: PutioPlaybackPositionPipeline
  let reportPosition: PutioPlaybackPositionReport
  let callbacks: PutioVideoPlayerCallbacks

  func makeCoordinator() -> PutioDirectPlayCoordinator {
    PutioDirectPlayCoordinator(positionPipeline: positionPipeline)
  }

  func makeUIView(context: Context) -> AetherPlayerView {
    let view = AetherPlayerView()
    view.backgroundColor = .black
    context.coordinator.start(
      fileID: fileID, source: source, transport: transport,
      remembersPlaybackPosition: remembersPlaybackPosition,
      reportPosition: { try await reportPosition($0, $1) }, in: view, callbacks: callbacks)
    return view
  }

  func updateUIView(_ view: AetherPlayerView, context: Context) {}

  static func dismantleUIView(_ view: AetherPlayerView, coordinator: PutioDirectPlayCoordinator) {
    coordinator.stop()
  }
}

/// What a player reports to the screen around it.
struct PutioVideoPlayerCallbacks {
  var onReady: @MainActor @Sendable () -> Void = {}
  var onDurationKnown: @MainActor @Sendable (Double) -> Void = { _ in }
  var observesPlaybackState = false
  var onAudioSelected: @MainActor @Sendable (String) -> Void = { _ in }
  var onSubtitleSelected: @MainActor @Sendable (String) -> Void = { _ in }
  var onPositionChanged: @MainActor @Sendable (Int) -> Void = { _ in }
  var onPlaybackEnded: @MainActor @Sendable () -> Void = {}
  var onPlaybackRestarted: @MainActor @Sendable () -> Void = {}
  var onFailure: @MainActor @Sendable (PutioVideoPlayerFailure) -> Void = { _ in }
}

@MainActor
final class PutioDirectPlayCoordinator {
  private let positionPipeline: PutioPlaybackPositionPipeline
  private let audioSession: any PutioPlaybackAudioSessioning
  private var engine: AetherEngine?
  private weak var transport: PutioVideoTransport?
  private var positionReporter: PutioVideoPositionReporter?
  private var observations: Set<AnyCancellable> = []
  private var backgroundObservation: NSObjectProtocol?
  private var loading: Task<Void, Never>?
  private var generation: UInt64 = 0
  private var failureReported = false
  private var readyReported = false
  private var positionEstablished = false
  private var audioSessionIsActive = false
  private var callbacks = PutioVideoPlayerCallbacks()
  private var source: PutioPlaybackSource?

  init(positionPipeline: PutioPlaybackPositionPipeline) {
    self.positionPipeline = positionPipeline
    audioSession = PutioPlaybackAudioSession()
  }

  func start(
    fileID: PutioFileID, source: PutioPlaybackSource, transport: PutioVideoTransport,
    remembersPlaybackPosition: Bool, reportPosition: @escaping PutioPlaybackPositionReport,
    in view: AetherPlayerView, callbacks: PutioVideoPlayerCallbacks
  ) {
    generation &+= 1
    let playbackGeneration = generation
    self.callbacks = callbacks
    self.source = source
    self.transport = transport
    failureReported = false
    readyReported = false
    positionEstablished = false
    let engine: AetherEngine
    do {
      engine = try PutioDirectPlayEngine.shared.claim(by: self)
      try audioSession.activate()
      audioSessionIsActive = true
    } catch {
      reportFailure(.playback, generation: playbackGeneration)
      return
    }
    self.engine = engine
    engine.bind(view: view)
    transport.engineChanged(to: engine)
    transport.onEngineRestart = { [weak self] in self?.restart() }

    let reporter = PutioVideoPositionReporter(
      fileID: fileID,
      remembersPosition: remembersPlaybackPosition,
      pipeline: positionPipeline,
      report: reportPosition,
      currentPosition: { [weak self, weak engine] in
        guard let self, let engine, self.engine === engine else { return nil }
        return PutioVideoPositionReporter.normalizedPosition(seconds: engine.currentTime)
      },
      savedPosition: remembersPlaybackPosition ? source.startFromSeconds : nil,
      endOfPlayback: .keepsPosition)
    positionReporter = reporter
    observe(engine, generation: playbackGeneration)

    loading = Task { @MainActor [weak self] in
      await self?.load(
        source, in: engine, remembersPlaybackPosition: remembersPlaybackPosition,
        generation: playbackGeneration)
    }
  }

  private func observe(_ engine: AetherEngine, generation playbackGeneration: UInt64) {
    engine.$state
      .dropFirst()
      .sink { [weak self] state in
        guard let self, generation == playbackGeneration else { return }
        switch state {
        case .paused:
          positionReporter?.savePosition()
        case .ended:
          reportPlaybackEnded()
        case .error:
          reportFailure(Self.fault(engine.errorInfo), generation: playbackGeneration)
        case .idle, .loading, .playing, .seeking:
          break
        }
      }
      .store(in: &observations)
    engine.seekEvents
      .sink { [weak self] event in
        guard let self, generation == playbackGeneration, case .landed = event.outcome else { return }
        positionReporter?.savePosition()
      }
      .store(in: &observations)
    backgroundObservation = NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.generation == playbackGeneration else { return }
        self.positionReporter?.savePosition()
      }
    }
    guard callbacks.observesPlaybackState else { return }
    engine.clock.$currentTime
      .filter { [weak self] _ in self?.readyReported == true }
      .compactMap { PutioVideoPositionReporter.normalizedPosition(seconds: $0) }
      .removeDuplicates()
      .sink { [weak self] position in
        guard let self, generation == playbackGeneration else { return }
        callbacks.onPositionChanged(position)
      }
      .store(in: &observations)
    engine.$audioTracks.combineLatest(engine.$activeAudioTrackIndex)
      .sink { [weak self] tracks, active in
        guard let self, generation == playbackGeneration,
          let track = tracks.first(where: { $0.id == active }),
          let code = PutioTrackLabel.languageCode(track.language)
        else { return }
        callbacks.onAudioSelected(code)
      }
      .store(in: &observations)
    engine.$subtitleTracks.combineLatest(engine.$activeSubtitleTrackIndex)
      .sink { [weak self] tracks, active in
        guard let self, generation == playbackGeneration, readyReported else { return }
        guard !tracks.isEmpty else { return callbacks.onSubtitleSelected("unavailable") }
        let track = tracks.first { $0.id == active }
        callbacks.onSubtitleSelected(
          track.map { PutioTrackLabel.languageCode($0.language) ?? "unknown" } ?? "off")
      }
      .store(in: &observations)
  }

  private func load(
    _ source: PutioPlaybackSource, in engine: AetherEngine, remembersPlaybackPosition: Bool,
    generation playbackGeneration: UInt64
  ) async {
    let original = source.original
    var options = LoadOptions()
    options.autoplay = false
    options.externalSubtitles = (original?.subtitles ?? []).map { subtitle in
      ExternalSubtitleTrack(
        url: subtitle.url, name: subtitle.language, language: subtitle.languageCode,
        isDefault: subtitle.key == original?.defaultSubtitleKey,
        formatHint: subtitle.url.pathExtension.isEmpty ? "webvtt" : nil)
    }
    do {
      try await engine.load(url: source.url, options: options)
    } catch is CancellationError {
      return
    } catch {
      reportFailure(Self.fault(engine.errorInfo), generation: playbackGeneration)
      return
    }
    guard generation == playbackGeneration, !failureReported else { return }
    selectDefaultSubtitle(of: original, in: engine)
    readyReported = true
    positionReporter?.ready()
    if engine.duration > 0 { callbacks.onDurationKnown(engine.duration) }
    callbacks.onReady()

    let start =
      source.resumesAfterFailure
      ? source.startFromSeconds
      : remembersPlaybackPosition
        ? PutioPlaybackProgress.startSeconds(
          savedSeconds: source.startFromSeconds, durationSeconds: engine.duration) : 0
    if start > 0 {
      await engine.seek(to: Double(start))
      guard generation == playbackGeneration, !failureReported else { return }
    }
    positionEstablished = true
    positionReporter?.positionEstablished()
    positionReporter?.startReporting()
    transport?.setControlsEnabled(true, for: engine)
    engine.play()
  }

  /// The engine numbers put.io's subtitle files after the file's own tracks,
  /// in the order the load listed them.
  private func selectDefaultSubtitle(of original: PutioOriginalPlayback?, in engine: AetherEngine) {
    guard let original, let key = original.defaultSubtitleKey,
      let index = original.subtitles.firstIndex(where: { $0.key == key })
    else { return }
    let external = engine.subtitleTracks.filter(\.isExternal)
    guard external.indices.contains(index) else { return }
    engine.selectSubtitleTrack(index: external[index].id)
  }

  /// A session that reached its end plays again from the start.
  private func restart() {
    guard let engine, let source, generation > 0 else { return }
    let playbackGeneration = generation
    loading?.cancel()
    loading = Task { @MainActor [weak self] in
      do {
        try await engine.load(url: source.url, startPosition: 0)
      } catch is CancellationError {
        return
      } catch {
        self?.reportFailure(Self.fault(engine.errorInfo), generation: playbackGeneration)
        return
      }
      guard let self, generation == playbackGeneration,
        positionReporter?.playbackRestarted() == true
      else { return }
      callbacks.onPlaybackRestarted()
    }
  }

  func stop() {
    positionReporter?.stop()
    positionReporter = nil
    generation &+= 1
    loading?.cancel()
    loading = nil
    observations.removeAll()
    if let backgroundObservation {
      NotificationCenter.default.removeObserver(backgroundObservation)
      self.backgroundObservation = nil
    }
    transport?.onEngineRestart = nil
    transport?.engineChanged(to: nil)
    transport = nil
    PutioDirectPlayEngine.shared.release(by: self)
    engine = nil
    if audioSessionIsActive {
      audioSession.deactivate()
      audioSessionIsActive = false
    }
  }

  private func reportPlaybackEnded() {
    guard readyReported, !failureReported, positionReporter?.playbackEnded() == true else { return }
    callbacks.onPlaybackEnded()
  }

  private func reportFailure(
    _ fault: PutioVideoPlayerFault, generation playbackGeneration: UInt64
  ) {
    guard generation == playbackGeneration, !failureReported else { return }
    failureReported = true
    let playingSeconds = engine.flatMap {
      PutioVideoPositionReporter.normalizedPosition(seconds: $0.currentTime)
    }
    let heldSeconds =
      positionEstablished
      ? playingSeconds : source.flatMap { $0.resumesAfterFailure ? $0.startFromSeconds : nil }
    positionReporter?.playbackFailed()
    callbacks.onFailure(PutioVideoPlayerFailure(fault: fault, heldSeconds: heldSeconds))
  }

  /// The engine names the failure's underlying error by domain and code.
  private static func fault(_ info: PlaybackErrorInfo?) -> PutioVideoPlayerFault {
    guard let info, let domain = info.underlyingDomain, let code = info.underlyingCode else {
      return .playback
    }
    return PutioVideoPlayerFault(error: NSError(domain: domain, code: code))
  }
}

/// The Direct play engine's subtitle cues, drawn over the picture.
struct PutioVideoSubtitleOverlay: View {
  let cues: [PutioVideoCue]

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .bottom) {
        ForEach(cues) { cue in
          if let image = cue.image, let position = cue.position {
            Image(decorative: image, scale: 1)
              .resizable()
              .frame(
                width: position.width * geometry.size.width,
                height: position.height * geometry.size.height
              )
              .position(
                x: position.midX * geometry.size.width, y: position.midY * geometry.size.height)
          } else if let text = cue.text, !text.isEmpty {
            Text(text)
              .putioFont(PutioTheme.Typography.body)
              .foregroundStyle(.white)
              .multilineTextAlignment(.center)
              .shadow(color: .black, radius: 2)
              .padding(.horizontal, PutioTheme.Spacing.space4)
              .padding(.bottom, PutioTheme.Spacing.space6)
              .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
              .accessibilityIdentifier("video.subtitle-cue")
          }
        }
      }
    }
    .allowsHitTesting(false)
  }
}
