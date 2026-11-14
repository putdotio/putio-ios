import Foundation

public struct PutioVideoTimeline: Equatable, Sendable {
  public static let skipInterval: Double = 10

  public let elapsedSeconds: Double
  public let durationSeconds: Double?

  public init(elapsedSeconds: Double, durationSeconds: Double?) {
    let duration = durationSeconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    let elapsed = elapsedSeconds.isFinite ? max(elapsedSeconds, 0) : 0
    self.durationSeconds = duration
    self.elapsedSeconds = duration.map { min(elapsed, $0) } ?? elapsed
  }

  public var remainingSeconds: Double? {
    durationSeconds.map { max($0.rounded(.down) - elapsedSeconds.rounded(.down), 0) }
  }

  public var elapsedText: String {
    Self.clock(elapsedSeconds)
  }

  public var remainingText: String {
    remainingSeconds.map { "-" + Self.clock($0) } ?? "--:--"
  }

  public func target(skippingBy seconds: Double) -> Double {
    clamped(elapsedSeconds + seconds)
  }

  public func clamped(_ seconds: Double) -> Double {
    let lower = max(seconds.isFinite ? seconds : 0, 0)
    return durationSeconds.map { min(lower, $0) } ?? lower
  }

  public static func clock(_ seconds: Double) -> String {
    let total = seconds.isFinite ? Int(max(seconds, 0).rounded(.down)) : 0
    let hours = total / 3600
    let minutes = total % 3600 / 60
    let remainder = total % 60
    guard hours > 0 else { return "\(minutes):\(twoDigits(remainder))" }
    return "\(hours):\(twoDigits(minutes)):\(twoDigits(remainder))"
  }

  private static func twoDigits(_ value: Int) -> String {
    value < 10 ? "0\(value)" : "\(value)"
  }
}

public struct PutioVideoPlayhead: Equatable, Sendable {
  public private(set) var timeline = PutioVideoTimeline(elapsedSeconds: 0, durationSeconds: nil)
  private var seeks: UInt64 = 0
  private var pendingSeek: UInt64?

  public init() {}

  public mutating func seekStarted(to seconds: Double) -> UInt64 {
    timeline = PutioVideoTimeline(
      elapsedSeconds: timeline.clamped(seconds), durationSeconds: timeline.durationSeconds)
    seeks &+= 1
    pendingSeek = seeks
    return seeks
  }

  public mutating func seekFinished(_ seek: UInt64) {
    guard pendingSeek == seek else { return }
    pendingSeek = nil
  }

  public mutating func observed(elapsedSeconds: Double, durationSeconds: Double?) {
    timeline = PutioVideoTimeline(
      elapsedSeconds: pendingSeek == nil ? elapsedSeconds : timeline.elapsedSeconds,
      durationSeconds: durationSeconds)
  }
}

public struct PutioVideoControlsVisibility: Equatable, Sendable {
  public enum Pin: Hashable, Sendable {
    case voiceOver
    case scrubbing
    case menu
  }

  public static let idleDelay = Duration.seconds(3)

  public private(set) var isVisible = true
  public private(set) var idleGeneration: UInt64 = 0
  private var pins: Set<Pin> = []

  public init() {}

  public mutating func interacted() {
    isVisible = true
    idleGeneration &+= 1
  }

  public mutating func toggled() {
    if isVisible, pins.isEmpty {
      isVisible = false
    } else {
      interacted()
    }
  }

  public mutating func set(_ pin: Pin, _ pinned: Bool) {
    if pinned { pins.insert(pin) } else { pins.remove(pin) }
    interacted()
  }

  public mutating func idleElapsed(generation: UInt64, isPlaying: Bool) {
    guard generation == idleGeneration, isPlaying, pins.isEmpty else { return }
    isVisible = false
  }
}
