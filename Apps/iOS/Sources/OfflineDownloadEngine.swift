import AVFoundation
import Foundation
import PutioCore

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

  init(accountID: Int) {
    self.accountID = accountID
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
  private static let relay = PutioOfflineDownloadRelay()
  private var session: AVAssetDownloadURLSession { Self.sharedSession }
  private var tasks: [PutioFileID: AVAssetDownloadTask] = [:]
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
    Self.relay.engine = self
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
    if let previous = tasks[fileID] {
      previous.cancel()
      tasks[fileID] = nil
    }
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
    claimRelay()
    let task = session.makeAssetDownloadTask(downloadConfiguration: configuration)
    task.taskDescription = description(for: fileID)
    tasks[fileID] = task
    observeProgress(of: task, fileID: fileID)
    task.resume()
  }

  private var progressObservations: [PutioFileID: NSKeyValueObservation] = [:]

  /// Configuration-based tasks report through `Progress`; the time-range
  /// delegate stays as a fallback for older task shapes.
  private func observeProgress(of task: AVAssetDownloadTask, fileID: PutioFileID) {
    progressObservations[fileID] = task.progress.observe(\.fractionCompleted, options: [.new]) {
      [weak self] progress, _ in
      let fraction = progress.fractionCompleted
      Task { @MainActor [weak self] in self?.handleProgress(fileID, fraction) }
    }
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
    tasks[fileID]?.cancel()
    tasks[fileID] = nil
    progressObservations[fileID] = nil
  }

  /// Duplicate tasks for one file id (a crash between start and persist)
  /// keep the newest and cancel the rest.
  func restoreTasks() async -> [PutioFileID] {
    claimRelay()
    PutioOfflineEventJournal.replay(into: self)
    let restored = await session.allTasks
    var ids: [PutioFileID] = []
    for task in restored {
      guard let downloadTask = task as? AVAssetDownloadTask, let fileID = owns(task) else {
        continue
      }
      if let existing = tasks[fileID] {
        if existing.taskIdentifier < downloadTask.taskIdentifier {
          existing.cancel()
          tasks[fileID] = downloadTask
          observeProgress(of: downloadTask, fileID: fileID)
        } else {
          downloadTask.cancel()
        }
        continue
      }
      tasks[fileID] = downloadTask
      observeProgress(of: downloadTask, fileID: fileID)
      ids.append(fileID)
    }
    return ids
  }

  /// The shared session is never invalidated; the engine only forgets its
  /// task map so a successor engine can reclaim tasks through restore.
  func stop() {
    tasks = [:]
    progressObservations = [:]
    if Self.relay.engine === self { Self.relay.engine = nil }
  }

  fileprivate func handleProgress(_ fileID: PutioFileID, _ progress: Double) {
    onProgress?(fileID, progress)
  }

  func handleLocation(_ fileID: PutioFileID, _ url: URL) {
    onLocation?(fileID, url)
  }

  /// Completions for a task the map has already replaced are stale and must
  /// not touch the replacement's bookkeeping.
  fileprivate func handleCompletion(
    _ fileID: PutioFileID, task: URLSessionTask, _ error: Error?
  ) {
    if let current = tasks[fileID], current !== task { return }
    // Cancellation by the queue is the one case it does not want reported.
    if let error, (error as? URLError)?.code == .cancelled {
      tasks[fileID] = nil
      progressObservations[fileID] = nil
      onCancelled?(fileID)
      return
    }
    tasks[fileID] = nil
    progressObservations[fileID] = nil
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

/// The session's delegate. It holds the current engine weakly so the session
/// never keeps a stale engine alive. Events that arrive before any engine
/// has claimed the relay (a background relaunch) are buffered and replayed
/// to the first engine that restores, so a finished download is recorded.
final class PutioOfflineDownloadRelay: NSObject, AVAssetDownloadDelegate,
  @unchecked Sendable
{
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
    let progress = expected > 0 ? min(1, loaded / expected) : 0
    Task { @MainActor in self.deliver(.progress(task: assetDownloadTask, progress)) }
  }

  func urlSession(
    _ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    Task { @MainActor in self.deliver(.location(task: assetDownloadTask, location)) }
  }

  /// Configuration-based tasks announce the final location up front.
  func urlSession(
    _ session: URLSession, assetDownloadTask: AVAssetDownloadTask, willDownloadTo location: URL
  ) {
    Task { @MainActor in self.deliver(.location(task: assetDownloadTask, location)) }
  }

  func urlSession(
    _ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
    didResolve resolvedMediaSelection: AVMediaSelection
  ) {}

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    Task { @MainActor in self.deliver(.completion(task: task, error: error)) }
  }

  /// Events that arrived while no engine was listening are written to a
  /// journal before the system completion handler runs, so a suspension right
  /// after it cannot lose a finished download. The next engine to restore
  /// replays the journal.
  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    Task { @MainActor in
      PutioOfflineEventJournal.append(self.buffered)
      PutioSystemOfflineDownloadEngine.backgroundCompletion?()
      PutioSystemOfflineDownloadEngine.backgroundCompletion = nil
    }
  }
}

/// A tiny on-disk record of location and completion events delivered while
/// the app was not ready to handle them. Keyed by task description so the
/// owning account's engine can claim its entries.
enum PutioOfflineEventJournal {
  struct Entry: Codable, Equatable {
    let description: String
    var location: String?
    var completed: Bool
    var failed: Bool
  }

  static var fileURL: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appending(path: "OfflineDownloads/events.json")
  }

  @MainActor static func append(_ events: [PutioOfflineDownloadRelay.Event]) {
    guard !events.isEmpty else { return }
    var entries = load()
    for event in events {
      guard let description = event.task.taskDescription else { continue }
      let index = entries.firstIndex { $0.description == description }
      var entry =
        index.map { entries[$0] }
        ?? Entry(description: description, location: nil, completed: false, failed: false)
      switch event {
      case .location(_, let url): entry.location = url.path
      case .completion(_, let error):
        entry.completed = error == nil
        entry.failed = error != nil
      case .progress: continue
      }
      if let index { entries[index] = entry } else { entries.append(entry) }
    }
    save(entries)
  }

  static func load() -> [Entry] {
    guard let data = try? Data(contentsOf: fileURL) else { return [] }
    return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
  }

  static func save(_ entries: [Entry]) {
    try? FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    if entries.isEmpty {
      try? FileManager.default.removeItem(at: fileURL)
      return
    }
    guard let data = try? JSONEncoder().encode(entries) else { return }
    try? data.write(to: fileURL, options: .atomic)
  }

  /// Hands this account's entries to the engine and removes them.
  @MainActor static func replay(into engine: PutioSystemOfflineDownloadEngine) {
    var entries = load()
    var remaining: [Entry] = []
    for entry in entries {
      guard let parsed = PutioSystemOfflineDownloadEngine.parse(entry.description),
        parsed.accountID == engine.accountID
      else {
        remaining.append(entry)
        continue
      }
      if let location = entry.location {
        engine.handleLocation(parsed.fileID, URL(fileURLWithPath: location))
      }
      if entry.completed {
        engine.onFinished?(parsed.fileID, nil)
      } else if entry.failed {
        engine.onFinished?(parsed.fileID, URLError(.unknown))
      }
    }
    entries = remaining
    save(entries)
  }
}
