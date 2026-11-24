#if os(iOS) || os(tvOS) || os(macOS)
  import AVFoundation
  import Foundation

  #if canImport(UIKit)
    import UIKit
  #endif

  /// The view an app shows the player in: an `AVPlayerLayer` host on iOS,
  /// `AVPlayerViewController` on tvOS.
  @MainActor
  public protocol PutioVideoPlayerSurface: AnyObject, Sendable {
    var player: AVPlayer? { get set }
    var showsPlaybackControls: Bool { get set }
    var showsFirstFrame: Bool { get }
  }

  @MainActor
  public protocol PutioVideoPlayerDriving: AnyObject, Sendable {
    var player: AVPlayer { get }
    var currentTime: CMTime { get }
    var itemDuration: CMTime { get }

    func play()
    func seek(to time: CMTime, completion: @escaping @Sendable (Bool) -> Void)
    func observePosition(
      every interval: CMTime,
      callback: @escaping @Sendable (CMTime) -> Void
    ) -> Any
    func removePositionObservation(_ observation: Any)
    func stop()
  }

  @MainActor
  public final class PutioVideoPlayerDriver: PutioVideoPlayerDriving {
    public let player: AVPlayer

    public var currentTime: CMTime {
      player.currentTime()
    }

    public var itemDuration: CMTime {
      player.currentItem?.duration ?? .invalid
    }

    public init(player: AVPlayer) {
      self.player = player
    }

    public convenience init(item: AVPlayerItem) {
      self.init(player: AVPlayer(playerItem: item))
    }

    public func play() {
      player.play()
    }

    public func seek(to time: CMTime, completion: @escaping @Sendable (Bool) -> Void) {
      player.seek(
        to: time,
        toleranceBefore: .zero,
        toleranceAfter: .zero,
        completionHandler: completion
      )
    }

    public func observePosition(
      every interval: CMTime,
      callback: @escaping @Sendable (CMTime) -> Void
    ) -> Any {
      player.addPeriodicTimeObserver(forInterval: interval, queue: .main, using: callback)
    }

    public func removePositionObservation(_ observation: Any) {
      player.removeTimeObserver(observation)
    }

    public func stop() {
      player.currentItem?.cancelPendingSeeks()
      player.pause()
      player.replaceCurrentItem(with: nil)
    }
  }

  @MainActor
  public protocol PutioPlaybackAudioSessioning: AnyObject {
    func activate() throws
    func deactivate()
  }

  #if os(iOS) || os(tvOS)
    @MainActor
    public final class PutioPlaybackAudioSession: PutioPlaybackAudioSessioning {
      public init() {}

      public func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .moviePlayback)
        try session.setActive(true)
      }

      public func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(
          false,
          options: .notifyOthersOnDeactivation
        )
      }
    }
  #endif

  @MainActor
  public protocol PutioPlayerItemStatusObservation: AnyObject {
    func invalidate()
  }

  extension NSKeyValueObservation: PutioPlayerItemStatusObservation {}

  public struct PutioVideoPlayerFailure: Equatable, Sendable {
    public let error: PutioPlayerError
    public let heldSeconds: Int?
    public var beforeFirstFrame: Bool

    public init(error: PutioPlayerError, heldSeconds: Int?, beforeFirstFrame: Bool = false) {
      self.error = error
      self.heldSeconds = heldSeconds
      self.beforeFirstFrame = beforeFirstFrame
    }

    public var fault: PutioVideoPlayerFault { error.fault }
  }

  /// One AVPlayer playback on iOS or tvOS: the item's readiness, the start
  /// subtitle and audio, the resume seek, position saves, the end and a
  /// restart after it, and failures with the position they held. Controls
  /// stay hidden until the tracks and the start position are settled, so no
  /// choice made before them can be overridden.
  @MainActor
  public final class PutioVideoPlayerSession {
    public typealias DefaultSubtitleApplier = @MainActor (AVPlayerItem) async -> Void
    public typealias TrackRestorer =
      @MainActor (PutioVideoTrackSelection, AVPlayerItem) async -> Void
    public typealias DriverFactory = @MainActor (AVPlayerItem) -> any PutioVideoPlayerDriving
    public typealias DurationLoader = @MainActor (AVPlayerItem) async -> Double?
    public typealias PositionReportScheduler = PutioVideoPositionReporter.Scheduler
    public typealias StatusObserverFactory =
      @MainActor (
        AVPlayerItem,
        @escaping @Sendable (AVPlayerItem.Status) -> Void
      ) -> any PutioPlayerItemStatusObservation

    private let makeItem: @MainActor (URL) -> AVPlayerItem
    private let makeDriver: DriverFactory
    private let observeItemStatus: StatusObserverFactory
    private let selectedAudioLanguage: @MainActor (AVPlayerItem) async -> String?
    private let applyDefaultSubtitle: DefaultSubtitleApplier
    private let restoreTracks: TrackRestorer
    private let audioSession: any PutioPlaybackAudioSessioning
    private let notificationCenter: NotificationCenter
    private let backgroundNotification: Notification.Name?
    private let positionPipeline: PutioPlaybackPositionPipeline
    private let schedulePositionReports: PositionReportScheduler
    private let loadDuration: DurationLoader
    private var statusObservation: (any PutioPlayerItemStatusObservation)?
    private var positionReporter: PutioVideoPositionReporter?
    private var positionObservation: Any?
    private var failedToEndObservation: NSObjectProtocol?
    private var playedToEndObservation: NSObjectProtocol?
    private var timeJumpedObservation: NSObjectProtocol?
    private var mediaSelectionObservation: NSObjectProtocol?
    private var positionSaveObservations: [NSObjectProtocol] = []
    private var driver: (any PutioVideoPlayerDriving)?
    private var onReady: (@MainActor () -> Void)?
    private var onDurationKnown: (@MainActor (Double) -> Void)?
    private var onAudioSelected: (@MainActor @Sendable (String) -> Void)?
    /// Harness probes; set before `start` and reported only while observing.
    public var onSubtitleSelected: (@MainActor @Sendable (String) -> Void)?
    public var onSubtitleTextShown: (@MainActor @Sendable (String) -> Void)?
    private var subtitleTextProbe: PutioSubtitleTextProbe?
    private var observesPlaybackState = false
    private var onPositionChanged: (@MainActor @Sendable (Int) -> Void)?
    private var onPlaybackEnded: (@MainActor @Sendable () -> Void)?
    private var onPlaybackRestarted: (@MainActor @Sendable () -> Void)?
    private var onFailure: (@MainActor (PutioVideoPlayerFailure) -> Void)?
    private var generation: UInt64 = 0
    private var readyReported = false
    private var defaultSubtitleRequested = false
    private var failureReported = false
    private var positionEstablished = false
    private var recoveredStartSeconds: Int?
    private var fileID: PutioFileID?
    private var audioSessionIsActive = false
    private var pendingControlGates: Set<ControlGate> = []
    private weak var surface: (any PutioVideoPlayerSurface)?
    private var reloadAt: (@MainActor (Int?, PutioVideoTrackSelection?) -> Void)?

    private enum ControlGate {
      case audio
      case defaultSubtitle
      case position
    }

    public var player: AVPlayer? { driver?.player }

    #if os(iOS) || os(tvOS)
      public convenience init() {
        self.init(
          makeDriver: { PutioVideoPlayerDriver(item: $0) },
          audioSession: PutioPlaybackAudioSession(),
          notificationCenter: .default,
          positionPipeline: PutioPlaybackPositionPipeline()
        )
      }

      public convenience init(
        positionPipeline: PutioPlaybackPositionPipeline,
        subtitlePolicy: PutioSubtitleStartupPolicy,
        subtitleMemory: PutioSubtitleMemory?,
        makeItem: @escaping @MainActor (URL) -> AVPlayerItem = { AVPlayerItem(url: $0) },
        makeDriver: @escaping DriverFactory = { PutioVideoPlayerDriver(item: $0) }
      ) {
        self.init(
          makeItem: makeItem,
          makeDriver: makeDriver,
          audioSession: PutioPlaybackAudioSession(),
          notificationCenter: .default,
          positionPipeline: positionPipeline,
          applyDefaultSubtitle: {
            await PutioVideoTracks.selectStartSubtitle(
              in: $0, policy: subtitlePolicy, remembered: subtitleMemory?.remembered)
          }
        )
      }
    #endif

    public init(
      makeItem: @escaping @MainActor (URL) -> AVPlayerItem = { AVPlayerItem(url: $0) },
      makeDriver: @escaping DriverFactory,
      observeItemStatus: @escaping StatusObserverFactory = { item, statusChanged in
        item.observe(\.status, options: [.initial, .new]) { item, _ in
          statusChanged(item.status)
        }
      },
      audioSession: any PutioPlaybackAudioSessioning,
      notificationCenter: NotificationCenter,
      backgroundNotification: Notification.Name? = PutioVideoPlayerSession
        .applicationBackgroundNotification,
      positionPipeline: PutioPlaybackPositionPipeline,
      selectedAudioLanguage: @escaping @MainActor (AVPlayerItem) async -> String? = {
        await PutioMediaSelection.selectedAudioLanguage(in: $0)
      },
      applyDefaultSubtitle: @escaping DefaultSubtitleApplier = {
        await PutioVideoPlayerSession.selectDefaultSubtitle(in: $0)
      },
      restoreTracks: @escaping TrackRestorer = {
        await PutioVideoTracks.restore($0, in: $1)
      },
      schedulePositionReports: @escaping PositionReportScheduler = { interval, callback in
        PutioMonotonicPositionReportSchedule(interval: interval, callback: callback)
      },
      loadDuration: @escaping DurationLoader = {
        await PutioVideoPlayerSession.duration(of: $0)
      }
    ) {
      self.makeItem = makeItem
      self.makeDriver = makeDriver
      self.observeItemStatus = observeItemStatus
      self.selectedAudioLanguage = selectedAudioLanguage
      self.applyDefaultSubtitle = applyDefaultSubtitle
      self.restoreTracks = restoreTracks
      self.audioSession = audioSession
      self.notificationCenter = notificationCenter
      self.backgroundNotification = backgroundNotification
      self.positionPipeline = positionPipeline
      self.schedulePositionReports = schedulePositionReports
      self.loadDuration = loadDuration
    }

    public nonisolated static var applicationBackgroundNotification: Notification.Name? {
      #if canImport(UIKit)
        UIApplication.didEnterBackgroundNotification
      #else
        nil
      #endif
    }

    @discardableResult
    public func start(
      fileID: PutioFileID = .root,
      source: PutioPlaybackSource,
      preparedItem: AVPlayerItem? = nil,
      preferredAudioLanguages: [String] = [],
      remembersPlaybackPosition: Bool = true,
      reportPosition: @escaping PutioPlaybackPositionReport = { _, _ in },
      in surface: any PutioVideoPlayerSurface,
      onReady: @escaping @MainActor () -> Void = {},
      onDurationKnown: @escaping @MainActor (Double) -> Void = { _ in },
      observesPlaybackState: Bool = false,
      onAudioSelected: @escaping @MainActor @Sendable (String) -> Void = { _ in },
      onPositionChanged: @escaping @MainActor @Sendable (Int) -> Void = { _ in },
      onPlaybackEnded: @escaping @MainActor @Sendable () -> Void = {},
      onPlaybackRestarted: @escaping @MainActor @Sendable () -> Void = {},
      reloadingAt reloadSeconds: Int? = nil,
      restoringTracks restoredTracks: PutioVideoTrackSelection? = nil,
      onFailure: @escaping @MainActor (PutioVideoPlayerFailure) -> Void
    ) -> Bool {
      reloadAt = { [weak self, weak surface] seconds, tracks in
        guard let self, let surface else { return }
        stop(surface: surface)
        start(
          fileID: fileID, source: source, preferredAudioLanguages: preferredAudioLanguages,
          remembersPlaybackPosition: remembersPlaybackPosition, reportPosition: reportPosition,
          in: surface, onReady: onReady, onDurationKnown: onDurationKnown,
          observesPlaybackState: observesPlaybackState, onAudioSelected: onAudioSelected,
          onPositionChanged: onPositionChanged, onPlaybackEnded: onPlaybackEnded,
          onPlaybackRestarted: onPlaybackRestarted, reloadingAt: seconds,
          restoringTracks: tracks, onFailure: onFailure)
      }
      generation &+= 1
      let playbackGeneration = generation
      readyReported = false
      defaultSubtitleRequested = false
      failureReported = false
      positionEstablished = false
      recoveredStartSeconds = nil
      pendingControlGates = [.audio, .defaultSubtitle, .position]
      self.surface = surface
      positionReporter?.cancel()
      self.observesPlaybackState = observesPlaybackState
      self.fileID = fileID
      self.onReady = onReady
      self.onDurationKnown = onDurationKnown
      self.onAudioSelected = observesPlaybackState ? onAudioSelected : nil
      self.onPositionChanged = observesPlaybackState ? onPositionChanged : nil
      self.onPlaybackEnded = onPlaybackEnded
      self.onPlaybackRestarted = onPlaybackRestarted
      self.onFailure = onFailure

      let item = preparedItem ?? makeItem(source.url)
      statusObservation = observeItemStatus(item) { [weak self] status in
        Task { @MainActor [weak self] in
          switch status {
          case .readyToPlay:
            if let restoredTracks {
              await self?.restoreTracksOnce(
                restoredTracks, to: item, generation: playbackGeneration)
            } else {
              self?.applyDefaultSubtitleOnce(to: item, generation: playbackGeneration)
              if !preferredAudioLanguages.isEmpty {
                await PutioMediaSelection.selectAudio(preferring: preferredAudioLanguages, in: item)
              }
            }
            self?.settleControls(.audio, generation: playbackGeneration)
            self?.reportMediaSelection(for: item, generation: playbackGeneration)
            self?.reportReady(generation: playbackGeneration)
          case .failed:
            self?.reportFailure(
              PutioPlayerError(avPlayerError: item.error), generation: playbackGeneration)
          case .unknown:
            break
          @unknown default:
            break
          }
        }
      }
      if observesPlaybackState, let onSubtitleTextShown {
        let probe = PutioSubtitleTextProbe(onText: onSubtitleTextShown)
        probe.attach(to: item)
        subtitleTextProbe = probe
      }
      if observesPlaybackState {
        mediaSelectionObservation = notificationCenter.addObserver(
          forName: AVPlayerItem.mediaSelectionDidChangeNotification, object: item, queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated {
            self?.reportMediaSelection(for: item, generation: playbackGeneration)
          }
        }
      }
      failedToEndObservation = notificationCenter.addObserver(
        forName: AVPlayerItem.failedToPlayToEndTimeNotification,
        object: item,
        queue: nil
      ) { [weak self] notification in
        let error = PutioPlayerError(
          avPlayerError: notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey]
            as? NSError
        )
        Task { @MainActor [weak self] in
          self?.reportFailure(error, generation: playbackGeneration)
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
      timeJumpedObservation = notificationCenter.addObserver(
        forName: AVPlayerItem.timeJumpedNotification,
        object: item,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.reportPlaybackRestarted(generation: playbackGeneration)
          self?.savePosition(generation: playbackGeneration)
        }
      }

      surface.showsPlaybackControls = false

      let driver = makeDriver(item)
      self.driver = driver
      surface.player = driver.player
      let positionReporter = PutioVideoPositionReporter(
        fileID: fileID,
        remembersPosition: remembersPlaybackPosition,
        pipeline: positionPipeline,
        report: reportPosition,
        currentPosition: { [weak self, weak driver] in
          guard let self, let driver, self.driver === driver else { return nil }
          return PutioVideoPositionReporter.normalizedPosition(
            seconds: CMTimeGetSeconds(driver.currentTime))
        },
        savedPosition: remembersPlaybackPosition ? reloadSeconds ?? source.startFromSeconds : nil,
        endOfPlayback: .keepsPosition,
        schedule: schedulePositionReports
      )
      self.positionReporter = positionReporter
      for observation in positionSaveObservations {
        notificationCenter.removeObserver(observation)
      }
      positionSaveObservations = [
        notificationCenter.addObserver(
          forName: AVPlayer.rateDidChangeNotification, object: driver.player, queue: .main
        ) { [weak self, weak driver] _ in
          MainActor.assumeIsolated {
            guard driver?.player.rate == 0 else { return }
            self?.savePosition(generation: playbackGeneration)
          }
        }
      ]
      if let backgroundNotification {
        positionSaveObservations.append(
          notificationCenter.addObserver(
            forName: backgroundNotification, object: nil, queue: .main
          ) { [weak self] _ in
            MainActor.assumeIsolated {
              self?.savePosition(generation: playbackGeneration)
            }
          })
      }
      if self.onPositionChanged != nil {
        positionObservation = driver.observePosition(
          every: CMTime(seconds: 0.25, preferredTimescale: 600)
        ) { [weak self] time in
          Task { @MainActor [weak self] in
            guard
              let self,
              generation == playbackGeneration,
              time.isValid,
              time.isNumeric
            else { return }
            let seconds = time.seconds
            guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return }
            self.onPositionChanged?(Int(seconds.rounded(.down)))
          }
        }
      }

      let seeksToStart = remembersPlaybackPosition || source.resumesAfterFailure
      recoveredStartSeconds =
        reloadSeconds ?? (source.resumesAfterFailure ? source.startFromSeconds : nil)

      do {
        try audioSession.activate()
        audioSessionIsActive = true
      } catch {
        Task { @MainActor [weak self] in
          self?.reportFailure(
            PutioPlayerError(avPlayerError: error), generation: playbackGeneration)
        }
        return false
      }

      let requestedStart = reloadSeconds ?? (seeksToStart ? source.startFromSeconds : 0)
      guard requestedStart > 0 else {
        positionEstablished = true
        positionReporter.positionEstablished()
        settleControls(.position, generation: playbackGeneration)
        driver.play()
        return true
      }

      let loadDuration = loadDuration
      Task { @MainActor [weak self] in
        let duration = await loadDuration(item)
        guard let self, generation == playbackGeneration, self.driver === driver,
          !failureReported
        else { return }
        let startSeconds =
          reloadSeconds
          ?? (source.resumesAfterFailure
            ? source.startFromSeconds
            : PutioPlaybackProgress.startSeconds(
              savedSeconds: source.startFromSeconds, durationSeconds: duration))
        guard startSeconds > 0 else {
          positionEstablished = true
          positionReporter.positionEstablished()
          positionReporter.startReporting()
          settleControls(.position, generation: playbackGeneration)
          driver.play()
          return
        }
        seek(driver, to: startSeconds, reporter: positionReporter, generation: playbackGeneration)
      }
      return true
    }

    private func seek(
      _ driver: any PutioVideoPlayerDriving, to startSeconds: Int,
      reporter positionReporter: PutioVideoPositionReporter, generation playbackGeneration: UInt64
    ) {
      let startTime = CMTime(seconds: Double(startSeconds), preferredTimescale: 600)
      driver.seek(to: startTime) { [weak self] finished in
        Task { @MainActor [weak self] in
          guard let self, generation == playbackGeneration, self.driver === driver else { return }
          guard !failureReported else { return }
          guard finished else {
            reportFailure(
              PutioPlayerError(avPlayerError: driver.player.currentItem?.error),
              generation: playbackGeneration)
            return
          }
          positionEstablished = true
          positionReporter.positionEstablished()
          positionReporter.startReporting()
          settleControls(.position, generation: playbackGeneration)
          driver.play()
        }
      }
    }

    public static func duration(of item: AVPlayerItem) async -> Double? {
      guard let duration = try? await item.asset.load(.duration), duration.isNumeric else {
        return nil
      }
      return CMTimeGetSeconds(duration)
    }

    private func savePosition(generation playbackGeneration: UInt64) {
      guard generation == playbackGeneration else { return }
      positionReporter?.savePosition()
    }

    public func reload(restoring tracks: PutioVideoTrackSelection? = nil) {
      guard let driver, let reloadAt else { return }
      let seconds = PutioVideoPositionReporter.normalizedPosition(
        seconds: CMTimeGetSeconds(driver.currentTime))
      reloadAt(seconds, tracks)
    }

    private func restoreTracksOnce(
      _ tracks: PutioVideoTrackSelection, to item: AVPlayerItem,
      generation playbackGeneration: UInt64
    ) async {
      guard generation == playbackGeneration, !defaultSubtitleRequested else { return }
      defaultSubtitleRequested = true
      await restoreTracks(tracks, item)
      settleControls(.defaultSubtitle, generation: playbackGeneration)
    }

    public static func restore(_ tracks: PutioVideoTrackSelection, in item: AVPlayerItem) async {
      await PutioVideoTracks.restore(tracks, in: item)
    }

    public func stop(surface: any PutioVideoPlayerSurface) {
      let stoppedDriver = driver
      positionReporter?.stop()
      positionReporter = nil
      generation &+= 1
      statusObservation?.invalidate()
      statusObservation = nil
      if let positionObservation, let stoppedDriver {
        stoppedDriver.removePositionObservation(positionObservation)
        self.positionObservation = nil
      }
      if let failedToEndObservation {
        notificationCenter.removeObserver(failedToEndObservation)
        self.failedToEndObservation = nil
      }
      if let playedToEndObservation {
        notificationCenter.removeObserver(playedToEndObservation)
        self.playedToEndObservation = nil
      }
      if let timeJumpedObservation {
        notificationCenter.removeObserver(timeJumpedObservation)
        self.timeJumpedObservation = nil
      }
      if let mediaSelectionObservation {
        notificationCenter.removeObserver(mediaSelectionObservation)
        self.mediaSelectionObservation = nil
      }
      for observation in positionSaveObservations {
        notificationCenter.removeObserver(observation)
      }
      positionSaveObservations = []
      subtitleTextProbe = nil
      onReady = nil
      onPositionChanged = nil
      onPlaybackEnded = nil
      onPlaybackRestarted = nil
      onFailure = nil
      stoppedDriver?.stop()
      driver = nil
      surface.player = nil
      self.surface = nil
      if audioSessionIsActive {
        audioSession.deactivate()
        audioSessionIsActive = false
      }
    }

    public func waitForPendingPositionReports() async {
      guard let fileID else { return }
      await positionPipeline.waitForPendingReports(fileID: fileID)
    }

    private func reportFailure(
      _ error: PutioPlayerError, generation playbackGeneration: UInt64
    ) {
      guard generation == playbackGeneration, !failureReported else { return }
      failureReported = true
      let playingSeconds = driver.flatMap {
        PutioVideoPositionReporter.normalizedPosition(seconds: CMTimeGetSeconds($0.currentTime))
      }
      let heldSeconds = positionEstablished ? playingSeconds : recoveredStartSeconds
      positionReporter?.playbackFailed()
      onFailure?(
        PutioVideoPlayerFailure(
          error: error, heldSeconds: heldSeconds,
          beforeFirstFrame: surface?.showsFirstFrame != true))
    }

    public static func selectAudio(preferring languages: [String], in item: AVPlayerItem) async {
      await PutioMediaSelection.selectAudio(preferring: languages, in: item)
    }

    private func applyDefaultSubtitleOnce(
      to item: AVPlayerItem,
      generation playbackGeneration: UInt64
    ) {
      guard generation == playbackGeneration, !defaultSubtitleRequested else { return }
      defaultSubtitleRequested = true
      let applyDefaultSubtitle = applyDefaultSubtitle
      Task { @MainActor [weak self] in
        await applyDefaultSubtitle(item)
        guard let self, generation == playbackGeneration else { return }
        settleControls(.defaultSubtitle, generation: playbackGeneration)
        reportMediaSelection(for: item, generation: playbackGeneration)
      }
    }

    private func settleControls(_ gate: ControlGate, generation playbackGeneration: UInt64) {
      guard generation == playbackGeneration else { return }
      pendingControlGates.remove(gate)
      guard pendingControlGates.isEmpty else { return }
      surface?.showsPlaybackControls = true
    }

    public static func selectDefaultSubtitle(in item: AVPlayerItem) async {
      await selectStartSubtitle(in: item, policy: .accountDefault, remembered: nil)
    }

    public static func selectStartSubtitle(
      in item: AVPlayerItem, policy: PutioSubtitleStartupPolicy,
      remembered: PutioRememberedSubtitle?
    ) async {
      await PutioVideoTracks.selectStartSubtitle(in: item, policy: policy, remembered: remembered)
    }

    /// Publishes the audible and legible options in effect so the journey can
    /// assert language picks without reaching into AVFoundation.
    private func reportMediaSelection(
      for item: AVPlayerItem, generation playbackGeneration: UInt64
    ) {
      guard generation == playbackGeneration, observesPlaybackState else { return }
      if onAudioSelected != nil {
        let selectedAudioLanguage = selectedAudioLanguage
        Task { @MainActor [weak self] in
          guard let language = await selectedAudioLanguage(item) else { return }
          // A newer playback may have started during the load; its language is
          // reported by its own call.
          guard let self, generation == playbackGeneration, let onAudioSelected else { return }
          onAudioSelected(language)
        }
      }
      if onSubtitleSelected != nil {
        Task { @MainActor [weak self] in
          let subtitle = await PutioMediaSelection.selectedSubtitle(in: item)
          guard let self, generation == playbackGeneration, let onSubtitleSelected else { return }
          onSubtitleSelected(subtitle)
        }
      }
    }

    public static func selectedAudioLanguage(in item: AVPlayerItem) async -> String? {
      await PutioMediaSelection.selectedAudioLanguage(in: item)
    }

    private func reportReady(generation playbackGeneration: UInt64) {
      guard generation == playbackGeneration, !readyReported, !failureReported else { return }
      readyReported = true
      positionReporter?.ready()
      if let duration = driver?.itemDuration, duration.isValid, duration.isNumeric {
        onDurationKnown?(CMTimeGetSeconds(duration))
      }
      onReady?()
    }

    private func reportPlaybackEnded(generation playbackGeneration: UInt64) {
      guard
        generation == playbackGeneration,
        readyReported,
        !failureReported,
        positionReporter?.playbackEnded() == true
      else { return }
      onPlaybackEnded?()
    }

    /// A time jump after EOF is a restart only when playback actually moved
    /// back into the item. HLS discontinuities at the end jump to the duration,
    /// and treating those as a restart would save a stale position over the end.
    private func reportPlaybackRestarted(generation playbackGeneration: UInt64) {
      guard
        generation == playbackGeneration, let driver, let positionReporter,
        positionReporter.hasReportedFinalPosition
      else { return }
      guard !Self.isAtItemEnd(position: driver.currentTime, duration: driver.itemDuration) else {
        return
      }
      guard positionReporter.playbackRestarted() else { return }
      onPlaybackRestarted?()
    }

    private static func isAtItemEnd(position: CMTime, duration: CMTime) -> Bool {
      guard duration.isValid, duration.isNumeric else { return false }
      return PutioVideoPositionReporter.isAtEnd(
        positionSeconds: CMTimeGetSeconds(position), durationSeconds: CMTimeGetSeconds(duration))
    }
  }

  @MainActor
  private final class PutioSubtitleTextProbe: NSObject, AVPlayerItemLegibleOutputPushDelegate {
    private let output = AVPlayerItemLegibleOutput()
    private let onText: @MainActor @Sendable (String) -> Void

    init(onText: @escaping @MainActor @Sendable (String) -> Void) {
      self.onText = onText
      super.init()
      output.setDelegate(self, queue: .main)
    }

    func attach(to item: AVPlayerItem) {
      item.add(output)
    }

    nonisolated func legibleOutput(
      _ output: AVPlayerItemLegibleOutput,
      didOutputAttributedStrings strings: [NSAttributedString],
      nativeSampleBuffers nativeSamples: [Any], forItemTime itemTime: CMTime
    ) {
      let text = strings.map(\.string).joined(separator: "\n")
      MainActor.assumeIsolated { onText(text.isEmpty ? "none" : text) }
    }
  }
#endif
