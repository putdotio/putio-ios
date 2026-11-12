import Foundation

enum PutioBrowserErrorKind: Hashable, Sendable {
  case notFound
  case forbidden
  case rateLimited
  case unavailable
  case offline
  case transient
  case invalidResponse
  case unknown
}

public struct PutioBrowserErrorPresentation: Equatable, Sendable {
  let kind: PutioBrowserErrorKind
  public let title: String
  public let message: String

  public var isOffline: Bool { kind == .offline }

  public init?(error: Error) {
    let kind: PutioBrowserErrorKind
    switch error as? PutioFolderLoadError {
    case .forbidden: kind = .forbidden
    case .unavailable: kind = .unavailable
    case .offline: kind = .offline
    case nil:
      switch error as? PutioRuntimeError {
      case .authenticationRequired, .sessionExpired: return nil
      case .notFound: kind = .notFound
      case .rateLimited: kind = .rateLimited
      case .transient: kind = .transient
      case .invalidResponse: kind = .invalidResponse
      case .unknown, nil: kind = .unknown
      }
    }
    self.init(kind: kind)
  }

  private init(kind: PutioBrowserErrorKind) {
    self.kind = kind
    if kind == .notFound {
      title = String(localized: "Folder not found", bundle: .module)
      message = String(localized: "It may have been moved or deleted.", bundle: .module)
      return
    }
    #if os(tvOS)
      title = String(localized: "Could not load files", bundle: .module)
    #else
      title = (kind == .offline ? PutioScreenErrorKind.offline : .failed).title
    #endif
    message = Self.message(for: kind)
  }

  private static func message(for kind: PutioBrowserErrorKind) -> String {
    switch kind {
    case .notFound:
      String(localized: "It may have been moved or deleted.", bundle: .module)
    case .forbidden:
      String(localized: "You don’t have access to this folder.", bundle: .module)
    case .rateLimited:
      String(
        localized: "put.io is receiving too many requests. Try again shortly.", bundle: .module)
    case .unavailable:
      String(localized: "put.io is temporarily unavailable. Try again.", bundle: .module)
    case .offline:
      #if os(tvOS)
        PutioScreenErrorKind.failed.message
      #else
        PutioScreenErrorKind.offline.message
      #endif
    case .transient:
      PutioScreenErrorKind.failed.message
    case .invalidResponse:
      #if os(tvOS)
        String(localized: "put.io returned an invalid response. Try again.", bundle: .module)
      #else
        PutioScreenErrorKind.failed.message
      #endif
    case .unknown:
      #if os(tvOS)
        String(localized: "put.io could not complete the request. Try again.", bundle: .module)
      #else
        PutioScreenErrorKind.failed.message
      #endif
    }
  }
}
