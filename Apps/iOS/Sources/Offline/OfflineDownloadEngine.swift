import AVFoundation
import Foundation
import PutioCore
import Synchronization
import os

/// The transport behind the queue: AVAssetDownloadURLSession in production, a
/// scripted fake in tests. Every callback lands on the main actor.
@MainActor
protocol PutioOfflineDownloadEngine: AnyObject {
  var onProgress: ((PutioFileID, Double) -> Void)? { get set }
  var onLocation: ((PutioFileID, URL) -> Void)? { get set }
  var onFinished: ((PutioFileID, Error?) -> Void)? { get set }
  /// The engine confirmed a cancellation the queue asked for.
  var onCancelled: ((PutioFileID) -> Void)? { get set }
  /// A write the engine could not make; the queue reports it with its own.
  var onPersistenceFailure: ((Error) -> Void)? { get set }

  /// Inspects the asset without downloading it.
  func inventory(url: URL) async throws -> PutioOfflineInventory
  func start(fileID: PutioFileID, url: URL, title: String, audioLanguages: [String]) async throws
  func pause(fileID: PutioFileID)
  func resume(fileID: PutioFileID)
  func cancel(fileID: PutioFileID)
  /// File ids with tasks the system kept alive across relaunch.
  func restoreTasks() async -> [PutioFileID]
  func stop()
  /// Writes again what failed before.
  func retryPersisting() throws
}

/// AVAssetDownloadURLSession with a background configuration. The system owns
/// the transfer, keeps it alive across relaunch, and reports the final
/// location before completion. Task identity is the put.io file id carried in
/// `taskDescription`, so restored tasks map back onto queue items.
@MainActor
final class PutioSystemOfflineDownloadEngine: NSObject, PutioOfflineDownloadEngine {
  static let sessionIdentifier = "io.put.ios.offline-downloads"
  /// put.io file ids are per account, so tasks are keyed by account too and
  /// an engine only ever maps its own account's tasks.
  let accountID: Int

  private let prepareConfiguration:
    @MainActor (URL, String, [String]) async throws -> AVAssetDownloadConfiguration
  private let makeTask: @MainActor (AVAssetDownloadConfiguration) -> URLSessionTask
  private let relay: PutioOfflineDownloadRelay
  private let allTasks: @MainActor () async -> [URLSessionTask]

  init(
    accountID: Int,
    prepareConfiguration:
      @escaping @MainActor (URL, String, [String]) async throws -> AVAssetDownloadConfiguration =
      PutioSystemOfflineDownloadEngine.prepareConfiguration,
    makeTask: @escaping @MainActor (AVAssetDownloadConfiguration) -> URLSessionTask = {
      PutioSystemOfflineDownloadEngine.sharedSession.makeAssetDownloadTask(
        downloadConfiguration: $0)
    },
    relay: PutioOfflineDownloadRelay = PutioSystemOfflineDownloadEngine.relay,
    allTasks: @escaping @MainActor () async -> [URLSessionTask] = {
      await PutioSystemOfflineDownloadEngine.sharedSession.allTasks.filter {
        $0 is AVAssetDownloadTask
      }
    }
  ) {
    self.accountID = accountID
    self.prepareConfiguration = prepareConfiguration
    self.makeTask = makeTask
    self.relay = relay
    self.allTasks = allTasks
    super.init()
  }

  private func description(for fileID: PutioFileID) -> String {
    "\(accountID):\(fileID.rawValue)"
  }

  /// Only the account-qualified form is owned. A bare file id has no owner
  /// and is never adopted: the queue that wrote it can no longer be told
  /// apart from another account's.
  static func parse(_ description: String?) -> (accountID: Int, fileID: PutioFileID)? {
    guard let description else { return nil }
    let parts = description.split(separator: ":", maxSplits: 1)
    guard parts.count == 2, let account = Int(parts[0]), let file = Int(parts[1]) else {
      return nil
    }
    return (account, PutioFileID(rawValue: file))
  }

  private func owns(_ task: URLSessionTask) -> PutioFileID? {
    guard let parsed = Self.parse(task.taskDescription), parsed.accountID == accountID else {
      return nil
    }
    return parsed.fileID
  }

  var onProgress: ((PutioFileID, Double) -> Void)?
  var onLocation: ((PutioFileID, URL) -> Void)?
  var onFinished: ((PutioFileID, Error?) -> Void)?
  var onCancelled: ((PutioFileID) -> Void)?
  var onPersistenceFailure: ((Error) -> Void)?

  /// One background session per process. iOS rejects a second session with
  /// the same identifier, and the tab view that owns the engine is rebuilt on
  /// every sign-in, so the session outlives any single engine and forwards
  /// to whichever engine is current.
  private static let sharedSession: AVAssetDownloadURLSession = {
    let configuration = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
    configuration.isDiscretionary = false
    configuration.sessionSendsLaunchEvents = true
    return AVAssetDownloadURLSession(
      configuration: configuration, assetDownloadDelegate: relay, delegateQueue: .main)
  }()
  static let relay = PutioOfflineDownloadRelay()
  private var tasks: [PutioFileID: URLSessionTask] = [:]
  private var pendingStarts: [PutioFileID: UUID] = [:]
  /// Set by the app delegate when iOS relaunches us for session events.
  static var backgroundCompletion: (() -> Void)?

  /// Forces the shared session into existence so a background relaunch that
  /// never reaches the signed-in shell still receives its events.
  static func activateBackgroundSession() {
    _ = sharedSession
  }

  /// SwiftUI evaluates `State(initialValue:)` on every parent update, so
  /// engines are constructed more often than they are used. Only the engine
  /// that actually owns tasks claims the relay, at the moments it takes them.
  private func claimRelay() {
    relay.engine = self
  }

  /// Every property load must succeed; a failure here is a real inventory
  /// failure and the picker surfaces it instead of guessing.
  func inventory(url: URL) async throws -> PutioOfflineInventory {
    let asset = AVURLAsset(url: url)
    let (duration, variants) = try await asset.load(.duration, .variants)
    let audible = try await asset.loadMediaSelectionGroup(for: .audible)
    let legible = try await asset.loadMediaSelectionGroup(for: .legible)
    let seconds = duration.seconds.isFinite ? duration.seconds : 0
    let options = (audible?.options ?? []).map { option in
      let track = PutioOfflineQueue.track(option)
      return PutioOfflineAudioOption(
        languageCode: track.languageCode, displayName: track.displayName,
        estimatedBytes: Self.estimateAudioBytes(duration: seconds))
    }
    let subtitles = (legible?.options ?? []).map(PutioOfflineQueue.track)
    let variantBitrate = variants.compactMap(\.averageBitRate).max() ?? 0
    let videoBytes = Int64(max(variantBitrate, 1_500_000) / 8 * seconds)
    return PutioOfflineInventory(
      videoBytes: videoBytes, audioOptions: options, subtitleTracks: subtitles)
  }
  /// A conservative 128 kbps per audio rendition.
  static func estimateAudioBytes(duration: Double) -> Int64 {
    Int64(128_000 / 8 * max(duration, 0))
  }

  /// Every selected language is attached as its own media selection on the
  /// primary content configuration, so the stored asset keeps all of them.
  /// An empty selection keeps the asset default.
  func start(fileID: PutioFileID, url: URL, title: String, audioLanguages: [String]) async throws {
    try Task.checkCancellation()
    let request = UUID()
    pendingStarts[fileID] = request
    defer {
      if pendingStarts[fileID] == request { pendingStarts[fileID] = nil }
    }
    if let previous = tasks[fileID] {
      previous.cancel()
      stopProgress(fileID)
      tasks[fileID] = nil
    }
    let configuration = try await prepareConfiguration(url, title, audioLanguages)
    try Task.checkCancellation()
    guard pendingStarts[fileID] == request else { throw CancellationError() }
    claimRelay()
    let task = makeTask(configuration)
    task.taskDescription = description(for: fileID)
    tasks[fileID] = task
    observeProgress(of: task, fileID: fileID)
    task.resume()
  }

  private static func prepareConfiguration(
    url: URL, title: String, audioLanguages: [String]
  ) async throws -> AVAssetDownloadConfiguration {
    let asset = AVURLAsset(url: url)
    let configuration = AVAssetDownloadConfiguration(asset: asset, title: title)
    if !audioLanguages.isEmpty {
      // A selection the asset cannot honour must fail rather than store a
      // default-only package the queue believes is multi-language.
      guard let group = try await asset.loadMediaSelectionGroup(for: .audible) else {
        throw PutioOfflineEngineError.missingLanguages
      }
      let selections: [AVMediaSelection] = audioLanguages.compactMap { language in
        guard
          let option = group.options.first(where: {
            PutioOfflineQueue.track($0).languageCode == PutioOfflineLanguage.normalize(language)
          })
        else { return nil }
        guard
          let selection = asset.preferredMediaSelection.mutableCopy() as? AVMutableMediaSelection
        else { return nil }
        selection.select(option, in: group)
        return selection
      }
      guard selections.count == audioLanguages.count else {
        throw PutioOfflineEngineError.missingLanguages
      }
      configuration.primaryContentConfiguration.mediaSelections = selections
    }
    return configuration
  }

  private var progressObservations: [PutioFileID: NSKeyValueObservation] = [:]

  /// Configuration-based tasks report through `Progress`; the time-range
  /// delegate stays as a fallback for older task shapes. Both pass the task's
  /// gate before and after the main-actor hop.
  private func observeProgress(of task: URLSessionTask, fileID: PutioFileID) {
    let gate = PutioOfflineProgressGate()
    relay.track(task, with: gate)
    progressObservations[fileID] = task.progress.observe(\.fractionCompleted, options: [.new]) {
      [weak self] progress, _ in
      let fraction = progress.fractionCompleted
      guard gate.admits(fraction) else { return }
      Task { @MainActor [weak self] in
        guard gate.delivers(fraction) else { return }
        self?.handleProgress(fileID, fraction)
      }
    }
  }

  /// Ends both progress paths for the file's current task.
  private func stopProgress(_ fileID: PutioFileID) {
    progressObservations[fileID] = nil
    if let task = tasks[fileID] { relay.track(task, with: nil) }
  }

  func pause(fileID: PutioFileID) {
    claimRelay()
    tasks[fileID]?.suspend()
  }

  func resume(fileID: PutioFileID) {
    claimRelay()
    tasks[fileID]?.resume()
  }

  func cancel(fileID: PutioFileID) {
    pendingStarts[fileID] = nil
    tasks[fileID]?.cancel()
    stopProgress(fileID)
    tasks[fileID] = nil
  }

  /// Duplicate tasks for one file id (a crash between start and persist)
  /// keep the newest and cancel the rest.
  func restoreTasks() async -> [PutioFileID] {
    let lifetime = self.lifetime
    let restored = await allTasks()
    // A stop during the listing hands the relay to a successor; this restore
    // must not take it back or consume its events.
    guard lifetime == self.lifetime else { return [] }
    var ids: [PutioFileID] = []
    for task in restored {
      guard let fileID = owns(task) else { continue }
      if let existing = tasks[fileID] {
        if existing.taskIdentifier < task.taskIdentifier {
          existing.cancel()
          stopProgress(fileID)
          tasks[fileID] = task
          observeProgress(of: task, fileID: fileID)
        } else {
          task.cancel()
        }
        continue
      }
      tasks[fileID] = task
      observeProgress(of: task, fileID: fileID)
      ids.append(fileID)
    }
    // Only once the live tasks are known, and buffered events go through the
    // journal's selection first, so no event from a replaced task reaches
    // the item its successor now owns.
    do { try PutioOfflineEventJournal.append(relay.takeBuffered()) } catch {
      persistenceFailed(error)
    }
    claimRelay()
    PutioOfflineEventJournal.replay(into: self, liveTasks: tasks.mapValues(\.taskIdentifier))
    return ids
  }

  /// Abandon pending starts and forget tasks without invalidating the shared
  /// session, so a successor engine can reclaim transfers through restore.
  /// Advanced by every stop, so work that suspended before it ends there.
  private var lifetime: UInt64 = 0

  func stop() {
    lifetime &+= 1
    pendingStarts.removeAll()
    for fileID in tasks.keys { stopProgress(fileID) }
    tasks = [:]
    if relay.engine === self { relay.engine = nil }
  }

  fileprivate func handleProgress(_ fileID: PutioFileID, _ progress: Double) {
    onProgress?(fileID, progress)
  }

  func handleLocation(_ fileID: PutioFileID, _ url: URL) {
    onLocation?(fileID, url)
  }

  func persistenceFailed(_ error: Error) {
    onPersistenceFailure?(error)
  }

  func retryPersisting() throws {
    try PutioOfflineEventJournal.retry()
  }

  /// Completions for a task the map has already replaced are stale and must
  /// not touch the replacement's bookkeeping.
  fileprivate func handleCompletion(
    _ fileID: PutioFileID, task: URLSessionTask, _ error: Error?
  ) {
    if let current = tasks[fileID], current !== task { return }
    stopProgress(fileID)
    tasks[fileID] = nil
    // Cancellation by the queue is the one case it does not want reported.
    if let error, (error as? URLError)?.code == .cancelled {
      onCancelled?(fileID)
      return
    }
    onFinished?(fileID, error)
  }

  /// Replayed events for tasks the map never saw (finished before restore)
  /// are accepted; live events for a replaced task are stale and dropped.
  /// Events for another account's tasks stay buffered for that account's
  /// engine; this one never sees them.
  fileprivate func accepts(_ event: PutioOfflineDownloadRelay.Event) -> Bool {
    owns(event.task) != nil
  }

  fileprivate func replay(_ event: PutioOfflineDownloadRelay.Event) {
    guard let fileID = owns(event.task) else { return }
    switch event {
    case .progress(_, let progress):
      handleProgress(fileID, progress)
    case .location(let task, let url):
      guard tasks[fileID] == nil || tasks[fileID] === task else { return }
      handleLocation(fileID, url)
    case .completion(let task, let error):
      handleCompletion(fileID, task: task, error)
    }
  }
}

enum PutioOfflineEngineError: Error {
  case missingLanguages
}

/// Passes a task's progress only when it reaches a new, higher whole percent.
/// KVO fires far more often than the row can show, and every admitted value
/// costs a main-actor hop and a Downloads list update.
final class PutioOfflineProgressGate: Sendable {
  private let admitted = Mutex<Int>(-1)
  private let delivered = Mutex<Int>(-1)

  /// Before the hop, on whichever thread reported the progress.
  func admits(_ fraction: Double) -> Bool { Self.advance(admitted, to: fraction) }

  /// After the hop. Hops are not ordered, so a lower percent admitted first
  /// can land after a higher one; it is dropped here.
  func delivers(_ fraction: Double) -> Bool { Self.advance(delivered, to: fraction) }

  /// Drops everything from now on, including hops already queued.
  func close() {
    admitted.withLock { $0 = .max }
    delivered.withLock { $0 = .max }
  }

  private static func advance(_ last: borrowing Mutex<Int>, to fraction: Double) -> Bool {
    let percent = Int((min(max(fraction, 0), 1) * 100).rounded(.down))
    return last.withLock { last in
      guard percent > last else { return false }
      last = percent
      return true
    }
  }
}

/// The session's delegate. It holds the current engine weakly so the session
/// never keeps a stale engine alive. Events that arrive before any engine
/// has claimed the relay (a background relaunch) are buffered and replayed
/// to the first engine that restores, so a finished download is recorded.
final class PutioOfflineDownloadRelay: NSObject, AVAssetDownloadDelegate,
  @unchecked Sendable
{
  typealias Dispatch = @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void

  /// Every hop to the main actor goes through here.
  private let dispatch: Dispatch

  private typealias Tracked = (task: URLSessionTask, gate: PutioOfflineProgressGate)

  /// Observed tasks and their gates, readable where the delegate runs, so a
  /// tick that is not a new percent never reaches the main actor. The task
  /// is held so its identifier cannot be reused while the entry exists.
  private let progressGates = Mutex<[ObjectIdentifier: Tracked]>([:])

  init(dispatch: @escaping Dispatch = { work in Task { @MainActor in work() } }) {
    self.dispatch = dispatch
    super.init()
  }

  /// A finished task stops hopping, but hops already queued, such as its
  /// final 1.0, still land. The engine closes the gate for a task it
  /// cancels or replaces.
  func release(_ task: URLSessionTask) {
    progressGates.withLock { $0[ObjectIdentifier(task)] = nil }
  }

  /// A replaced or removed gate is closed, so its queued hops are dropped.
  func track(_ task: URLSessionTask, with gate: PutioOfflineProgressGate?) {
    let previous = progressGates.withLock { gates in
      let key = ObjectIdentifier(task)
      defer { gates[key] = gate.map { (task, $0) } }
      return gates[key]
    }
    if let previous, previous.gate !== gate { previous.gate.close() }
  }

  /// Progress for a task nobody observes is dropped before any hop.
  func progressed(_ task: URLSessionTask, _ fraction: Double) {
    guard let gate = progressGates.withLock({ $0[ObjectIdentifier(task)]?.gate }),
      gate.admits(fraction)
    else { return }
    dispatch {
      guard gate.delivers(fraction) else { return }
      self.deliver(.progress(task: task, fraction))
    }
  }

  enum Event {
    case progress(task: URLSessionTask, Double)
    case location(task: URLSessionTask, URL)
    case completion(task: URLSessionTask, error: Error?)

    var task: URLSessionTask {
      switch self {
      case .progress(let task, _), .location(let task, _), .completion(let task, _): task
      }
    }

    var kind: Int {
      switch self {
      case .progress: 0
      case .location: 1
      case .completion: 2
      }
    }
  }

  /// Only the latest location and completion per task are kept; progress
  /// is never buffered, so a long relaunch cannot grow this without bound.
  @MainActor private(set) var buffered: [Event] = []
  @MainActor weak var engine: PutioSystemOfflineDownloadEngine? {
    didSet { drain() }
  }

  @MainActor func takeBuffered() -> [Event] {
    defer { buffered = [] }
    return buffered
  }

  @MainActor private func buffer(_ event: Event) {
    if case .progress = event { return }
    buffered.removeAll { existing in
      existing.task === event.task && existing.kind == event.kind
    }
    buffered.append(event)
  }

  /// Replays what the current engine accepts and keeps the rest for a later
  /// engine (another account). Progress is not worth keeping.
  @MainActor private func drain() {
    guard let engine, !buffered.isEmpty else { return }
    let events = buffered
    buffered = []
    for event in events {
      if engine.accepts(event) {
        engine.replay(event)
      } else {
        buffer(event)
      }
    }
  }

  @MainActor fileprivate func deliver(_ event: Event) {
    guard let engine, engine.accepts(event) else {
      buffer(event)
      return
    }
    engine.replay(event)
  }

  func urlSession(
    _ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
    didLoad timeRange: CMTimeRange, totalTimeRangesLoaded loadedTimeRanges: [NSValue],
    timeRangeExpectedToLoad: CMTimeRange
  ) {
    let loaded = loadedTimeRanges.map { $0.timeRangeValue.duration.seconds }.reduce(0, +)
    let expected = timeRangeExpectedToLoad.duration.seconds
    progressed(assetDownloadTask, expected > 0 ? min(1, loaded / expected) : 0)
  }

  func urlSession(
    _ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    dispatch { self.deliver(.location(task: assetDownloadTask, location)) }
  }

  /// Configuration-based tasks announce the final location up front.
  func urlSession(
    _ session: URLSession, assetDownloadTask: AVAssetDownloadTask, willDownloadTo location: URL
  ) {
    dispatch { self.deliver(.location(task: assetDownloadTask, location)) }
  }

  func urlSession(
    _ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
    didResolve resolvedMediaSelection: AVMediaSelection
  ) {}

  /// A finished task is released here even when no engine is left to do it.
  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    release(task)
    dispatch { self.deliver(.completion(task: task, error: error)) }
  }

  /// Events that arrived while no engine was listening are written to a
  /// journal before the system completion handler runs, so a suspension right
  /// after it cannot lose a finished download. The next engine to restore
  /// replays the journal. A failed write stays in memory for that replay, and
  /// a listening engine reports it now.
  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    dispatch {
      do { try PutioOfflineEventJournal.append(self.buffered) } catch {
        self.engine?.persistenceFailed(error)
      }
      PutioSystemOfflineDownloadEngine.backgroundCompletion?()
      PutioSystemOfflineDownloadEngine.backgroundCompletion = nil
    }
  }
}

/// A tiny on-disk record of location and completion events delivered while
/// the app was not ready to handle them. Keyed by task description so the
/// owning account's engine can claim its entries, and by task identifier so a
/// replaced task's events stay apart from its successor's.
enum PutioOfflineEventJournal {
  struct Entry: Codable, Equatable {
    let description: String
    /// Nil for entries written before the identifier was recorded.
    var taskIdentifier: Int? = nil
    var location: String?
    var completed: Bool
    var failed: Bool
  }

  private static let logger = Logger(subsystem: "io.put", category: "OfflineDownloads")

  static var fileURL: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appending(path: "OfflineDownloads/events.json")
  }

  /// The entries a failed write could not put on disk. They are newer than
  /// the file, so the next append, replay, or retry starts from them.
  @MainActor private static var unwritten: [Entry]?

  @MainActor private static func current() -> [Entry] { unwritten ?? load() }

  @MainActor private static func write(_ entries: [Entry]) throws {
    do {
      try save(entries)
      unwritten = nil
    } catch {
      unwritten = entries
      logger.error("Offline event journal not written: \(error.localizedDescription)")
      throw error
    }
  }

  /// Writes what a failed append or replay left in memory.
  @MainActor static func retry() throws {
    guard let unwritten else { return }
    try write(unwritten)
  }

  @MainActor static func append(_ events: [PutioOfflineDownloadRelay.Event]) throws {
    guard !events.isEmpty else { return }
    var entries = current()
    for event in events {
      guard let description = event.task.taskDescription else { continue }
      let taskIdentifier = event.task.taskIdentifier
      let index = entries.firstIndex {
        $0.description == description && $0.taskIdentifier == taskIdentifier
      }
      var entry =
        index.map { entries[$0] }
        ?? Entry(
          description: description, taskIdentifier: taskIdentifier, location: nil,
          completed: false, failed: false)
      switch event {
      case .location(_, let url): entry.location = url.path
      case .completion(_, let error):
        entry.completed = error == nil
        entry.failed = error != nil
      case .progress: continue
      }
      if let index { entries[index] = entry } else { entries.append(entry) }
    }
    try write(entries)
  }

  static func load() -> [Entry] {
    guard let data = try? Data(contentsOf: fileURL) else { return [] }
    return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
  }

  static func save(_ entries: [Entry]) throws {
    guard !entries.isEmpty else {
      do { try FileManager.default.removeItem(at: fileURL) } catch CocoaError.fileNoSuchFile {}
      return
    }
    let data = try JSONEncoder().encode(entries)
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: fileURL, options: .atomic)
  }

  /// Hands this account's entries to the engine and removes them. A file
  /// with a live task only takes that task's entry; otherwise the newest
  /// task's entry speaks for it, as restore keeps the newest duplicate.
  @MainActor static func replay(
    into engine: PutioSystemOfflineDownloadEngine, liveTasks: [PutioFileID: Int]
  ) {
    var remaining: [Entry] = []
    var claimed: [PutioFileID: Entry] = [:]
    var legacyLocations: [PutioFileID: String] = [:]
    var order: [PutioFileID] = []
    for entry in current() {
      guard let parsed = PutioSystemOfflineDownloadEngine.parse(entry.description),
        parsed.accountID == engine.accountID
      else {
        remaining.append(entry)
        continue
      }
      if let live = liveTasks[parsed.fileID], entry.taskIdentifier != live {
        // An entry without an identifier may hold the live task's only
        // destination; its outcome cannot be attributed, so only that is kept.
        if entry.taskIdentifier == nil, let location = entry.location {
          if legacyLocations[parsed.fileID] == nil, claimed[parsed.fileID] == nil {
            order.append(parsed.fileID)
          }
          legacyLocations[parsed.fileID] = location
        }
        continue
      }
      if let existing = claimed[parsed.fileID] {
        guard (entry.taskIdentifier ?? -1) > (existing.taskIdentifier ?? -1) else { continue }
      } else if legacyLocations[parsed.fileID] == nil {
        order.append(parsed.fileID)
      }
      claimed[parsed.fileID] = entry
    }
    for fileID in order {
      let entry = claimed[fileID]
      if let location = entry?.location ?? legacyLocations[fileID] {
        engine.handleLocation(fileID, URL(fileURLWithPath: location))
      }
      guard let entry else { continue }
      if entry.completed {
        engine.onFinished?(fileID, nil)
      } else if entry.failed {
        engine.onFinished?(fileID, URLError(.unknown))
      }
    }
    // An entry left behind replays again next launch, and a stale failure
    // would then fail a download that has since finished.
    do { try write(remaining) } catch { engine.persistenceFailed(error) }
  }
}
