import Foundation
import Observation

public struct PutioRecentSearches: Equatable, Sendable {
  public var enabled: Bool
  public var terms: [String]

  public init(enabled: Bool, terms: [String]) {
    self.enabled = enabled
    self.terms = terms
  }
}

public struct PutioRecentSearchActions: Sendable {
  let load: @MainActor @Sendable () async throws -> PutioRecentSearches
  let save: @MainActor @Sendable ([String]) async throws -> Void
  let session: @MainActor @Sendable () -> UInt64

  public init(runtime: PutioRuntime) {
    load = { try await runtime.recentSearches() }
    save = { try await runtime.setRecentSearches($0) }
    session = { runtime.session.authenticationGeneration }
  }

  init(
    load: @escaping @MainActor @Sendable () async throws -> PutioRecentSearches,
    save: @escaping @MainActor @Sendable ([String]) async throws -> Void,
    session: @escaping @MainActor @Sendable () -> UInt64 = { 0 }
  ) {
    self.load = load
    self.save = save
    self.session = session
  }
}

@MainActor
@Observable
public final class PutioRecentSearchesModel {
  public nonisolated static let limit = 5

  public private(set) var terms: [String] = []
  public private(set) var editFailure: UUID?

  @ObservationIgnored private var confirmed: PutioRecentSearches?
  @ObservationIgnored private var pending: [(id: UUID, edit: Edit)] = []
  @ObservationIgnored private var queue: Task<Void, Never>?
  @ObservationIgnored private let actions: PutioRecentSearchActions

  public init(actions: PutioRecentSearchActions) {
    self.actions = actions
  }

  public func clearEditFailure() { editFailure = nil }

  public func load() async {
    let owner = actions.session()
    await serially {
      guard self.actions.session() == owner, let stored = try? await self.actions.load(),
        self.actions.session() == owner
      else { return }
      self.confirmed = Self.normalized(stored)
      self.publish()
    }
  }

  public func record(_ query: String) async {
    let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !term.isEmpty else { return }
    await edit(.record(term))
  }

  public func remove(_ term: String) async {
    await edit(.remove(term))
  }

  public func clear() async {
    await edit(.clear)
  }

  private enum Edit {
    case record(String)
    case remove(String)
    case clear

    func applied(to terms: [String]) -> [String] {
      switch self {
      case .record(let term):
        Array(([term] + terms.filter { $0 != term }).prefix(PutioRecentSearchesModel.limit))
      case .remove(let term): terms.filter { $0 != term }
      case .clear: []
      }
    }
  }

  private func edit(_ edit: Edit) async {
    let id = UUID()
    let owner = actions.session()
    pending.append((id, edit))
    publish()
    await serially { await self.commit(edit, id: id, owner: owner) }
  }

  private func commit(_ edit: Edit, id: UUID, owner: UInt64) async {
    defer {
      pending.removeAll { $0.id == id }
      publish()
    }
    guard actions.session() == owner else { return }
    guard let loaded = try? await actions.load() else {
      if case .record = edit { return }
      editFailure = UUID()
      return
    }
    let stored = Self.normalized(loaded)
    confirmed = stored
    guard stored.enabled else { return }
    let next = edit.applied(to: stored.terms)
    guard next != stored.terms, actions.session() == owner else { return }
    do {
      try await actions.save(next)
      confirmed?.terms = next
    } catch {
      editFailure = UUID()
    }
  }

  private func publish() {
    guard let confirmed, confirmed.enabled else {
      terms = []
      return
    }
    terms = pending.reduce(confirmed.terms) { $1.edit.applied(to: $0) }
  }

  private func serially(_ operation: @escaping @MainActor () async -> Void) async {
    let previous = queue
    let task = Task { @MainActor in
      await previous?.value
      await operation()
    }
    queue = task
    await task.value
  }

  private static func normalized(_ stored: PutioRecentSearches) -> PutioRecentSearches {
    var seen = Set<String>()
    let terms = stored.terms
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty && seen.insert($0).inserted }
    return PutioRecentSearches(enabled: stored.enabled, terms: Array(terms.prefix(limit)))
  }
}
