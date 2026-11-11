import Foundation

enum PutioBrowserErrorKind: Hashable, Sendable {
  case notFound
  case rateLimited
  case transient
  case invalidResponse
  case unknown
}

public struct PutioBrowserErrorPresentation: Equatable, Sendable {
  let kind: PutioBrowserErrorKind
  public let title: String
  public let message: String

  public init?(error: Error) {
    switch error as? PutioRuntimeError {
    case .authenticationRequired, .sessionExpired:
      return nil
    case .notFound:
      self.init(
        kind: .notFound,
        title: String(localized: "Folder not found", bundle: .module),
        message: String(localized: "It may have been moved or deleted.", bundle: .module)
      )
    case .rateLimited:
      self.init(
        kind: .rateLimited,
        title: String(localized: "Could not load files", bundle: .module),
        message: String(
          localized: "put.io is receiving too many requests. Try again shortly.", bundle: .module)
      )
    case .transient:
      self.init(
        kind: .transient,
        title: String(localized: "Could not load files", bundle: .module),
        message: String(localized: "Check your connection and try again.", bundle: .module)
      )
    case .invalidResponse:
      self.init(
        kind: .invalidResponse,
        title: String(localized: "Could not load files", bundle: .module),
        message: String(
          localized: "put.io returned an invalid response. Try again.", bundle: .module)
      )
    case .unknown, nil:
      self.init(
        kind: .unknown,
        title: String(localized: "Could not load files", bundle: .module),
        message: String(
          localized: "put.io could not complete the request. Try again.", bundle: .module)
      )
    }
  }

  private init(kind: PutioBrowserErrorKind, title: String, message: String) {
    self.kind = kind
    self.title = title
    self.message = message
  }
}
