import Foundation
import Observation
import PutioCore

// Legacy navigation uses URL paths, including putio:///files/123. The URL host
// is never interpreted as a route, and authentication callbacks stay with ASWebAuthenticationSession.
enum PutioDeepLink: Equatable {
  case file(PutioFileID)
  case history
  case account
  case unavailable

  static func parse(_ url: URL) -> Self? {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let scheme = components.scheme?.lowercased(), ["putio", "https"].contains(scheme)
    else { return nil }
    let host = components.host?.lowercased() ?? ""
    guard (scheme == "putio" && host.isEmpty) || host == "put.io" || host.hasSuffix(".put.io")
    else { return nil }
    guard components.user == nil, components.password == nil, components.port == nil,
      components.query == nil, components.fragment == nil,
      components.percentEncodedPath == components.path
    else { return .unavailable }
    switch components.path {
    case "/history": return .history
    case "/account", "/settings": return .account
    default:
      let parts = components.path.split(separator: "/", omittingEmptySubsequences: false)
      guard parts.count == 3, parts[0].isEmpty, parts[1] == "files",
        !parts[2].isEmpty, parts[2].utf8.allSatisfy({ (48...57).contains($0) }),
        let id = Int(parts[2]), id >= 0
      else { return .unavailable }
      return .file(PutioFileID(rawValue: id))
    }
  }
}

enum PutioDeepLinkDestination: Equatable {
  case files([PutioFolderRoute], file: PutioFileRoute?)
  case history
  case account
}

enum PutioDeepLinkFailure: Error, Equatable {
  case unavailable
  case historyDisabled
  case missingFile
  case connection
  case invalidResponse

  var message: String {
    switch self {
    case .unavailable: String(localized: "This link cannot be opened in this app yet.")
    case .historyDisabled: String(localized: "History is turned off in your account settings.")
    case .missingFile: String(localized: "This item could not be found.")
    case .connection: String(localized: "Check your connection and try again.")
    case .invalidResponse: String(localized: "put.io returned an invalid response. Try again.")
    }
  }

  var canRetry: Bool {
    switch self {
    case .missingFile, .connection, .invalidResponse: true
    default: false
    }
  }
}

@MainActor
@Observable
final class PutioDeepLinkModel {
  private(set) var revision: UInt64 = 0
  private(set) var accountID: Int?
  private(set) var pending: PutioDeepLink?
  private(set) var destination: PutioDeepLinkDestination?
  private(set) var failure: PutioDeepLinkFailure?
  private(set) var isLoading = false
  private var boundAccountID: Int?

  struct Request: Equatable {
    let revision: UInt64
    let accountID: Int?
  }

  var request: Request { Request(revision: revision, accountID: accountID) }
  var presentsStatus: Bool { isLoading || failure != nil }

  func receive(_ url: URL) {
    guard let link = PutioDeepLink.parse(url) else { return }
    cancel()
    pending = link
    boundAccountID = accountID
    if link == .unavailable { failure = .unavailable }
  }

  func updateSession(_ state: PutioSessionState) {
    switch state {
    case .signedIn(let account):
      if let boundAccountID, boundAccountID != account.id { cancel() }
      accountID = account.id
    case .signingOut, .signOutFailed:
      cancel()
      accountID = nil
    case .unknown, .authenticating, .signedOut:
      if boundAccountID != nil { cancel() }
      accountID = nil
    }
  }

  func resolve(
    historyEnabled: Bool,
    file: @MainActor @Sendable (PutioFileID) async throws -> PutioFileItem
  ) async {
    guard let pending, pending != .unavailable, let accountID, !isLoading, failure == nil else {
      return
    }
    boundAccountID = accountID
    let request = self.request
    isLoading = true
    defer { if request == self.request { isLoading = false } }
    do {
      let resolved: PutioDeepLinkDestination
      switch pending {
      case .account: resolved = .account
      case .history:
        guard historyEnabled else { throw PutioDeepLinkFailure.historyDisabled }
        resolved = .history
      case .file(let id): resolved = try await Self.resolveFile(id, file: file)
      case .unavailable: throw PutioDeepLinkFailure.unavailable
      }
      try Task.checkCancellation()
      guard request == self.request else { return }
      destination = resolved
      self.pending = nil
    } catch {
      if Task.isCancelled || error is CancellationError {
        // SwiftUI restarts the owning task on view identity changes, which
        // cancels this run without changing the request. The link is still
        // pending, so a new revision makes the task fire again.
        if request == self.request, self.pending != nil {
          isLoading = false
          revision &+= 1
        }
        return
      }
      guard request == self.request else { return }
      if let failure = error as? PutioDeepLinkFailure {
        self.failure = failure
      } else {
        switch error as? PutioRuntimeError {
        case .authenticationRequired, .sessionExpired: cancel()
        case .notFound: failure = .missingFile
        case .invalidResponse: failure = .invalidResponse
        default: failure = .connection
        }
      }
    }
  }

  func retry() {
    guard failure?.canRetry == true, pending != nil else { return }
    revision &+= 1
    failure = nil
  }

  func consumeDestination() { destination = nil }

  func cancel() {
    revision &+= 1
    pending = nil
    destination = nil
    failure = nil
    isLoading = false
    boundAccountID = nil
  }

  private static func resolveFile(
    _ id: PutioFileID,
    file: @MainActor @Sendable (PutioFileID) async throws -> PutioFileItem
  ) async throws -> PutioDeepLinkDestination {
    if id == .root { return .files([], file: nil) }
    let item = try await file(id)
    guard item.id == id else { throw PutioDeepLinkFailure.invalidResponse }
    var path: [PutioFolderRoute] = []
    var current = item
    var seen: Set<PutioFileID> = []
    while true {
      try Task.checkCancellation()
      guard seen.insert(current.id).inserted, current.parentID.rawValue >= 0
      else {
        throw PutioDeepLinkFailure.invalidResponse
      }
      if current.kind == .folder {
        path.insert(PutioFolderRoute(id: current.id, title: current.name), at: 0)
      } else if current.id != item.id {
        throw PutioDeepLinkFailure.invalidResponse
      }
      if current.parentID == .root { break }
      let parent = try await file(current.parentID)
      guard parent.id == current.parentID, parent.kind == .folder else {
        throw PutioDeepLinkFailure.invalidResponse
      }
      current = parent
    }
    return .files(path, file: item.kind == .folder ? nil : PutioFileRoute(item: item))
  }
}

struct PutioFilesNavigationRequest: Equatable {
  let id = UUID()
  let path: [PutioFolderRoute]
}
