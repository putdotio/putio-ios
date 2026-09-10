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

  private lazy var session: AVAssetDownloadURLSession = {
    let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
    configuration.isDiscretionary = false
    configuration.sessionSendsLaunchEvents = true
    return AVAssetDownloadURLSession(
      configuration: configuration, assetDownloadDelegate: self, delegateQueue: .main)
  }()
  private var tasks: [PutioFileID: AVAssetDownloadTask] = [:]
  /// Set by the app delegate when iOS relaunches us for session events.
  static var backgroundCompletion: (() -> Void)?

  /// Duration and the audible group must load; a failure here is a real
  /// inventory failure, not an empty asset.
  func inventory(url: URL) async throws -> PutioOfflineInventory {
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration).seconds
    var options: [PutioOfflineAudioOption] = []
    if let group = try await asset.loadMediaSelectionGroup(for: .audible) {
      for option in group.options {
        let track = PutioOfflineQueue.track(option)
        options.append(
          PutioOfflineAudioOption(
            languageCode: track.languageCode, displayName: track.displayName,
            estimatedBytes: Self.estimateAudioBytes(duration: duration)))
      }
    }
    var subtitles: [PutioOfflineTrack] = []
    if let group = try? await asset.loadMediaSelectionGroup(for: .legible) {
      subtitles = group.options.map(PutioOfflineQueue.track)
    }
    let variantBitrate =
      (try? await asset.load(.variants))?.map { $0.averageBitRate ?? 0 }.max() ?? 0
    let videoBytes = Int64(max(variantBitrate, 1_500_000) / 8 * duration)
    return PutioOfflineInventory(
      videoBytes: videoBytes, audioOptions: options, subtitleTracks: subtitles)
  }

  /// A conservative 128 kbps per audio rendition.
  static func estimateAudioBytes(duration: Double) -> Int64 {
    Int64(128_000 / 8 * max(duration, 0))
  }

  /// Every selected language becomes an auxiliary content configuration so
  /// the stored asset keeps all of them; an empty selection keeps the default.
  func start(fileID: PutioFileID, url: URL, title: String, audioLanguages: [String]) throws {
    let asset = AVURLAsset(url: url)
    let configuration = AVAssetDownloadConfiguration(asset: asset, title: title)
    configuration.primaryContentConfiguration.variantQualifiers = [
      AVAssetVariantQualifier(predicate: NSPredicate(format: "peakBitRate >= 0"))
    ]
    let group = asset.mediaSelectionGroup(forMediaCharacteristic: .audible)
    if let group, !audioLanguages.isEmpty {
      let selections: [AVMediaSelection] = audioLanguages.compactMap { language in
        guard
          let option = group.options.first(where: {
            PutioOfflineLanguage.matches(
              $0.extendedLanguageTag ?? $0.locale?.identifier ?? "", language)
          })
        else { return nil }
        let selection = asset.preferredMediaSelection.mutableCopy() as! AVMutableMediaSelection
        selection.select(option, in: group)
        return selection
      }
      if let first = selections.first {
        configuration.primaryContentConfiguration.mediaSelections = [first]
      }
      let auxiliary = configuration.auxiliaryContentConfigurations
      if selections.count > 1 {
        let extra = AVAssetDownloadContentConfiguration()
        extra.mediaSelections = Array(selections.dropFirst())
        configuration.auxiliaryContentConfigurations = auxiliary + [extra]
      }
    }
    let task = session.makeAssetDownloadTask(downloadConfiguration: configuration)
    task.taskDescription = String(fileID.rawValue)
    tasks[fileID] = task
    task.resume()
  }

  func pause(fileID: PutioFileID) {
    tasks[fileID]?.suspend()
  }

  func resume(fileID: PutioFileID) {
    tasks[fileID]?.resume()
  }

  func cancel(fileID: PutioFileID) {
    tasks[fileID]?.cancel()
    tasks[fileID] = nil
  }

  func restoreTasks() async -> [PutioFileID] {
    let restored = await session.allTasks
    var ids: [PutioFileID] = []
    for task in restored {
      guard let downloadTask = task as? AVAssetDownloadTask,
        let raw = task.taskDescription.flatMap(Int.init)
      else { continue }
      let fileID = PutioFileID(rawValue: raw)
      tasks[fileID] = downloadTask
      ids.append(fileID)
    }
    return ids
  }

  func stop() {
    session.finishTasksAndInvalidate()
  }

  private func fileID(for task: URLSessionTask) -> PutioFileID? {
    task.taskDescription.flatMap(Int.init).map(PutioFileID.init(rawValue:))
  }
}

extension PutioSystemOfflineDownloadEngine: AVAssetDownloadDelegate {
  nonisolated func urlSession(
    _ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
    didLoad timeRange: CMTimeRange, totalTimeRangesLoaded loadedTimeRanges: [NSValue],
    timeRangeExpectedToLoad: CMTimeRange
  ) {
    let loaded = loadedTimeRanges.map { $0.timeRangeValue.duration.seconds }.reduce(0, +)
    let expected = timeRangeExpectedToLoad.duration.seconds
    let progress = expected > 0 ? min(1, loaded / expected) : 0
    let description = assetDownloadTask.taskDescription
    Task { @MainActor [weak self] in
      guard let id = description.flatMap(Int.init) else { return }
      self?.onProgress?(PutioFileID(rawValue: id), progress)
    }
  }

  nonisolated func urlSession(
    _ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    let description = assetDownloadTask.taskDescription
    Task { @MainActor [weak self] in
      guard let id = description.flatMap(Int.init) else { return }
      self?.onLocation?(PutioFileID(rawValue: id), location)
    }
  }

  nonisolated func urlSession(
    _ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
    didResolve resolvedMediaSelection: AVMediaSelection
  ) {}

  nonisolated func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
  ) {
    let description = task.taskDescription
    Task { @MainActor [weak self] in
      guard let self, let id = description.flatMap(Int.init) else { return }
      let fileID = PutioFileID(rawValue: id)
      // A cancelled task is a queue decision; the queue already knows.
      if let error, (error as? URLError)?.code == .cancelled { return }
      tasks[fileID] = nil
      onFinished?(fileID, error)
    }
  }

  nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    Task { @MainActor in
      Self.backgroundCompletion?()
      Self.backgroundCompletion = nil
    }
  }
}
