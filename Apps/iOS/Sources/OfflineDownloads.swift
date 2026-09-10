import AVFoundation
import Foundation
import Observation
import PutioCore

// MARK: - Model

/// One row in the offline queue. Identity is the put.io file id, so a
/// conversion-then-download handoff or a retry keeps the same item.
struct PutioOfflineItem: Identifiable, Codable, Equatable, Sendable {
  enum Kind: String, Codable, Sendable {
    case video
    case audio
  }

  enum Stage: Codable, Equatable, Sendable {
    case queued
    case converting(progress: Double)
    case downloading(progress: Double)
    case paused(progress: Double)
    case completed
    case failed(PutioOfflineFailure)
  }

  let id: PutioFileID
  let parentID: PutioFileID
  let name: String
  let kind: Kind
  let createdAt: Date
  var stage: Stage
  /// Relative path under the app's home; AVFoundation picks the final location.
  var localPath: String?
  var storedBytes: Int64
  /// Audio tracks the user asked for, by language code, in selection order.
  var selectedAudioLanguages: [String]
  /// Tracks actually present in the stored asset, disclosed in details.
  var storedAudioTracks: [PutioOfflineTrack]
  var storedSubtitleTracks: [PutioOfflineTrack]
  var resumePositionSeconds: Int
  /// A position saved while offline that the server has not received yet.
  var pendingPositionSeconds: Int?

  var progress: Double {
    switch stage {
    case .queued: 0
    case .converting(let progress), .downloading(let progress), .paused(let progress): progress
    case .completed: 1
    case .failed: 0
    }
  }

  var isActive: Bool {
    switch stage {
    case .converting, .downloading: true
    default: false
    }
  }

  var isPlayable: Bool {
    stage == .completed && localPath != nil
  }

  /// The picker's estimate at enqueue time, enforced again before start.
  var estimatedBytes: Int64
  /// Set when the item was queued before its asset could be inspected; the
  /// queue selects every language once conversion finishes.
  var awaitsLanguageSelection: Bool = false
}

struct PutioOfflineTrack: Codable, Equatable, Hashable, Sendable {
  let languageCode: String
  let displayName: String
}

struct PutioOfflineFailure: Codable, Equatable, Sendable {
  enum Kind: String, Codable, Sendable {
    case conversion
    case resolution
    case download
    case storage
    case notFound
    case authentication
  }

  let kind: Kind
  let message: String

  var canRetry: Bool { kind != .notFound }

  static let authentication = Self(
    kind: .authentication, message: "Sign in again to continue this download.")

  static let download = Self(kind: .download, message: "The download could not finish. Try again.")
  static let conversion = Self(
    kind: .conversion, message: "The conversion did not finish. Try again.")
  static let storage = Self(
    kind: .storage, message: "Not enough space on this device. Free up storage and try again.")
  static let notFound = Self(kind: .notFound, message: "It may have been moved or deleted.")

  static func resolving(_ error: Error) -> Self? {
    switch error as? PutioRuntimeError {
    case .authenticationRequired, .sessionExpired: .authentication
    case .notFound: .notFound
    case .rateLimited:
      Self(kind: .resolution, message: "put.io is receiving too many requests. Try again shortly.")
    case .transient: Self(kind: .resolution, message: "Check your connection and try again.")
    case .invalidResponse:
      Self(kind: .resolution, message: "put.io returned an invalid response. Try again.")
    case .unknown, nil:
      Self(kind: .resolution, message: "put.io could not prepare this file. Try again.")
    }
  }
}

/// An audio language the asset offers, with the bytes it adds to the download.
struct PutioOfflineAudioOption: Identifiable, Equatable, Sendable {
  let languageCode: String
  let displayName: String
  let estimatedBytes: Int64

  var id: String { languageCode }
}

struct PutioOfflineInventory: Equatable, Sendable {
  let videoBytes: Int64
  let audioOptions: [PutioOfflineAudioOption]
  let subtitleTracks: [PutioOfflineTrack]

  /// The bytes the download will take with the given languages selected.
  func estimatedBytes(selecting languages: [String]) -> Int64 {
    videoBytes
      + audioOptions.filter { languages.contains($0.languageCode) }.map(\.estimatedBytes).reduce(
        0, +)
  }
}

// MARK: - Persistence

/// Queue persistence is a JSON document in Application Support. The queue is
/// small, read once at launch, and written on every change; a database would
/// add a dependency for nothing. This is the repository pattern for offline
/// state going forward.
struct PutioOfflineStore: Sendable {
  private struct Document: Codable {
    let version: Int
    var items: [PutioOfflineItem]
    var concurrencyLimit: Int
  }

  let directory: URL

  /// Each account keeps its own queue so a later sign-in never sees, plays,
  /// or deletes another account's downloads.
  init(directory: URL? = nil, accountID: Int? = nil) {
    if let directory {
      self.directory = directory
    } else {
      var base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "OfflineDownloads", directoryHint: .isDirectory)
      if let accountID {
        base = base.appending(path: "account-\(accountID)", directoryHint: .isDirectory)
      }
      self.directory = base
    }
  }

  private var fileURL: URL { directory.appending(path: "queue.json") }

  static let version = 1

  /// A document that fails to decode is set aside as `queue.corrupt.json`
  /// rather than silently replaced, so stored assets can still be recovered.
  func load() -> (items: [PutioOfflineItem], concurrencyLimit: Int) {
    guard let data = try? Data(contentsOf: fileURL) else {
      return ([], PutioOfflineQueue.defaultConcurrencyLimit)
    }
    guard let document = try? JSONDecoder().decode(Document.self, from: data),
      document.version == Self.version
    else {
      try? FileManager.default.removeItem(at: corruptURL)
      try? FileManager.default.moveItem(at: fileURL, to: corruptURL)
      return ([], PutioOfflineQueue.defaultConcurrencyLimit)
    }
    let limit =
      PutioOfflineQueue.concurrencyLimits.contains(document.concurrencyLimit)
      ? document.concurrencyLimit : PutioOfflineQueue.defaultConcurrencyLimit
    return (document.items, limit)
  }

  private var corruptURL: URL { directory.appending(path: "queue.corrupt.json") }

  func save(items: [PutioOfflineItem], concurrencyLimit: Int) {
    let document = Document(
      version: Self.version, items: items, concurrencyLimit: concurrencyLimit)
    guard let data = try? JSONEncoder().encode(document) else { return }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? data.write(to: fileURL, options: .atomic)
  }
}

// MARK: - Engine

/// The transport behind the queue: AVAssetDownloadURLSession in production, a
/// scripted fake in tests. Every callback lands on the main actor.
@MainActor
protocol PutioOfflineDownloadEngine: AnyObject {
  var onProgress: ((PutioFileID, Double) -> Void)? { get set }
  var onLocation: ((PutioFileID, URL) -> Void)? { get set }
  var onFinished: ((PutioFileID, Error?) -> Void)? { get set }
  /// The engine confirmed a cancellation the queue asked for.
  var onCancelled: ((PutioFileID) -> Void)? { get set }

  /// Inspects the asset without downloading it.
  func inventory(url: URL) async throws -> PutioOfflineInventory
  func start(fileID: PutioFileID, url: URL, title: String, audioLanguages: [String]) async throws
  func pause(fileID: PutioFileID)
  func resume(fileID: PutioFileID)
  func cancel(fileID: PutioFileID)
  /// File ids with tasks the system kept alive across relaunch.
  func restoreTasks() async -> [PutioFileID]
  func stop()
}

// MARK: - Queue

typealias PutioOfflineResolve =
  @MainActor @Sendable (PutioFileID, PutioOfflineItem.Kind) async throws -> PutioPlaybackResolution
typealias PutioOfflineConversionStart = @MainActor @Sendable (PutioFileID) async throws -> Void
typealias PutioOfflineConversionStatus =
  @MainActor @Sendable (PutioFileID) async throws -> PutioVideoConversionStatus
typealias PutioOfflinePositionReport = @MainActor @Sendable (PutioFileID, Int) async throws -> Void

@MainActor
@Observable
final class PutioOfflineQueue {
  static let defaultConcurrencyLimit = 2
  static let concurrencyLimits = [1, 2, 3]
  /// A single download may not exceed this many bytes of selected tracks.
  static let maximumSelectedBytes: Int64 = 8 * 1024 * 1024 * 1024

  private(set) var items: [PutioOfflineItem] = []
  private(set) var concurrencyLimit: Int
  private(set) var storedBytes: Int64 = 0
  private(set) var availableBytes: Int64 = 0

  @ObservationIgnored private let store: PutioOfflineStore
  @ObservationIgnored private let engine: any PutioOfflineDownloadEngine
  @ObservationIgnored private let resolve: PutioOfflineResolve
  @ObservationIgnored private let startConversion: PutioOfflineConversionStart
  @ObservationIgnored private let conversionStatus: PutioOfflineConversionStatus
  @ObservationIgnored private let reportPosition: PutioOfflinePositionReport
  @ObservationIgnored private let conversionPollInterval: Duration
  @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
  @ObservationIgnored private let availableStorage: @MainActor () -> Int64
  @ObservationIgnored private let fileManager: FileManager
  @ObservationIgnored private let readTracks: PutioOfflineTrackReader
  @ObservationIgnored private let isPlayable: PutioOfflinePlayabilityCheck
  @ObservationIgnored private let notifyCompletion: @MainActor (PutioOfflineItem) -> Void
  @ObservationIgnored private var workers: [PutioFileID: Task<Void, Never>] = [:]
  /// File ids whose engine task is suspended and can be resumed in place.
  @ObservationIgnored private var suspended: Set<PutioFileID> = []
  /// Suspended tasks the user asked to resume while every slot was busy.
  private var resumeWhenFree: [PutioFileID] = []
  /// Items whose package is being read for completion; a second completion
  /// signal for the same item (replay plus restore) is ignored.
  @ObservationIgnored private var completing: Set<PutioFileID> = []
  /// Bumped by resume, retry, and remove so a completion read that started
  /// before the user acted cannot commit a stale package.
  @ObservationIgnored private var completionEpoch: [PutioFileID: UInt64] = [:]

  func isWaitingForSlot(_ fileID: PutioFileID) -> Bool {
    resumeWhenFree.contains(fileID)
  }
  @ObservationIgnored private var restored = false
  @ObservationIgnored private var syncTask: Task<Void, Never>?

  init(
    store: PutioOfflineStore,
    engine: any PutioOfflineDownloadEngine,
    conversionPollInterval: Duration = .seconds(3),
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    availableStorage: @escaping @MainActor () -> Int64 = PutioOfflineQueue.deviceAvailableBytes,
    fileManager: FileManager = .default,
    readTracks: @escaping PutioOfflineTrackReader = {
      await PutioOfflineQueue.storedTracks(at: $0)
    },
    notifyCompletion: @escaping @MainActor (PutioOfflineItem) -> Void = { _ in },
    isPlayable: @escaping PutioOfflinePlayabilityCheck = {
      await PutioOfflineQueue.assetIsPlayable(at: $0)
    },
    resolve: @escaping PutioOfflineResolve,
    startConversion: @escaping PutioOfflineConversionStart,
    conversionStatus: @escaping PutioOfflineConversionStatus,
    reportPosition: @escaping PutioOfflinePositionReport
  ) {
    self.store = store
    self.engine = engine
    self.conversionPollInterval = conversionPollInterval
    self.sleep = sleep
    self.availableStorage = availableStorage
    self.fileManager = fileManager
    self.readTracks = readTracks
    self.notifyCompletion = notifyCompletion
    self.isPlayable = isPlayable
    self.resolve = resolve
    self.startConversion = startConversion
    self.conversionStatus = conversionStatus
    self.reportPosition = reportPosition
    let loaded = store.load()
    items = loaded.items
    concurrencyLimit = loaded.concurrencyLimit
    engine.onProgress = { [weak self] id, progress in self?.engineProgressed(id, progress) }
    engine.onLocation = { [weak self] id, url in self?.engineLocated(id, url) }
    engine.onFinished = { [weak self] id, error in self?.engineFinished(id, error) }
    engine.onCancelled = { [weak self] id in self?.engineCancelled(id) }
    recomputeStorage()
  }

  /// Important-usage capacity first; the simulator reports it as zero, so
  /// fall back to the plain volume capacity before treating the disk as full.
  static func deviceAvailableBytes() -> Int64 {
    let home = URL(fileURLWithPath: NSHomeDirectory())
    let values = try? home.resourceValues(forKeys: [
      .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
    ])
    if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 {
      return important
    }
    return Int64(values?.volumeAvailableCapacity ?? 0)
  }

  // MARK: Lifecycle

  /// Reconnects tasks the system kept alive and re-queues everything else
  /// that was mid-flight when the app died.
  func restore() async {
    guard !restored else { return }
    restored = true
    let alive = Set(await engine.restoreTasks())
    for index in items.indices {
      switch items[index].stage {
      case .downloading(let progress) where !alive.contains(items[index].id):
        // Progress persists in 5% steps, so a whole package can read 0.95
        // while a 40% crash also left bytes on disk. The row pauses first;
        // only a package the player can open then counts as finished.
        items[index].stage = .paused(progress: progress)
        if let localPath = items[index].localPath {
          finishRestoredIfPlayable(fileID: items[index].id, localPath: localPath)
        }
      case .paused where !alive.contains(items[index].id):
        // A previous launch may have died between pausing and the probe;
        // a playable package still on disk finishes now.
        if let localPath = items[index].localPath {
          finishRestoredIfPlayable(fileID: items[index].id, localPath: localPath)
        }
      case .paused where alive.contains(items[index].id):
        // The system kept the task; it resumes in place instead of restarting.
        suspended.insert(items[index].id)
      case .converting:
        items[index].stage = .queued
      default:
        break
      }
    }
    persist()
    schedule()
  }

  private func finishRestoredIfPlayable(fileID: PutioFileID, localPath: String) {
    let url = Self.localURL(for: localPath)
    let isPlayable = isPlayable
    Task { @MainActor [weak self] in
      guard await isPlayable(url), let self,
        case .paused = self.item(for: fileID)?.stage
      else { return }
      complete(fileID: fileID, localPath: localPath)
    }
  }

  /// One completion per item: engine success and restore both land here.
  private func complete(fileID: PutioFileID, localPath: String) {
    guard !completing.contains(fileID) else { return }
    completing.insert(fileID)
    let epoch = completionEpoch[fileID, default: 0]
    let url = Self.localURL(for: localPath)
    let readTracks = readTracks
    Task { @MainActor [weak self] in
      let tracks = await readTracks(url)
      guard let self else { return }
      completing.remove(fileID)
      // Resume, retry, or remove may have run during the read; only a row
      // that is still finishing this package commits.
      guard completionEpoch[fileID, default: 0] == epoch,
        let index = items.firstIndex(where: { $0.id == fileID }),
        items[index].localPath == localPath, workers[fileID] == nil
      else { return }
      switch items[index].stage {
      case .downloading, .paused: break
      default: return
      }
      update(fileID) {
        $0.stage = .completed
        $0.storedBytes = Self.directorySize(url, fileManager: fileManager)
        $0.storedAudioTracks = tracks.audio
        $0.storedSubtitleTracks = tracks.subtitles
      }
      recomputeStorage()
      if let completed = self.item(for: fileID) { notifyCompletion(completed) }
      schedule()
    }
  }

  func item(for fileID: PutioFileID) -> PutioOfflineItem? {
    items.first { $0.id == fileID }
  }

  // MARK: Enqueue

  /// A video that still needs conversion has no stream to inspect, so the
  /// picker cannot run; `needsConversion` tells the caller the languages
  /// will be chosen after conversion instead.
  enum InventoryResult {
    case ready(PutioOfflineInventory)
    case needsConversion
    case notApplicable
  }

  func inventory(fileID: PutioFileID, kind: PutioOfflineItem.Kind) async throws -> InventoryResult {
    guard kind == .video else { return .notApplicable }
    guard case .ready(let source) = try await resolve(fileID, kind) else { return .needsConversion }
    return .ready(try await engine.inventory(url: source.url))
  }

  /// After conversion the asset is inspectable; the queue keeps every
  /// language available so the stored asset is complete, and re-estimates
  /// the size so the storage gate sees the real total. An inventory failure
  /// is a real failure, not a silent default-only download.
  private func selectAllLanguagesIfUnset(fileID: PutioFileID, url: URL) async throws {
    guard let item = item(for: fileID), item.selectedAudioLanguages.isEmpty,
      item.kind == .video, item.awaitsLanguageSelection
    else { return }
    let inventory = try await engine.inventory(url: url)
    let languages = inventory.audioOptions.map(\.languageCode)
    update(fileID) {
      $0.selectedAudioLanguages = languages
      $0.estimatedBytes = inventory.estimatedBytes(selecting: languages)
      $0.awaitsLanguageSelection = false
    }
  }

  @discardableResult
  func enqueue(
    fileID: PutioFileID, parentID: PutioFileID, name: String, kind: PutioOfflineItem.Kind,
    audioLanguages: [String] = [], estimatedBytes: Int64 = 0,
    awaitsLanguageSelection: Bool = false
  ) -> PutioOfflineItem {
    if let existing = item(for: fileID) { return existing }
    var item = PutioOfflineItem(
      id: fileID, parentID: parentID, name: name, kind: kind, createdAt: .now, stage: .queued,
      localPath: nil, storedBytes: 0, selectedAudioLanguages: audioLanguages,
      storedAudioTracks: [], storedSubtitleTracks: [], resumePositionSeconds: 0,
      pendingPositionSeconds: nil, estimatedBytes: estimatedBytes)
    item.awaitsLanguageSelection = awaitsLanguageSelection
    items.append(item)
    persist()
    schedule()
    return item
  }

  // MARK: Controls

  func pause(fileID: PutioFileID) {
    guard let index = items.firstIndex(where: { $0.id == fileID }) else { return }
    switch items[index].stage {
    case .downloading(let progress):
      engine.pause(fileID: fileID)
      suspended.insert(fileID)
      items[index].stage = .paused(progress: progress)
    case .queued:
      workers[fileID]?.cancel()
      workers[fileID] = nil
      items[index].stage = .paused(progress: 0)
    case .converting(let progress):
      workers[fileID]?.cancel()
      workers[fileID] = nil
      items[index].stage = .paused(progress: progress)
    default:
      return
    }
    persist()
    schedule()
  }

  /// A suspended engine task resumes in place; anything else re-queues and
  /// goes through resolution again.
  func resume(fileID: PutioFileID) {
    guard let index = items.firstIndex(where: { $0.id == fileID }) else { return }
    guard case .paused(let progress) = items[index].stage else { return }
    completionEpoch[fileID, default: 0] &+= 1
    if suspended.contains(fileID) {
      guard inFlightCount < concurrencyLimit else {
        // Every slot is busy; the item keeps its progress and resumes in
        // place as soon as one frees.
        if !resumeWhenFree.contains(fileID) { resumeWhenFree.append(fileID) }
        persist()
        return
      }
      suspended.remove(fileID)
      items[index].stage = .downloading(progress: progress)
      engine.resume(fileID: fileID)
    } else {
      items[index].stage = .queued
    }
    persist()
    schedule()
  }

  func retry(fileID: PutioFileID) {
    guard let index = items.firstIndex(where: { $0.id == fileID }) else { return }
    guard case .failed(let failure) = items[index].stage, failure.canRetry else { return }
    completionEpoch[fileID, default: 0] &+= 1
    items[index].stage = .queued
    persist()
    schedule()
  }

  func remove(fileIDs: [PutioFileID]) {
    for fileID in fileIDs {
      completionEpoch[fileID, default: 0] &+= 1
      workers[fileID]?.cancel()
      workers[fileID] = nil
      suspended.remove(fileID)
      resumeWhenFree.removeAll { $0 == fileID }
      engine.cancel(fileID: fileID)
      deleteLocalAsset(for: fileID)
    }
    items.removeAll { fileIDs.contains($0.id) }
    persist()
    recomputeStorage()
    schedule()
  }

  func setConcurrencyLimit(_ limit: Int) {
    guard Self.concurrencyLimits.contains(limit) else { return }
    concurrencyLimit = limit
    persist()
    schedule()
  }

  // MARK: Playback

  func localSource(for fileID: PutioFileID) -> PutioPlaybackSource? {
    guard let item = item(for: fileID), item.isPlayable, let localPath = item.localPath else {
      return nil
    }
    let resume = item.pendingPositionSeconds ?? item.resumePositionSeconds
    return PutioPlaybackSource(url: Self.localURL(for: localPath), startFromSeconds: resume)
  }

  /// Records a position locally first, then forwards it. A failed forward
  /// stays pending until `syncPendingPositions` succeeds.
  func recordPosition(fileID: PutioFileID, seconds: Int) async {
    guard let index = items.firstIndex(where: { $0.id == fileID }) else { return }
    items[index].resumePositionSeconds = seconds
    items[index].pendingPositionSeconds = seconds
    persist()
    do {
      try await reportPosition(fileID, seconds)
      guard let index = items.firstIndex(where: { $0.id == fileID }),
        items[index].pendingPositionSeconds == seconds
      else { return }
      items[index].pendingPositionSeconds = nil
      persist()
    } catch {}
  }

  var pendingPositionCount: Int { items.filter { $0.pendingPositionSeconds != nil }.count }

  func syncPendingPositions() async {
    if let syncTask {
      await syncTask.value
      return
    }
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      for item in items where item.pendingPositionSeconds != nil {
        guard let seconds = item.pendingPositionSeconds else { continue }
        do {
          try await reportPosition(item.id, seconds)
          guard let index = items.firstIndex(where: { $0.id == item.id }),
            items[index].pendingPositionSeconds == seconds
          else { continue }
          items[index].pendingPositionSeconds = nil
        } catch {
          continue
        }
      }
      persist()
    }
    syncTask = task
    await task.value
    syncTask = nil
  }

  // MARK: Scheduling

  /// A worker resolving or converting occupies a slot before its item is
  /// marked downloading, so in-flight is workers plus engine-owned downloads.
  private var inFlightCount: Int {
    items.filter { $0.isActive || workers[$0.id] != nil }.count
  }

  private func schedule() {
    var slots = max(0, concurrencyLimit - inFlightCount)
    // Suspended tasks waiting for a slot resume in place before new work starts.
    while slots > 0, let fileID = resumeWhenFree.first {
      resumeWhenFree.removeFirst()
      guard suspended.contains(fileID), let index = items.firstIndex(where: { $0.id == fileID }),
        case .paused(let progress) = items[index].stage
      else { continue }
      suspended.remove(fileID)
      items[index].stage = .downloading(progress: progress)
      engine.resume(fileID: fileID)
      persist()
      slots -= 1
    }
    for item in items where slots > 0 && item.stage == .queued && workers[item.id] == nil {
      slots -= 1
      workers[item.id] = Task { @MainActor [weak self] in
        await self?.process(fileID: item.id)
        self?.workers[item.id] = nil
        self?.schedule()
      }
    }
  }

  private func process(fileID: PutioFileID) async {
    guard let index = items.firstIndex(where: { $0.id == fileID }) else { return }
    let item = items[index]
    do {
      var resolution = try await resolve(fileID, item.kind)
      try Task.checkCancellation()
      if case .conversionRequired = resolution {
        resolution = try await convert(fileID: fileID)
        if case .ready(let converted) = resolution {
          try await selectAllLanguagesIfUnset(fileID: fileID, url: converted.url)
        }
      }
      // Every await above may have let pause or remove run; nothing below
      // touches the engine unless this worker still owns a live item.
      try Task.checkCancellation()
      guard let current = self.item(for: fileID), !isPaused(current.stage) else { return }
      guard case .ready(let source) = resolution else {
        fail(fileID, .conversion)
        return
      }
      let free = availableStorage()
      availableBytes = free
      // Other active downloads have not written their bytes yet; their
      // estimates come off the free space before this one is admitted.
      let reserved =
        items
        .filter { $0.id != fileID && ($0.isActive || workers[$0.id] != nil) }
        .map { max(0, $0.estimatedBytes - $0.storedBytes) }
        .reduce(0, +)
      guard Self.fits(estimatedBytes: current.estimatedBytes, freeBytes: free - reserved) else {
        fail(fileID, .storage)
        return
      }
      update(fileID) {
        $0.stage = .downloading(progress: 0)
        $0.resumePositionSeconds = source.startFromSeconds
      }
      try await engine.start(
        fileID: fileID, url: source.url, title: item.name,
        audioLanguages: current.selectedAudioLanguages)
      // The engine's own awaits may have let pause or remove run; the queue
      // is the owner, so a task it no longer wants is cancelled here.
      if Task.isCancelled || self.item(for: fileID).map({ isPaused($0.stage) }) != false {
        // The pause raced the engine: nothing was suspended, so a later
        // Resume must re-queue rather than resume a task that is gone.
        engine.cancel(fileID: fileID)
        suspended.remove(fileID)
        return
      }
    } catch is CancellationError {
      engine.cancel(fileID: fileID)
      return
    } catch PutioOfflineEngineError.missingLanguages {
      fail(
        fileID,
        PutioOfflineFailure(
          kind: .resolution, message: "A selected audio language is no longer available."))
    } catch is PutioOfflineConversionError {
      fail(fileID, .conversion)
    } catch {
      fail(
        fileID,
        PutioOfflineFailure.resolving(error)
          ?? PutioOfflineFailure(
            kind: .resolution, message: "put.io could not prepare this file. Try again."))
    }
  }

  private func isPaused(_ stage: PutioOfflineItem.Stage) -> Bool {
    if case .paused = stage { return true }
    return false
  }

  /// Free space the device must keep after a download; the picker and the
  /// start gate apply the same headroom.
  static let minimumFreeBytes: Int64 = 200 * 1024 * 1024

  static func fits(estimatedBytes: Int64, freeBytes: Int64) -> Bool {
    estimatedBytes <= maximumSelectedBytes && estimatedBytes + minimumFreeBytes <= freeBytes
  }

  /// Conversion and download are distinct stages under one queue identity.
  private func convert(fileID: PutioFileID) async throws -> PutioPlaybackResolution {
    update(fileID) { $0.stage = .converting(progress: 0) }
    try await startConversion(fileID)
    while true {
      try Task.checkCancellation()
      let status = try await conversionStatus(fileID)
      // The await may have let pause run; a paused row is never overwritten.
      try Task.checkCancellation()
      switch status {
      case .queued:
        update(fileID) { $0.stage = .converting(progress: 0) }
      case .converting(let progress):
        update(fileID) { $0.stage = .converting(progress: progress) }
      case .completed:
        return try await resolve(fileID, .video)
      case .failed:
        throw PutioOfflineConversionError()
      }
      try await sleep(conversionPollInterval)
    }
  }

  /// Progress persists at 5% steps so a kill mid-download restores close to
  /// where it was without rewriting the document on every callback.
  private func engineProgressed(_ fileID: PutioFileID, _ progress: Double) {
    guard let index = items.firstIndex(where: { $0.id == fileID }),
      case .downloading(let previous) = items[index].stage
    else { return }
    let persisting = Int(progress * 20) != Int(previous * 20) || progress >= 1
    update(fileID, persisting: persisting) { $0.stage = .downloading(progress: progress) }
  }

  /// A cancellation the queue did not ask for (system, replaced task) must
  /// not leave a downloading row with no task behind it.
  private func engineCancelled(_ fileID: PutioFileID) {
    suspended.remove(fileID)
    // A waiter whose task is gone can no longer resume in place; it goes
    // back through the queue like any other paused item.
    if resumeWhenFree.contains(fileID) {
      resumeWhenFree.removeAll { $0 == fileID }
      update(fileID) { $0.stage = .queued }
      schedule()
      return
    }
    guard let index = items.firstIndex(where: { $0.id == fileID }),
      case .downloading(let progress) = items[index].stage, workers[fileID] == nil
    else { return }
    items[index].stage = .paused(progress: progress)
    persist()
    schedule()
  }

  private func engineLocated(_ fileID: PutioFileID, _ url: URL) {
    update(fileID) { $0.localPath = Self.relativePath(for: url) }
  }

  /// `suspend()` on an AVAssetDownloadTask does not stop a transfer that is
  /// already finishing. A success that lands on a paused row is real: the
  /// package exists, so it completes rather than being thrown away.

  private func engineFinished(_ fileID: PutioFileID, _ error: Error?) {
    guard let index = items.firstIndex(where: { $0.id == fileID }) else { return }
    suspended.remove(fileID)
    if let error {
      if case .paused = items[index].stage { return }
      if (error as? URLError)?.code == .cancelled { return }
      let failure: PutioOfflineFailure =
        (error as NSError).code == NSFileWriteOutOfSpaceError ? .storage : .download
      deleteLocalAsset(for: fileID)
      fail(fileID, failure)
      schedule()
      return
    }
    guard let localPath = items[index].localPath else {
      fail(fileID, .download)
      schedule()
      return
    }
    switch items[index].stage {
    case .downloading, .paused: break
    default: return
    }
    complete(fileID: fileID, localPath: localPath)
  }

  /// Partial packages from failed or abandoned downloads are removed so they
  /// neither leak nor count toward the accounting.
  private func deleteLocalAsset(for fileID: PutioFileID) {
    guard let index = items.firstIndex(where: { $0.id == fileID }),
      let localPath = items[index].localPath
    else { return }
    try? fileManager.removeItem(at: Self.localURL(for: localPath))
    items[index].localPath = nil
    items[index].storedBytes = 0
  }

  /// Storage accounting is a snapshot; the UI refreshes it on demand.
  func refreshStorage() {
    recomputeStorage()
  }

  /// A failure that lands after the user paused keeps the pause; the retry
  /// path re-queues from there.
  private func fail(_ fileID: PutioFileID, _ failure: PutioOfflineFailure) {
    update(fileID) {
      if case .paused = $0.stage { return }
      $0.stage = .failed(failure)
    }
  }

  private func update(
    _ fileID: PutioFileID, persisting: Bool = true, _ change: (inout PutioOfflineItem) -> Void
  ) {
    guard let index = items.firstIndex(where: { $0.id == fileID }) else { return }
    change(&items[index])
    if persisting { persist() }
  }

  private func persist() {
    store.save(items: items, concurrencyLimit: concurrencyLimit)
  }

  private func recomputeStorage() {
    storedBytes = items.map(\.storedBytes).reduce(0, +)
    availableBytes = availableStorage()
  }

  // MARK: Paths

  /// Stored relative to the app container so a reinstall or the
  /// `/.nofollow/` prefix AVFoundation reports does not orphan items.
  static func relativePath(for url: URL) -> String {
    let components = url.standardizedFileURL.pathComponents
    guard
      let application = components.indices.first(where: { index in
        index >= 2 && components[index] == "Application" && components[index - 1] == "Data"
          && components[index - 2] == "Containers"
      }), components.count > application + 2
    else { return url.standardizedFileURL.path }
    return components[(application + 2)...].joined(separator: "/")
  }

  static func localURL(for relativePath: String) -> URL {
    relativePath.hasPrefix("/")
      ? URL(fileURLWithPath: relativePath)
      : URL(fileURLWithPath: NSHomeDirectory()).appending(path: relativePath)
  }

  nonisolated static func directorySize(_ url: URL, fileManager: FileManager) -> Int64 {
    guard
      let enumerator = fileManager.enumerator(
        at: url, includingPropertiesForKeys: [.fileSizeKey, .totalFileAllocatedSizeKey])
    else {
      return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }
    var total: Int64 = 0
    for case let file as URL in enumerator {
      let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
      total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
    }
    return total
  }

  /// A package is finished when AVFoundation reports it playable with a
  /// finite duration; a partial download fails one of those.
  nonisolated static func assetIsPlayable(at url: URL) async -> Bool {
    let asset = AVURLAsset(url: url)
    guard let (playable, duration) = try? await asset.load(.isPlayable, .duration) else {
      return false
    }
    return playable && duration.isNumeric && duration.seconds > 0
  }

  nonisolated static func storedTracks(at url: URL) async
    -> (audio: [PutioOfflineTrack], subtitles: [PutioOfflineTrack])
  {
    let asset = AVURLAsset(url: url)
    var audio: [PutioOfflineTrack] = []
    var subtitles: [PutioOfflineTrack] = []
    if let group = try? await asset.loadMediaSelectionGroup(for: .audible) {
      audio = group.options.map(Self.track)
    }
    if let group = try? await asset.loadMediaSelectionGroup(for: .legible) {
      subtitles = group.options.map(Self.track)
    }
    return (audio, subtitles)
  }

  /// Language codes normalise to the two-letter form so "eng", "en-US", and
  /// "en" all compare equal.
  nonisolated static func track(_ option: AVMediaSelectionOption) -> PutioOfflineTrack {
    let raw = option.extendedLanguageTag ?? option.locale?.identifier ?? "und"
    return PutioOfflineTrack(
      languageCode: PutioOfflineLanguage.normalize(raw), displayName: option.displayName)
  }
}

struct PutioOfflineConversionError: Error {}

// MARK: - Preferred language

enum PutioOfflineLanguage {
  /// The track to play: the user's first preferred language present in the
  /// stored set, else the first stored track. Deterministic and documented.
  static func preferred(
    from stored: [PutioOfflineTrack], preferredLanguages: [String] = Locale.preferredLanguages
  ) -> PutioOfflineTrack? {
    match(from: stored, preferredLanguages: preferredLanguages) ?? stored.first
  }

  /// The first preferred language present, or nil when none is: playback
  /// uses nil to keep the asset's own default.
  static func match(from stored: [PutioOfflineTrack], preferredLanguages: [String])
    -> PutioOfflineTrack?
  {
    for language in preferredLanguages {
      let base = normalize(language)
      if let match = stored.first(where: { matches($0.languageCode, base) }) { return match }
    }
    return nil
  }

  static func matches(_ code: String, _ base: String) -> Bool {
    normalize(code) == normalize(base)
  }

  static func normalize(_ code: String) -> String {
    (Locale(identifier: code).language.languageCode?.identifier ?? code).lowercased()
  }
}

typealias PutioOfflinePlayabilityCheck = @Sendable (URL) async -> Bool
typealias PutioOfflineTrackReader =
  @Sendable (URL) async -> (audio: [PutioOfflineTrack], subtitles: [PutioOfflineTrack])
