import Foundation
import Observation
public struct PutioContinueWatchingEntry: Identifiable, Codable, Equatable, Sendable {
  public let fileID: PutioFileID
  public var parentID: PutioFileID
  public var name: String
  public var positionSeconds: Int
  public var durationSeconds: Double
  public var watchedAt: Date

  public var id: PutioFileID { fileID }

  public init(
    fileID: PutioFileID, parentID: PutioFileID, name: String, positionSeconds: Int,
    durationSeconds: Double, watchedAt: Date
  ) {
    self.fileID = fileID
    self.parentID = parentID
    self.name = name
    self.positionSeconds = positionSeconds
    self.durationSeconds = durationSeconds
    self.watchedAt = watchedAt
  }

  public var fraction: Double {
    min(max(Double(positionSeconds) / durationSeconds, 0), 1)
  }

  public var remainingSeconds: Int {
    max(Int((durationSeconds - Double(positionSeconds)).rounded(.down)), 0)
  }

  public var remainingClock: String {
    let left = Duration.seconds(remainingSeconds)
    return remainingSeconds < 3600
      ? left.formatted(.time(pattern: .minuteSecond))
      : left.formatted(.time(pattern: .hourMinuteSecond))
  }

  public var remainingSpoken: String {
    Duration.seconds(remainingSeconds).formatted(
      .units(allowed: [.hours, .minutes, .seconds], width: .wide))
  }

  public var videoRoute: PutioVideoRoute {
    PutioVideoRoute(id: fileID, parentID: parentID, title: name)
  }
  public static func isInProgress(positionSeconds: Int, durationSeconds: Double) -> Bool {
    guard durationSeconds.isFinite, durationSeconds > 0, positionSeconds > 0 else { return false }
    let position = Double(positionSeconds)
    return position < durationSeconds * 0.95 && durationSeconds - position > 10
  }
}
@MainActor
public final class PutioContinueWatchingStore {
  private let defaults: UserDefaults
  private let key: String

  public init(defaults: UserDefaults = .standard, accountID: Int) {
    self.defaults = defaults
    key = Self.key(accountID: accountID)
  }

  public func read() -> [PutioContinueWatchingEntry] {
    guard let data = defaults.data(forKey: key),
      let entries = try? JSONDecoder().decode([PutioContinueWatchingEntry].self, from: data)
    else { return [] }
    return entries.filter {
      $0.fileID.rawValue > 0 && !$0.name.isEmpty
        && PutioContinueWatchingEntry.isInProgress(
          positionSeconds: $0.positionSeconds, durationSeconds: $0.durationSeconds)
    }
  }

  public func write(_ entries: [PutioContinueWatchingEntry]) {
    guard let data = try? JSONEncoder().encode(entries) else { return }
    defaults.set(data, forKey: key)
  }

  public static func clear(defaults: UserDefaults = .standard, accountID: Int) {
    defaults.removeObject(forKey: key(accountID: accountID))
  }

  private static func key(accountID: Int) -> String {
    "putio.files.continue-watching.\(accountID)"
  }
}
@MainActor
@Observable
public final class PutioContinueWatchingModel {
  public static let limit = 10

  public private(set) var entries: [PutioContinueWatchingEntry]

  private struct Media {
    let parentID: PutioFileID
    let name: String
    let durationSeconds: Double
  }

  @ObservationIgnored private var media: [PutioFileID: Media] = [:]
  @ObservationIgnored private let store: PutioContinueWatchingStore
  @ObservationIgnored private let clock: @MainActor () -> Date

  public init(
    store: PutioContinueWatchingStore, clock: @escaping @MainActor () -> Date = { .now }
  ) {
    self.store = store
    self.clock = clock
    entries = Self.ordered(store.read())
  }

  public func opened(
    fileID: PutioFileID, parentID: PutioFileID, name: String, durationSeconds: Double
  ) {
    guard durationSeconds.isFinite, durationSeconds > 0 else { return }
    media[fileID] = Media(parentID: parentID, name: name, durationSeconds: durationSeconds)
    update(
      entries.map {
        guard $0.fileID == fileID else { return $0 }
        var entry = $0
        entry.durationSeconds = durationSeconds
        return entry
      })
  }

  public func positionSaved(fileID: PutioFileID, seconds: Int) {
    let existing = entries.first { $0.fileID == fileID }
    guard
      let known = media[fileID]
        ?? existing.map({
          Media(parentID: $0.parentID, name: $0.name, durationSeconds: $0.durationSeconds)
        })
    else { return }
    let others = entries.filter { $0.fileID != fileID }
    if PutioContinueWatchingEntry.isInProgress(
      positionSeconds: seconds, durationSeconds: known.durationSeconds)
    {
      let entry = PutioContinueWatchingEntry(
        fileID: fileID, parentID: known.parentID, name: known.name, positionSeconds: seconds,
        durationSeconds: known.durationSeconds, watchedAt: clock())
      update([entry] + others)
    } else if existing != nil {
      update(others)
    }
  }

  public func remove(_ fileID: PutioFileID) {
    media[fileID] = nil
    update(entries.filter { $0.fileID != fileID })
  }
  public func reconcile(
    loadFile: @MainActor (PutioFileID) async throws -> PutioFileItem,
    keepsLocalPosition: @MainActor (PutioFileID) -> Bool = { _ in false }
  ) async {
    for read in entries {
      guard !Task.isCancelled else { return }
      do {
        let item = try await loadFile(read.fileID)
        guard entries.contains(read) else { continue }
        refresh(read, from: item, keepsPosition: keepsLocalPosition(read.fileID))
      } catch let error as PutioRuntimeError where error == .notFound {
        guard entries.contains(where: { $0.fileID == read.fileID }) else { continue }
        media[read.fileID] = nil
        update(entries.filter { $0.fileID != read.fileID })
      } catch {
        continue
      }
    }
  }

  private func refresh(
    _ entry: PutioContinueWatchingEntry, from item: PutioFileItem, keepsPosition: Bool
  ) {
    let position = keepsPosition ? entry.positionSeconds : item.resumePositionSeconds
    guard
      item.kind == .video,
      PutioContinueWatchingEntry.isInProgress(
        positionSeconds: position, durationSeconds: entry.durationSeconds)
    else {
      media[entry.fileID] = nil
      update(entries.filter { $0.fileID != entry.fileID })
      return
    }
    update(
      entries.map {
        guard $0.fileID == entry.fileID else { return $0 }
        var refreshed = $0
        refreshed.name = item.name
        refreshed.parentID = item.parentID
        refreshed.positionSeconds = position
        return refreshed
      })
  }

  private func update(_ next: [PutioContinueWatchingEntry]) {
    let kept = Self.ordered(next)
    guard kept != entries else { return }
    entries = kept
    store.write(kept)
  }

  private static func ordered(_ entries: [PutioContinueWatchingEntry])
    -> [PutioContinueWatchingEntry]
  {
    Array(entries.sorted { $0.watchedAt > $1.watchedAt }.prefix(limit))
  }
}
