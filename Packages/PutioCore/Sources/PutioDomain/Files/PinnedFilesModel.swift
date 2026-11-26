import Foundation
import Observation

public struct PutioPinnedFile: Identifiable, Hashable, Sendable {
  public let item: PutioFileItem
  public let location: String?

  public var id: PutioFileID { item.id }

  public init(item: PutioFileItem, location: String?) {
    self.item = item
    self.location = location
  }
}

public enum PutioPinnedFilesState: Equatable, Sendable {
  case loading
  case unavailable
  case loaded([PutioPinnedFile])
}

public struct PutioPinEditFailure: Identifiable, Equatable, Sendable {
  public let id = UUID()
  public let name: String
}

public struct PutioPinnedFilesActions: Sendable {
  let loadIDs: @MainActor @Sendable () async throws -> [PutioFileID]
  let saveIDs: @MainActor @Sendable ([PutioFileID]) async throws -> Void
  let loadFile: @MainActor @Sendable (PutioFileID) async throws -> PutioFileItem

  public init(runtime: PutioRuntime) {
    loadIDs = { try await runtime.pinnedFileIDs() }
    saveIDs = { try await runtime.setPinnedFileIDs($0) }
    loadFile = { try await runtime.getFile(fileID: $0) }
  }

  init(
    loadIDs: @escaping @MainActor @Sendable () async throws -> [PutioFileID],
    saveIDs: @escaping @MainActor @Sendable ([PutioFileID]) async throws -> Void,
    loadFile: @escaping @MainActor @Sendable (PutioFileID) async throws -> PutioFileItem
  ) {
    self.loadIDs = loadIDs
    self.saveIDs = saveIDs
    self.loadFile = loadFile
  }
}

@MainActor
@Observable
public final class PutioPinnedFilesModel {
  public static let sectionLimit = 5

  public private(set) var state: PutioPinnedFilesState = .loading
  public private(set) var editFailure: PutioPinEditFailure?
  private var pinnedIDs: [PutioFileID] = []
  @ObservationIgnored private var confirmed: (state: PutioPinnedFilesState, ids: [PutioFileID]) =
    (.loading, [])

  @ObservationIgnored private let actions: PutioPinnedFilesActions
  @ObservationIgnored private let rootName: String
  @ObservationIgnored private var generation: UInt64 = 0
  @ObservationIgnored private var queue: Task<Void, Never>?

  public init(actions: PutioPinnedFilesActions, rootName: String) {
    self.actions = actions
    self.rootName = rootName
  }

  public var items: [PutioPinnedFile] {
    guard case .loaded(let items) = state else { return [] }
    return items
  }

  public var sectionItems: [PutioPinnedFile] { Array(items.prefix(Self.sectionLimit)) }

  public var showsSeeAll: Bool { items.count > Self.sectionLimit }

  public func isPinned(_ id: PutioFileID) -> Bool { pinnedIDs.contains(id) }

  public func clearEditFailure() { editFailure = nil }

  /// Loads the pins and drops the ones whose file is gone from the config.
  public func load() async {
    await serially { await self.reloadDroppingGone() }
  }

  public func pin(_ item: PutioFileItem, in location: String?) async {
    await edit(.pin(PutioPinnedFile(item: item, location: location)), failureName: item.name)
  }

  public func unpin(_ item: PutioFileItem) async {
    await edit(.remove([item.id]), failureName: item.name)
  }

  private enum Edit {
    case pin(PutioPinnedFile)
    case remove(Set<PutioFileID>)

    func applied(to ids: [PutioFileID]) -> [PutioFileID] {
      switch self {
      case .pin(let file): [file.id] + ids.filter { $0 != file.id }
      case .remove(let removed): ids.filter { !removed.contains($0) }
      }
    }

    func applied(to shown: (state: PutioPinnedFilesState, ids: [PutioFileID]))
      -> (PutioPinnedFilesState, [PutioFileID])
    {
      let ids = applied(to: shown.ids)
      guard case .loaded(let files) = shown.state else { return (shown.state, ids) }
      switch self {
      case .pin(let file):
        return (.loaded([file] + files.filter { $0.id != file.id }), ids)
      case .remove(let removed):
        return (.loaded(files.filter { !removed.contains($0.id) }), ids)
      }
    }
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

  private func reloadDroppingGone() async {
    let gone = await reload()
    guard !gone.isEmpty, let stored = try? await actions.loadIDs() else { return }
    let next = Edit.remove(gone).applied(to: stored)
    if next != stored { try? await actions.saveIDs(next) }
  }

  private func reload() async -> Set<PutioFileID> {
    let loadGeneration = generation
    let ids: [PutioFileID]
    do {
      ids = try await actions.loadIDs()
    } catch {
      guard loadGeneration == generation, !Task.isCancelled else { return [] }
      if case .loading = state { state = .unavailable }
      return []
    }
    let (files, gone) = await resolve(ids)
    guard loadGeneration == generation, !Task.isCancelled else { return [] }
    pinnedIDs = ids.filter { !gone.contains($0) }
    state = .loaded(files)
    confirmed = (state, pinnedIDs)
    return gone
  }

  private func edit(_ edit: Edit, failureName: String) async {
    generation &+= 1
    let mark = generation
    (state, pinnedIDs) = edit.applied(to: (state, pinnedIDs))
    await serially {
      await self.commit(edit, mark: mark, failureName: failureName)
    }
  }

  private func commit(
    _ edit: Edit, mark: UInt64, failureName: String
  ) async {
    do {
      let stored = try await actions.loadIDs()
      let next = edit.applied(to: stored)
      if next != stored { try await actions.saveIDs(next) }
      confirmed = edit.applied(to: (confirmed.state, next))
      guard mark == generation else { return }
      let shown = pinnedIDs
      pinnedIDs = next
      if case .loaded = state, shown == next { return }
      _ = await reload()
    } catch {
      editFailure = PutioPinEditFailure(name: failureName)
      guard mark == generation else { return }
      (state, pinnedIDs) = confirmed
    }
  }

  private func resolve(_ ids: [PutioFileID]) async -> ([PutioPinnedFile], Set<PutioFileID>) {
    let lookups = await lookUp(ids)
    var gone = Set<PutioFileID>()
    var items: [PutioFileItem] = []
    for id in ids {
      switch lookups[id] {
      case .success(let item): items.append(item)
      case .failure(let error as PutioRuntimeError) where error == .notFound: gone.insert(id)
      default: break
      }
    }
    let known = Dictionary(items.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    let parentIDs = Set(items.map(\.parentID)).subtracting(known.keys).subtracting([.root])
    var names = known
    names[.root] = rootName
    for (id, result) in await lookUp(Array(parentIDs)) {
      if case .success(let folder) = result { names[id] = folder.name }
    }
    let files = items.map { PutioPinnedFile(item: $0, location: names[$0.parentID]) }
    return (files, gone)
  }

  private func lookUp(_ ids: [PutioFileID]) async -> [PutioFileID: Result<PutioFileItem, Error>] {
    let loadFile = actions.loadFile
    return await withTaskGroup(of: (PutioFileID, Result<PutioFileItem, Error>).self) { group in
      for id in Set(ids) {
        group.addTask { await Self.fetch(id, with: loadFile) }
      }
      var results: [PutioFileID: Result<PutioFileItem, Error>] = [:]
      for await (id, result) in group { results[id] = result }
      return results
    }
  }

  private nonisolated static func fetch(
    _ id: PutioFileID,
    with loadFile: @MainActor @Sendable (PutioFileID) async throws -> PutioFileItem
  ) async -> (PutioFileID, Result<PutioFileItem, Error>) {
    do {
      return (id, .success(try await loadFile(id)))
    } catch {
      return (id, .failure(error))
    }
  }
}
