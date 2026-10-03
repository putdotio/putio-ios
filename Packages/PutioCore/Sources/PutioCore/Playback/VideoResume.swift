import Foundation

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
    "Continue from \(Self.clockTime(positionSeconds))"
  }

  /// VoiceOver reads the position as a duration, not as clock digits.
  public var resumeAccessibilityLabel: String {
    let spoken = Duration.seconds(positionSeconds).formatted(
      .units(allowed: [.hours, .minutes, .seconds], width: .wide))
    return "Continue from \(spoken)"
  }

  public static let startOverTitle = "Start from the beginning"

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
