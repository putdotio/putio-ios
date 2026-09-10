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
    if !audioLanguages.isEmpty, let group = try await asset.loadMediaSelectionGroup(for: .audible) {
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
    task.taskDescription = String(fileID.rawValue)
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
    let restored = await session.allTasks
    var ids: [PutioFileID] = []
    for task in restored {
      guard let downloadTask = task as? AVAssetDownloadTask,
        let raw = task.taskDescription.flatMap(Int.init)
      else { continue }
      let fileID = PutioFileID(rawValue: raw)
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

  fileprivate func handleLocation(_ fileID: PutioFileID, _ url: URL) {
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
  fileprivate func replay(_ event: PutioOfflineDownloadRelay.Event) {
    switch event {
    case .progress(let fileID, let progress):
      handleProgress(fileID, progress)
    case .location(let fileID, let url, let task):
      guard tasks[fileID] == nil || tasks[fileID] === task else { return }
      handleLocation(fileID, url)
    case .completion(let fileID, let task, let error):
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
private final class PutioOfflineDownloadRelay: NSObject, AVAssetDownloadDelegate,
  @unchecked Sendable
{
  enum Event {
    case progress(PutioFileID, Double)
    case location(PutioFileID, URL, task: URLSessionTask)
    case completion(PutioFileID, task: URLSessionTask, error: Error?)
  }

  @MainActor private(set) var buffered: [Event] = []
  @MainActor weak var engine: PutioSystemOfflineDownloadEngine? {
    didSet {
      guard let engine, !buffered.isEmpty else { return }
      let events = buffered
      buffered = []
      for event in events { engine.replay(event) }
    }
  }

  @MainActor fileprivate func deliver(_ event: Event) {
    guard let engine else {
      buffered.append(event)
      return
    }
    engine.replay(event)
  }

  private static func fileID(_ task: URLSessionTask) -> PutioFileID? {
    task.taskDescription.flatMap(Int.init).map(PutioFileID.init(rawValue:))
  }

  func urlSession(
    _ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
    didLoad timeRange: CMTimeRange, totalTimeRangesLoaded loadedTimeRanges: [NSValue],
    timeRangeExpectedToLoad: CMTimeRange
  ) {
    let loaded = loadedTimeRanges.map { $0.timeRangeValue.duration.seconds }.reduce(0, +)
    let expected = timeRangeExpectedToLoad.duration.seconds
    let progress = expected > 0 ? min(1, loaded / expected) : 0
    guard let fileID = Self.fileID(assetDownloadTask) else { return }
    Task { @MainActor in self.deliver(.progress(fileID, progress)) }
  }

  func urlSession(
    _ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    guard let fileID = Self.fileID(assetDownloadTask) else { return }
    Task { @MainActor in self.deliver(.location(fileID, location, task: assetDownloadTask)) }
  }

  /// Configuration-based tasks announce the final location up front.
  func urlSession(
    _ session: URLSession, assetDownloadTask: AVAssetDownloadTask, willDownloadTo location: URL
  ) {
    guard let fileID = Self.fileID(assetDownloadTask) else { return }
    Task { @MainActor in self.deliver(.location(fileID, location, task: assetDownloadTask)) }
  }

  func urlSession(
    _ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
    didResolve resolvedMediaSelection: AVMediaSelection
  ) {}

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let fileID = Self.fileID(task) else { return }
    Task { @MainActor in self.deliver(.completion(fileID, task: task, error: error)) }
  }

  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    Task { @MainActor in
      PutioSystemOfflineDownloadEngine.backgroundCompletion?()
      PutioSystemOfflineDownloadEngine.backgroundCompletion = nil
    }
  }
}
