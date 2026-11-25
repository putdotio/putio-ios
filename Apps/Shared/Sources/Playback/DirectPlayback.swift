#if canImport(AetherEngine)
  import AVFoundation
  import AetherEngine
  import Combine
  import PutioCore
  import SwiftUI
  import UIKit
  import VideoToolbox

  enum PutioDirectPlayback {
    nonisolated static func isPlayableInAVPlayer(_ type: String) -> Bool {
      guard AVURLAsset.isPlayableExtendedMIMEType(type) else { return false }
      guard type.contains("av01") else { return true }
      return VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
    }
  }

  @MainActor
  final class PutioDirectPlayEngine {
    static let shared = PutioDirectPlayEngine()

    private var engine: AetherEngine?
    private var owner: ObjectIdentifier?

    func claim(by owner: AnyObject) throws -> AetherEngine {
      let engine = try engine ?? AetherEngine()
      if self.engine == nil {
        engine.maximumSubtitleAdvanceSeconds = 0
        engine.maximumSubtitleDelaySeconds = PutioSubtitleTiming.limitSeconds
        engine.retainsVideoPipelineWhenBackgrounded = true
        engine.deactivatesAudioSessionOnStop = true
      }
      self.engine = engine
      self.owner = ObjectIdentifier(owner)
      return engine
    }

    @discardableResult
    func release(by owner: AnyObject) -> Bool {
      guard self.owner == ObjectIdentifier(owner) else { return false }
      self.owner = nil
      engine?.stop()
      return true
    }
  }

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
  protocol PutioDirectPlayTransport: AnyObject {
    var onEngineRestart: (@MainActor (Double) -> Void)? { get set }
    var onReload: (@MainActor (PutioVideoTrackSelection?) -> Void)? { get set }
    func engineChanged(to engine: AetherEngine)
    func engineReleased(_ engine: AetherEngine)
    func setControlsEnabled(_ enabled: Bool, for engine: AetherEngine)
  }

  @MainActor
  final class PutioDirectPlayCoordinator {
    private let positionPipeline: PutioPlaybackPositionPipeline
    private var engine: AetherEngine?
    private weak var transport: (any PutioDirectPlayTransport)?
    private var positionReporter: PutioVideoPositionReporter?
    private var observations: Set<AnyCancellable> = []
    private var backgroundObservation: NSObjectProtocol?
    private var loading: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var failureReported = false
    private var readyReported = false
    private var positionEstablished = false
    private var callbacks = PutioVideoPlayerCallbacks()
    private var source: PutioPlaybackSource?
    private var options = LoadOptions()

    struct SubtitleStart {
      let policy: PutioSubtitleStartupPolicy
      let remembered: @MainActor () -> PutioRememberedSubtitle?
    }

    init(positionPipeline: PutioPlaybackPositionPipeline) {
      self.positionPipeline = positionPipeline
    }

    func start(
      fileID: PutioFileID, source: PutioPlaybackSource, transport: any PutioDirectPlayTransport,
      preferredAudioLanguages: [String], remembersPlaybackPosition: Bool,
      subtitles: SubtitleStart,
      reportPosition: @escaping PutioPlaybackPositionReport,
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
      } catch {
        reportFailure(Self.error(nil), generation: playbackGeneration)
        return
      }
      self.engine = engine
      engine.bind(view: view)
      transport.engineChanged(to: engine)
      transport.onEngineRestart = { [weak self] seconds in self?.restart(at: seconds) }
      transport.onReload = { [weak self] _ in self?.reload() }

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
          source, in: engine, preferredAudioLanguages: preferredAudioLanguages,
          remembersPlaybackPosition: remembersPlaybackPosition, subtitles: subtitles,
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
            reportFailure(Self.error(engine.errorInfo), generation: playbackGeneration)
          case .idle, .loading, .playing, .seeking:
            break
          }
        }
        .store(in: &observations)
      engine.seekEvents
        .sink { [weak self] event in
          guard let self, generation == playbackGeneration, case .landed = event.outcome else {
            return
          }
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
          reportSubtitle(tracks, active: active)
        }
        .store(in: &observations)
    }

    private func reportSubtitle(_ tracks: [TrackInfo], active: Int?) {
      guard !tracks.isEmpty else { return callbacks.onSubtitleSelected("unavailable") }
      let track = tracks.first { $0.id == active }
      callbacks.onSubtitleSelected(
        track.map { PutioTrackLabel.languageCode($0.language) ?? "unknown" } ?? "off")
    }

    private func load(
      _ source: PutioPlaybackSource, in engine: AetherEngine, preferredAudioLanguages: [String],
      remembersPlaybackPosition: Bool, subtitles: SubtitleStart,
      generation playbackGeneration: UInt64
    ) async {
      let original = source.original
      var options = LoadOptions()
      options.autoplay = false
      options.preferredAudioLanguages = preferredAudioLanguages
      options.prepareNativeSubtitles = true
      let files = original?.fileSubtitles ?? []
      let labels = PutioTrackLabel.fileSubtitleTitles(
        files.map { ($0.languageCode, $0.language, $0.name) })
      options.externalSubtitles = zip(files, labels).map { subtitle, label in
        ExternalSubtitleTrack(
          url: subtitle.url, name: label,
          language: subtitle.languageCode,
          isDefault: subtitle.key == original?.defaultSubtitleKey,
          formatHint: subtitle.url.pathExtension.isEmpty ? "webvtt" : nil)
      }
      self.options = options
      do {
        try await engine.load(url: source.url, options: options)
      } catch is CancellationError {
        return
      } catch {
        reportFailure(Self.error(engine.errorInfo), generation: playbackGeneration)
        return
      }
      guard generation == playbackGeneration, !failureReported else { return }
      selectStartSubtitle(
        in: engine, subtitles: subtitles, embeddedDefault: original?.defaultEmbeddedTrack)
      readyReported = true
      if callbacks.observesPlaybackState {
        reportSubtitle(engine.subtitleTracks, active: engine.activeSubtitleTrackIndex)
      }
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

    private func selectStartSubtitle(
      in engine: AetherEngine, subtitles: SubtitleStart,
      embeddedDefault: (languageCode: String, position: Int)?
    ) {
      guard
        let start = subtitles.policy.startingTrack(
          in: Self.startCandidates(engine.subtitleTracks, embeddedDefault: embeddedDefault),
          remembered: subtitles.remembered())
      else { return }
      engine.selectSubtitleTrack(index: start.id)
    }

    static func startCandidates(
      _ tracks: [TrackInfo], embeddedDefault: (languageCode: String, position: Int)? = nil
    ) -> [PutioSubtitleTrack] {
      let candidates = tracks.filter { !$0.isForced }
      let native: Int? =
        if candidates.contains(where: { $0.isExternal && $0.isDefault }) {
          nil
        } else if let embeddedDefault {
          tracks.filter {
            !$0.isExternal
              && PutioSubtitleLanguage.matches($0.language, embeddedDefault.languageCode)
          }.dropFirst(embeddedDefault.position).first?.id
        } else {
          nil
        }
      return candidates.map { track in
        PutioSubtitleTrack(
          id: track.id, title: track.name, languageTag: track.language,
          isDefault: track.isExternal ? track.isDefault : track.id == native)
      }
    }

    private func reload() {
      guard let engine, generation > 0 else { return }
      let playbackGeneration = generation
      loading?.cancel()
      loading = Task { @MainActor [weak self] in
        do {
          try await engine.reloadAtCurrentPosition()
        } catch is CancellationError {
          return
        } catch {
          self?.reportFailure(Self.error(engine.errorInfo), generation: playbackGeneration)
          return
        }
        guard let self, generation == playbackGeneration else { return }
        engine.play()
      }
    }

    private func restart(at seconds: Double) {
      guard let engine, let source, generation > 0 else { return }
      let playbackGeneration = generation
      var options = options
      options.autoplay = true
      let audioTrack = engine.activeAudioTrackIndex
      let subtitleTrack = engine.activeSubtitleTrackIndex
      loading?.cancel()
      callbacks.onPlaybackRestarted()
      loading = Task { @MainActor [weak self] in
        do {
          try await engine.load(
            url: source.url, startPosition: seconds, options: options,
            audioSourceStreamIndex: audioTrack.map(Int32.init))
        } catch is CancellationError {
          return
        } catch {
          self?.reportFailure(Self.error(engine.errorInfo), generation: playbackGeneration)
          return
        }
        guard let self, generation == playbackGeneration else { return }
        if let subtitleTrack {
          engine.selectSubtitleTrack(index: subtitleTrack)
        } else {
          engine.clearSubtitle()
        }
        _ = positionReporter?.playbackRestarted()
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
      PutioDirectPlayEngine.shared.release(by: self)
      if let engine { transport?.engineReleased(engine) }
      transport = nil
      engine = nil
    }

    private func reportPlaybackEnded() {
      guard readyReported, !failureReported, positionReporter?.playbackEnded() == true else { return }
      callbacks.onPlaybackEnded()
    }

    private func reportFailure(
      _ error: PutioPlayerError, generation playbackGeneration: UInt64
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
      callbacks.onFailure(
        PutioVideoPlayerFailure(
          error: error, heldSeconds: heldSeconds,
          beforeFirstFrame: engine?.hasFirstFrameReadyForDisplay != true))
    }

    static func error(_ info: PlaybackErrorInfo?) -> PutioPlayerError {
      PutioPlayerError(
        aetherKind: info?.kind.rawValue, domain: info?.underlyingDomain, code: info?.underlyingCode)
    }
  }
#endif
