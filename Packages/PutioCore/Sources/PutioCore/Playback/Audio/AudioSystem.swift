#if os(iOS) || os(tvOS) || os(macOS)
  import AVFoundation
  import Foundation
  import OSLog

  @MainActor
  public final class PutioSystemAudioEngine: PutioAudioEngine {
    private static let logger = Logger(subsystem: "io.put", category: "AudioPlayback")
    public var onReady: (@MainActor (_ startSeconds: Int) -> Void)?
    public var onEnded: (@MainActor () -> Void)?
    public var onFailed: (@MainActor () -> Void)?
    public var onPositionChanged: (@MainActor (Int) -> Void)?
    public var onPlayingChanged: (@MainActor (Bool) -> Void)?

    public let player = AVPlayer()
    private var statusObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?
    private var itemIsReady = false
    private var pendingStartSeconds = 0
    private var pendingRate: Float?
    private var startsExactly = false

    public init() {
      player.automaticallyWaitsToMinimizeStalling = true
    }

    public var durationSeconds: Int? {
      guard let duration = player.currentItem?.duration else { return nil }
      return Self.seconds(duration)
    }

    public func load(url: URL, startFromSeconds: Int) {
      load(url: url, startFromSeconds: startFromSeconds, exact: false)
    }

    public func load(url: URL, exactlyAt seconds: Int) {
      load(url: url, startFromSeconds: seconds, exact: true)
    }

    private func load(url: URL, startFromSeconds: Int, exact: Bool) {
      stopObserving()
      let item = AVPlayerItem(url: url)
      itemIsReady = false
      startsExactly = exact
      pendingStartSeconds = startFromSeconds
      pendingRate = nil
      player.replaceCurrentItem(with: item)
      statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
        Task { @MainActor [weak self] in
          guard let self, self.player.currentItem === item else { return }
          switch item.status {
          case .readyToPlay: self.handleReady()
          case .failed:
            self.reportFailure(item.error)
          default: break
          }
        }
      }
      endObserver = NotificationCenter.default.addObserver(
        forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          guard let self, self.player.currentItem === item else { return }
          self.onEnded?()
        }
      }
      failObserver = NotificationCenter.default.addObserver(
        forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main
      ) { [weak self] notification in
        let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
        Task { @MainActor [weak self] in
          guard let self, self.player.currentItem === item else { return }
          self.reportFailure(error ?? item.error)
        }
      }
      timeObserver = player.addPeriodicTimeObserver(
        forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
      ) { [weak self] time in
        Task { @MainActor [weak self] in
          guard let self, self.player.currentItem === item, let seconds = Self.seconds(time) else {
            return
          }
          self.onPositionChanged?(seconds)
        }
      }
    }

    /// Playback starts once the item is ready and any saved position has been
    /// sought, so the first audible frame is the resumed one.
    public func play(rate: Float) {
      guard itemIsReady else {
        pendingRate = rate
        return
      }
      player.playImmediately(atRate: rate)
    }

    public func pause() {
      pendingRate = nil
      player.pause()
    }

    public func seek(to seconds: Int) {
      player.seek(
        to: CMTime(seconds: Double(seconds), preferredTimescale: 600),
        toleranceBefore: .zero, toleranceAfter: .zero)
    }

    public func setRate(_ rate: Float) {
      guard itemIsReady else {
        pendingRate = rate
        return
      }
      player.rate = rate
    }

    private func handleReady() {
      guard !itemIsReady else { return }
      itemIsReady = true
      let start =
        startsExactly
        ? pendingStartSeconds
        : PutioPlaybackProgress.startSeconds(
          savedSeconds: pendingStartSeconds,
          durationSeconds: player.currentItem.map { CMTimeGetSeconds($0.duration) })
      pendingStartSeconds = 0
      let begin: @MainActor () -> Void = { [weak self] in
        guard let self else { return }
        if let rate = self.pendingRate {
          self.pendingRate = nil
          self.player.playImmediately(atRate: rate)
        }
        self.onReady?(start)
      }
      guard start > 0 else {
        begin()
        return
      }
      let item = player.currentItem
      player.seek(
        to: CMTime(seconds: Double(start), preferredTimescale: 600),
        toleranceBefore: .zero, toleranceAfter: .zero
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          guard let self, self.player.currentItem === item else { return }
          begin()
        }
      }
    }

    public func stop() {
      stopObserving()
      player.pause()
      player.replaceCurrentItem(with: nil)
    }

    private func stopObserving() {
      statusObservation?.invalidate()
      statusObservation = nil
      if let timeObserver {
        player.removeTimeObserver(timeObserver)
        self.timeObserver = nil
      }
      for observer in [endObserver, failObserver].compactMap({ $0 }) {
        NotificationCenter.default.removeObserver(observer)
      }
      endObserver = nil
      failObserver = nil
    }

    private func reportFailure(_ error: Error?) {
      var cause = error.map { $0 as NSError }
      if cause == nil {
        Self.logger.error("Audio playback failed without an underlying error")
      }
      // Error descriptions and userInfo can contain signed media URLs.
      for depth in 0..<4 {
        guard let current = cause else { break }
        Self.logger.error(
          "Audio playback failed: depth=\(depth) domain=\(current.domain, privacy: .public) code=\(current.code)"
        )
        cause = current.userInfo[NSUnderlyingErrorKey] as? NSError
      }
      onFailed?()
    }

    private static func seconds(_ time: CMTime) -> Int? {
      guard time.isValid, time.isNumeric else { return nil }
      let seconds = CMTimeGetSeconds(time)
      guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return nil }
      return Int(seconds.rounded(.down))
    }
  }
#endif

#if os(iOS) || os(tvOS)
  import UIKit

  @MainActor
  public final class PutioSystemAudioSession: PutioAudioSessioning {
    public init() {}

    public func activate() throws {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .default)
      try session.setActive(true)
    }

    public func deactivate() {
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
  }

  @MainActor
  public final class PutioSystemAudioSessionEvents: PutioAudioSessionEvents {
    private let notificationCenter: NotificationCenter
    private var observers: [NSObjectProtocol] = []

    public init(notificationCenter: NotificationCenter = .default) {
      self.notificationCenter = notificationCenter
    }

    public func start(_ handler: @escaping @MainActor (PutioAudioSessionEvent) -> Void) {
      stop()
      observers = [
        notificationCenter.addObserver(
          forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { notification in
          let event = Self.interruption(notification.userInfo)
          Task { @MainActor in event.map(handler) }
        },
        notificationCenter.addObserver(
          forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { notification in
          let event = Self.routeChange(notification.userInfo)
          Task { @MainActor in event.map(handler) }
        },
        notificationCenter.addObserver(
          forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { _ in
          MainActor.assumeIsolated { handler(.enteredBackground) }
        },
      ]
    }

    public func stop() {
      for observer in observers { notificationCenter.removeObserver(observer) }
      observers = []
    }

    nonisolated static func interruption(_ info: [AnyHashable: Any]?) -> PutioAudioSessionEvent? {
      guard let raw = info?[AVAudioSessionInterruptionTypeKey] as? UInt,
        let type = AVAudioSession.InterruptionType(rawValue: raw)
      else { return nil }
      switch type {
      case .began:
        return .interruptionBegan
      case .ended:
        let options =
          (info?[AVAudioSessionInterruptionOptionKey] as? UInt)
          .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
        return .interruptionEnded(shouldResume: options.contains(.shouldResume))
      @unknown default:
        return nil
      }
    }

    nonisolated static func routeChange(_ info: [AnyHashable: Any]?) -> PutioAudioSessionEvent? {
      guard let raw = info?[AVAudioSessionRouteChangeReasonKey] as? UInt,
        AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable
      else { return nil }
      return .outputLost
    }
  }
#endif
