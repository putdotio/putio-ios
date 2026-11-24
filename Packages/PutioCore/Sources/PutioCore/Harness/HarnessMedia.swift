import Foundation

public enum HarnessMediaServer {
  public static let environmentKey = "PUTIO_HARNESS_MEDIA_BASE_URL"

  public static func baseURL(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL? {
    guard let raw = environment[environmentKey], let url = URL(string: raw),
      url.scheme == "http", url.host == "127.0.0.1"
    else { return nil }
    return url
  }
}

public struct HarnessConversionHistory: Equatable, Sendable {
  public private(set) var phases: [String] = []

  public init() {}

  public mutating func record(_ state: PutioVideoPlaybackState) {
    let phase: String
    switch state {
    case .conversionQueued: phase = "queued"
    case .converting: phase = "converting"
    case .conversionCompleted: phase = "completed"
    case .loading, .ready, .conversionRequired, .failed: return
    }
    guard phases.last != phase else { return }
    phases.append(phase)
  }

  public var value: String? {
    phases.isEmpty ? nil : phases.joined(separator: ",")
  }
}
