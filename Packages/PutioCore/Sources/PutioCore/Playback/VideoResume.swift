import Foundation
import Observation

/// The pre-play decision between the saved position and the start, shown
/// before the system player opens. It exists only while the account
/// remembers positions and the video has both a duration and a saved
/// position, the same trigger as every TV tier.
public struct PutioVideoResumePrompt: Equatable, Sendable {
  public enum Choice: Equatable, Sendable {
    case resume
    case startOver
  }

  public let positionSeconds: Int
  public let durationSeconds: Double

  public init?(startFromSeconds: Int, durationSeconds: Double?, remembersPosition: Bool) {
    guard remembersPosition, startFromSeconds > 0,
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

  public var resumeTitle: String {
    String(localized: "Continue from \(Self.clockTime(positionSeconds))", bundle: .module)
  }

  /// VoiceOver reads the position as a duration, not as clock digits.
  public var resumeAccessibilityLabel: String {
    let spoken = Duration.seconds(positionSeconds).formatted(
      .units(allowed: [.hours, .minutes, .seconds], width: .wide))
    return String(localized: "Continue from \(spoken)", bundle: .module)
  }

  public static let startOverTitle = String(localized: "Start from the beginning", bundle: .module)

  /// `H:MM:SS`, hours unpadded.
  static func clockTime(_ seconds: Int) -> String {
    let hours = seconds / 3600
    let minutes = seconds % 3600 / 60
    let remainder = seconds % 60
    return "\(hours):\(twoDigits(minutes)):\(twoDigits(remainder))"
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
    ask: @escaping @MainActor @Sendable (Int) async -> PutioVideoResumePrompt.Choice?
  ) -> PutioVideoStartChoice {
    { source, afterConversion in
      switch routeStart {
      case .resumes(let seconds):
        return PutioPlaybackSource(
          url: source.url, startFromSeconds: seconds, resumesAfterFailure: true,
          original: source.original)
      case .chosen(let choice):
        return Self.source(source, startingWith: choice)
      case .asksAfterConversion where !afterConversion:
        return source
      case .asksAfterConversion, .asksInPlayer:
        break
      }
      guard remembersPosition, source.startFromSeconds > 0 else { return source }
      let duration = await durationSeconds(source.url)
      guard
        asksWhereToStart(
          savedSeconds: source.startFromSeconds, durationSeconds: duration,
          remembersPosition: true)
      else { return source }
      let choice = await ask(source.startFromSeconds)
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
  @ObservationIgnored private var pending:
    (id: UInt64, continuation: CheckedContinuation<PutioVideoResumePrompt.Choice?, Never>)?
  @ObservationIgnored private var asked: UInt64 = 0

  public init() {}

  public func ask(positionSeconds: Int) async -> PutioVideoResumePrompt.Choice? {
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
