import Foundation

extension PutioVideoPlaybackFailure {
  public enum Recovery: Equatable, Sendable {
    case retry
    case reconnect
    case convertAgain
    case checkConversionAgain
    case playElsewhere

    public static let tryAgainTitle = String(localized: "Try again", bundle: .module)
    public static let convertAgainTitle = String(localized: "Convert again", bundle: .module)
  }

  /// What a failed screen offers. A file this device can't play goes to
  /// another player; every other failure loads the video again.
  public var recovery: Recovery {
    switch kind {
    case .accessExpired, .connectionLost: .reconnect
    case .conversion: .convertAgain
    case .conversionStatus: .checkConversionAgain
    case .conversionUnavailable, .unsupported: .playElsewhere
    case .notFound, .rateLimited, .transient, .invalidResponse, .playback, .unknown: .retry
    }
  }
}

public enum PutioVideoConversionPhase: Equatable, Sendable {
  case waiting
  case converting(progress: Double)

  public var title: String {
    switch self {
    case .waiting: String(localized: "Waiting to convert", bundle: .module)
    case .converting: String(localized: "Converting to MP4", bundle: .module)
    }
  }
}

extension PutioVideoPlaybackState {
  /// A finished conversion stays full until the converted copy loads.
  public var conversionPhase: PutioVideoConversionPhase? {
    switch self {
    case .conversionRequired, .conversionQueued: .waiting
    case .converting(let progress): .converting(progress: progress)
    case .conversionCompleted: .converting(progress: 1)
    case .loading, .ready, .failed: nil
    }
  }
}

extension PutioVideoWait {
  public static let stalledTitle = String(localized: "Playback stalled", bundle: .module)
}

public enum PutioWebLinks {
  public static func file(_ id: PutioFileID) -> URL {
    URL(string: "https://app.put.io/files/\(id.rawValue)")!
  }
}
