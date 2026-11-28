import Foundation
import Observation

/// The pre-play decision between the saved position and the start, shown
/// before the system player opens. It exists only while the account
/// remembers positions and the video has a duration and a saved position
/// short of the watched mark, the same trigger as every TV tier.
public struct PutioVideoResumePrompt: Equatable, Sendable {
  public enum Choice: Equatable, Sendable {
    case resume
    case startOver
  }

  public let positionSeconds: Int
  public let durationSeconds: Double

  public init?(startFromSeconds: Int, durationSeconds: Double?, remembersPosition: Bool) {
    guard
      PutioVideoStart.asksWhereToStart(
        savedSeconds: startFromSeconds, durationSeconds: durationSeconds,
        remembersPosition: remembersPosition),
      let durationSeconds, durationSeconds.isFinite, durationSeconds > 0
    else { return nil }
    self.positionSeconds = startFromSeconds
    self.durationSeconds = durationSeconds
  }

  public func startSeconds(for choice: Choice) -> Int {
    switch choice {
    case .resume: positionSeconds
    case .startOver: 0
    }
  }

  /// The elapsed share the progress preview shows while `choice` has focus.
  public func progress(for choice: Choice) -> Double {
    min(Double(startSeconds(for: choice)) / durationSeconds, 1)
  }

  public static func question(positionSeconds: Int) -> String {
    String(
      localized: "Resume from \(PutioPlaybackClock.text(seconds: positionSeconds))?",
      bundle: .module)
  }

  /// VoiceOver reads the position as a duration, not as clock digits.
  public static func resumeAccessibilityLabel(positionSeconds: Int) -> String {
    String(
      localized: "Resume from \(PutioPlaybackClock.spoken(seconds: positionSeconds))",
      bundle: .module)
  }

  public static let resumeTitle = String(localized: "Resume", bundle: .module)
  public static let startOverTitle = String(localized: "Start over", bundle: .module)
}

/// Playback positions and lengths as the players and file details show
/// them: `M:SS` under an hour, `H:MM:SS` from an hour.
public enum PutioPlaybackClock {
  public static func text(seconds: Int) -> String {
    let total = max(seconds, 0)
    let hours = total / 3600
    let minutes = total % 3600 / 60
    let remainder = total % 60
    guard hours > 0 else { return "\(minutes):\(twoDigits(remainder))" }
    return "\(hours):\(twoDigits(minutes)):\(twoDigits(remainder))"
  }

  public static func text(_ seconds: Double) -> String {
    text(seconds: seconds.isFinite ? Int(max(seconds, 0).rounded(.down)) : 0)
  }

  public static func spoken(seconds: Int) -> String {
    Duration.seconds(max(seconds, 0)).formatted(
      .units(allowed: [.hours, .minutes, .seconds], width: .wide))
  }

  private static func twoDigits(_ value: Int) -> String {
    value < 10 ? "0\(value)" : "\(value)"
  }
}

public struct PutioVideoStartPoint: Equatable, Sendable {
  public let savedSeconds: Int
  public let durationSeconds: Double?
  public let needsConversion: Bool

  public init(savedSeconds: Int, durationSeconds: Double?, needsConversion: Bool) {
    self.savedSeconds = savedSeconds
    self.durationSeconds = durationSeconds
    self.needsConversion = needsConversion
  }
}

public enum PutioVideoRouteStart: Equatable, Sendable {
  case asksAfterConversion
  case asksInPlayer
  case chosen(PutioVideoResumePrompt.Choice)
  case resumes(atSeconds: Int)
}

public enum PutioVideoOpening: Equatable, Sendable {
  case show(PutioVideoRoute)
  case ask(positionSeconds: Int)
}

public enum PutioVideoStart {
  public static func opening(
    _ route: PutioVideoRoute, from start: PutioVideoStartPoint?, method: PutioPlaybackMethod,
    remembersPosition: Bool
  ) -> PutioVideoOpening {
    guard remembersPosition, let start else { return .show(route) }
    if start.needsConversion, method != .directPlay {
      return .show(route.starting(.asksInPlayer))
    }
    guard
      asksWhereToStart(
        savedSeconds: start.savedSeconds, durationSeconds: start.durationSeconds,
        remembersPosition: true)
    else { return .show(route) }
    return .ask(positionSeconds: start.savedSeconds)
  }

  public static func choice(
    for routeStart: PutioVideoRouteStart, remembersPosition: Bool,
    durationSeconds: @escaping @MainActor @Sendable (URL) async -> Double?,
    metadataDurationSeconds: @escaping @MainActor @Sendable () async -> Double? = { nil },
    ask:
      @escaping @MainActor @Sendable (_ positionSeconds: Int, _ durationSeconds: Double?) async
      -> PutioVideoResumePrompt.Choice?
  ) -> PutioVideoStartChoice {
    { source, afterConversion in
      switch routeStart {
      case .resumes(let seconds):
        return source.resuming(at: seconds)
      case .chosen(let choice):
        return Self.source(source, startingWith: choice)
      case .asksAfterConversion where !afterConversion:
        return source
      case .asksAfterConversion, .asksInPlayer:
        break
      }
      guard remembersPosition, source.startFromSeconds > 0 else { return source }
      var duration = await durationSeconds(source.url).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
      if duration == nil { duration = await metadataDurationSeconds() }
      guard !Task.isCancelled else { return source }
      guard
        asksWhereToStart(
          savedSeconds: source.startFromSeconds, durationSeconds: duration,
          remembersPosition: true)
      else { return source }
      let choice = await ask(source.startFromSeconds, duration)
      return Self.source(source, startingWith: choice ?? .resume)
    }
  }

  public static func asksWhereToStart(
    savedSeconds: Int, durationSeconds: Double?, remembersPosition: Bool
  ) -> Bool {
    guard remembersPosition, savedSeconds > 0 else { return false }
    return !PutioPlaybackProgress.isWatched(
      positionSeconds: savedSeconds, durationSeconds: durationSeconds)
  }

  public static func source(
    _ source: PutioPlaybackSource, startingWith choice: PutioVideoResumePrompt.Choice
  ) -> PutioPlaybackSource {
    switch choice {
    case .resume: source
    case .startOver: source.starting(at: 0)
    }
  }
}

@MainActor
@Observable
public final class PutioVideoResumePrompter {
  public private(set) var isAsking = false
  public private(set) var positionSeconds = 0
  /// Set when the length is known, for the progress preview.
  public private(set) var prompt: PutioVideoResumePrompt?
  @ObservationIgnored private var pending:
    (id: UInt64, continuation: CheckedContinuation<PutioVideoResumePrompt.Choice?, Never>)?
  @ObservationIgnored private var asked: UInt64 = 0

  public init() {}

  public func ask(
    positionSeconds: Int, durationSeconds: Double? = nil
  ) async -> PutioVideoResumePrompt.Choice? {
    let prompt = PutioVideoResumePrompt(
      startFromSeconds: positionSeconds, durationSeconds: durationSeconds, remembersPosition: true)
    answer(nil)
    asked &+= 1
    let id = asked
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard !Task.isCancelled else {
          continuation.resume(returning: nil)
          return
        }
        pending = (id, continuation)
        self.positionSeconds = positionSeconds
        self.prompt = prompt
        isAsking = true
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        guard let self, pending?.id == id else { return }
        answer(nil)
      }
    }
  }

  public func close() {
    isAsking = false
  }

  public func answer(_ choice: PutioVideoResumePrompt.Choice?) {
    isAsking = false
    let continuation = pending?.continuation
    pending = nil
    continuation?.resume(returning: choice)
  }
}
