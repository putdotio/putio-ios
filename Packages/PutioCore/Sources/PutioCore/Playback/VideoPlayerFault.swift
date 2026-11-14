import Foundation

public enum PutioVideoPlayerFault: String, Equatable, Sendable {
  case accessExpired
  case connectionLost
  case playback

  public init(error: Error?) {
    let chain = Self.chain(from: error.map { $0 as NSError })
    if chain.contains(where: Self.isForbidden) {
      self = .accessExpired
    } else if chain.contains(where: Self.isTransportFailure) {
      self = .connectionLost
    } else {
      self = .playback
    }
  }

  private static func chain(from error: NSError?) -> [NSError] {
    var errors: [NSError] = []
    var current = error
    while let error = current, errors.count < 8 {
      errors.append(error)
      current = error.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    return errors
  }

  static let coreMediaDomain = "CoreMediaErrorDomain"
  static let httpForbidden = -12660

  private static func isForbidden(_ error: NSError) -> Bool {
    error.domain == coreMediaDomain && error.code == httpForbidden
  }

  private static let transportCodes: Set<Int> = [
    NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
    NSURLErrorNetworkConnectionLost, NSURLErrorDNSLookupFailed, NSURLErrorNotConnectedToInternet,
    NSURLErrorInternationalRoamingOff, NSURLErrorDataNotAllowed,
  ]

  private static func isTransportFailure(_ error: NSError) -> Bool {
    (error.domain == NSURLErrorDomain || error.domain == "kCFErrorDomainCFNetwork")
      && transportCodes.contains(error.code)
  }
}
