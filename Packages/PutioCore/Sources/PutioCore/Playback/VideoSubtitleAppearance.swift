import Foundation

public enum PutioSubtitleTextSize: String, CaseIterable, Identifiable, Sendable {
  case small
  case medium
  case large
  case extraLarge

  public var id: Self { self }

  public var scale: Double {
    switch self {
    case .small: 0.75
    case .medium: 1
    case .large: 1.25
    case .extraLarge: 1.5
    }
  }

  public var title: String {
    switch self {
    case .small: String(localized: "Small", bundle: .module)
    case .medium: String(localized: "Medium", bundle: .module)
    case .large: String(localized: "Large", bundle: .module)
    case .extraLarge: String(localized: "Extra large", bundle: .module)
    }
  }
}

public struct PutioSubtitleTiming: Equatable, Sendable {
  public static let limitSeconds: Double = 10
  public static let limitTenths = 100

  public private(set) var tenths = 0

  public init() {}

  public var seconds: Double { Double(tenths) / 10 }

  public mutating func moveEarlier() {
    tenths = max(tenths - 1, -Self.limitTenths)
  }

  public mutating func moveLater() {
    tenths = min(tenths + 1, Self.limitTenths)
  }

  public mutating func reset() {
    tenths = 0
  }

  public var text: String {
    let magnitude = "\(abs(tenths) / 10).\(abs(tenths) % 10) s"
    if tenths > 0 { return "+" + magnitude }
    if tenths < 0 { return "\u{2212}" + magnitude }
    return magnitude
  }
}

public struct PutioSubtitleChanges<Cue: Sendable>: Sendable {
  private var changes: [(time: Double, cues: [Cue])] = []

  public init() {}

  public mutating func record(_ cues: [Cue], at time: Double) {
    guard time.isFinite else { return }
    if let index = changes.firstIndex(where: { $0.time >= time }) {
      changes.removeSubrange(index...)
    }
    changes.append((time, cues))
  }

  public mutating func removeAll() {
    changes.removeAll()
  }

  public func cues(at time: Double, offset: Double) -> [Cue] {
    let shifted = time - offset
    return changes.last { $0.time <= shifted }?.cues ?? []
  }

  public mutating func forget(before time: Double) {
    let kept = changes.lastIndex { $0.time <= time }
    guard let kept, kept > 0 else { return }
    changes.removeSubrange(..<kept)
  }
}

@MainActor
public final class PutioSubtitleSizeMemory {
  public static let key = "putio.video.subtitle-size"
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  public var size: PutioSubtitleTextSize {
    get { defaults.string(forKey: Self.key).flatMap(PutioSubtitleTextSize.init) ?? .medium }
    set { defaults.set(newValue.rawValue, forKey: Self.key) }
  }
}
