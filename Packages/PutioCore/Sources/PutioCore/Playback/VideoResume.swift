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

public enum PutioVideoStart {
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
    case .startOver: PutioPlaybackSource(url: source.url, startFromSeconds: 0)
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
