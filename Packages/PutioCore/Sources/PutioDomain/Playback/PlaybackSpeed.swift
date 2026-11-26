import Foundation

/// Speeds the current app exposes. The chosen rate persists across launches
/// and applies to every track without asking again.
public enum PutioAudioSpeed: Float, CaseIterable, Sendable {
  case quarter = 0.25
  case half = 0.5
  case slower = 0.75
  case normal = 1
  case faster = 1.25
  case fast = 1.5
  case double = 2
  case doubleAndHalf = 2.5
  case triple = 3
  case tripleAndHalf = 3.5
  case quadruple = 4

  /// The tvOS speed menu, slowest first.
  public static let tvMenu: [PutioAudioSpeed] = [
    .quarter, .half, .slower, .normal, .faster, .fast, .double, .triple, .quadruple,
  ]

  /// Locale-independent so the label, identifier, and persisted value agree.
  public var title: String {
    "\(identifier)×"
  }

  public var identifier: String {
    let value = Double(rawValue)
    return value == value.rounded() ? String(Int(value)) : String(value)
  }
}

/// The last chosen speed, one key for audio and one for video, so every
/// platform starts the next playback at it.
@MainActor
public final class PutioAudioSpeedStore {
  public static let audioKey = "putio.audio.playback-speed"
  public static let videoKey = "putio.video.playback-speed"
  private let defaults: UserDefaults
  private let key: String

  public init(defaults: UserDefaults = .standard, key: String = audioKey) {
    self.defaults = defaults
    self.key = key
  }

  public func load() -> PutioAudioSpeed {
    guard defaults.object(forKey: key) != nil else { return .normal }
    return PutioAudioSpeed(rawValue: defaults.float(forKey: key)) ?? .normal
  }

  public func save(_ speed: PutioAudioSpeed) {
    defaults.set(speed.rawValue, forKey: key)
  }
}
