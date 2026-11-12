import Foundation
import Observation

public struct PutioPublicLink: Identifiable, Hashable, Sendable {
  public let id: Int
  public let fileName: String
  public let kind: PutioFileKind
  public let expiresAt: Date?
  public let url: URL

  public init(id: Int, fileName: String, kind: PutioFileKind, expiresAt: Date?, url: URL) {
    self.id = id
    self.fileName = fileName
    self.kind = kind
    self.expiresAt = expiresAt
    self.url = url
  }

  static let baseURL = "https://app.put.io/exclusive-access/"
  private static let tokenCharacters = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

  static func url(token: String) -> URL? {
    guard !token.isEmpty,
      let segment = token.addingPercentEncoding(withAllowedCharacters: tokenCharacters)
    else { return nil }
    return URL(string: baseURL + segment)
  }

  static func expiryDate(_ text: String) -> Date? {
    let pattern = /(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2}:\d{2})(\.\d+)?(Z|[+-]\d{2}:?\d{2})?/
    guard
      let match = text.trimmingCharacters(in: .whitespaces).wholeMatch(of: pattern),
      let whole = ISO8601DateFormatter().date(
        from: "\(match.1)T\(match.2)\(match.4.map(String.init) ?? "Z")")
    else { return nil }
    let fraction = match.3.flatMap { Double("0\($0)") } ?? 0
    return whole.addingTimeInterval(fraction)
  }

  public func isExpired(at now: Date) -> Bool {
    expiresAt.map { $0 <= now } ?? false
  }

  public func expiryText(at now: Date) -> String {
    guard let expiresAt else {
      return String(localized: "Expires within 72 hours", bundle: .module)
    }
    let hours = max(1, Int(max(0, expiresAt.timeIntervalSince(now)) / 3600))
    let remaining = String(localized: "\(hours) hours", bundle: .module)
    return String(localized: "Expires in \(remaining)", bundle: .module)
  }
}

public struct PutioPublicLinkActions: Sendable {
  let list: @MainActor @Sendable () async throws -> [PutioPublicLink]
  let revoke: @MainActor @Sendable (Int) async throws -> Void
  let now: @Sendable () -> Date

  public init(runtime: PutioRuntime) {
    list = { try await runtime.listPublicLinks() }
    revoke = { try await runtime.revokePublicLink(id: $0) }
    now = { .now }
  }

  init(
    list: @escaping @MainActor @Sendable () async throws -> [PutioPublicLink] = { [] },
    revoke: @escaping @MainActor @Sendable (Int) async throws -> Void = { _ in },
    now: @escaping @Sendable () -> Date = { .now }
  ) {
    self.list = list
    self.revoke = revoke
    self.now = now
  }
}

public enum PutioPublicLinkRevokeOutcome: Equatable, Sendable {
  case revoked
  case failed(String)
  case skipped
}

@MainActor
@Observable
public final class PutioPublicLinksModel {
  public enum State: Equatable {
    case loading
    case loaded([PutioPublicLink])
    case failed
  }

  public private(set) var state: State = .loading
  public private(set) var revokingID: Int?
  @ObservationIgnored private let actions: PutioPublicLinkActions
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var revokedIDs = Set<Int>()

  public init(actions: PutioPublicLinkActions) {
    self.actions = actions
  }

  public var links: [PutioPublicLink] {
    if case .loaded(let links) = state { return links }
    return []
  }

  public func links(at now: Date) -> [PutioPublicLink] {
    links.filter { !$0.isExpired(at: now) }
  }

  @discardableResult
  public func load() async -> Bool {
    generation += 1
    let generation = generation
    if case .failed = state { state = .loading }
    do {
      let loaded = try await actions.list()
      guard generation == self.generation, !Task.isCancelled else { return true }
      let now = actions.now()
      state = .loaded(loaded.filter { !$0.isExpired(at: now) && !revokedIDs.contains($0.id) })
      return true
    } catch {
      guard generation == self.generation, !Task.isCancelled,
        PutioAccountSecurityPresentation.message(for: error) != nil
      else { return true }
      if case .loaded = state { return false }
      state = .failed
      return true
    }
  }

  public func revoke(_ link: PutioPublicLink) async -> PutioPublicLinkRevokeOutcome {
    guard revokingID == nil, links.contains(where: { $0.id == link.id }) else { return .skipped }
    revokingID = link.id
    let task = Task { @MainActor in
      defer { revokingID = nil }
      let failure: Error?
      do {
        try await actions.revoke(link.id)
        failure = nil
      } catch {
        failure = error
      }
      if let failure, failure as? PutioRuntimeError != .notFound {
        guard let reason = PutioAccountSecurityPresentation.message(for: failure) else {
          return PutioPublicLinkRevokeOutcome.skipped
        }
        return .failed(
          String(localized: "Couldn’t revoke the link. \(reason)", bundle: .module))
      }
      revokedIDs.insert(link.id)
      state = .loaded(links.filter { $0.id != link.id })
      return .revoked
    }
    return await task.value
  }
}
