#if DEBUG
  import Foundation
  import PutioCore

  enum HarnessDownloadsFixture: String, CaseIterable {
    case list
    case downloadingStates = "downloading-states"
    case attentionStates = "attention-states"
    case empty
    case offline

    static let launchArgument = "--putio-harness-downloads"
    static let mediaPrefix = "harness-media/"
    static let missingPackage = mediaPrefix + "missing.movpkg"

    static func parse(_ arguments: [String]) -> Self? {
      guard let flag = arguments.firstIndex(of: launchArgument),
        arguments.indices.contains(flag + 1)
      else { return nil }
      return Self(rawValue: arguments[flag + 1])
    }

    var concurrencyLimit: Int {
      self == .downloadingStates
        ? PutioOfflineQueue.concurrencyLimits.max() ?? PutioOfflineQueue.defaultConcurrencyLimit
        : PutioOfflineQueue.defaultConcurrencyLimit
    }

    func freeBytes(isPad: Bool) -> Int64 {
      switch self {
      case .downloadingStates: 3_100_000_000
      case .empty: isPad ? 217_000_000_000 : 149_300_000_000
      default: isPad ? 212_600_000_000 : 144_900_000_000
      }
    }

    func writeStore(at directory: URL, accountID: Int, now: Date, locked: Bool) {
      let fileManager = FileManager.default
      try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
      try? fileManager.removeItem(at: directory)
      let store = PutioOfflineStore(directory: directory, accountID: accountID)
      let items = items(now: now)
      try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
      try? store.save(items: items, concurrencyLimit: concurrencyLimit)
      try? store.recordPackages(at: items.compactMap(\.localPath))
      guard locked else { return }
      try? fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
    }

    func transferringIDs(now: Date) -> [PutioFileID] {
      items(now: now).filter(\.isActive).map(\.id)
    }

    func conversionProgress(now: Date) -> [PutioFileID: Double] {
      items(now: now).reduce(into: [:]) { progress, item in
        if case .converting(let value) = item.stage { progress[item.id] = value }
      }
    }

    static func playbackURL(mediaBaseURL: URL?) -> @MainActor (String) -> URL {
      { localPath in
        guard let mediaBaseURL, localPath.hasPrefix(mediaPrefix) else {
          return PutioOfflineQueue.localURL(for: localPath)
        }
        return mediaBaseURL.appending(path: String(localPath.dropFirst(mediaPrefix.count)))
      }
    }

    func items(now: Date) -> [PutioOfflineItem] {
      let calendar = Calendar.current
      let today = now
      let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
      let october24 = Self.latestOctober24(
        onOrBefore: calendar.date(byAdding: .day, value: -2, to: now) ?? now)
      switch self {
      case .list, .offline:
        return [
          Self.episode(2, .downloading(progress: 0.42), created: today),
          Self.episode(3, .queued, created: today),
          Self.connectionLostFourthEpisode(created: today),
          Self.finishedFirstEpisode(created: today),
          Self.sintel(created: yesterday),
          Self.treeRings(created: october24),
        ]
      case .downloadingStates:
        var waitingForNetwork = Self.episode(6, .downloading(progress: 0.42), created: today)
        waitingForNetwork.waitingForNetwork = true
        var removing = Self.finishedFirstEpisode(created: today)
        removing.isRemoving = true
        return [
          Self.episode(2, .downloading(progress: 0.42), created: today),
          Self.episode(5, .converting(progress: 0.12), created: today),
          Self.episode(3, .paused(progress: 0.42), created: today),
          waitingForNetwork,
          Self.episode(
            4, .downloading(progress: 0.06), created: today, bytes: Self.fourthEpisodeBytes),
          Self.episode(7, .queued, created: today),
          removing,
          Self.sintel(created: yesterday),
        ]
      case .attentionStates:
        var missing = Self.finishedFirstEpisode(created: today)
        missing.localPath = Self.missingPackage
        return [
          Self.episode(2, .failed(Self.connectionLost), created: today),
          Self.episode(3, .failed(.authentication), created: today),
          Self.episode(4, .failed(.notFound), created: today, bytes: Self.fourthEpisodeBytes),
          Self.episode(5, .failed(.storage), created: today),
          Self.episode(6, .failed(.download), created: today),
          missing,
          Self.sintel(created: yesterday),
          Self.treeRings(created: october24),
        ]
      case .empty:
        return []
      }
    }

    private static let seasonFolderID = PutioFileID(rawValue: 440)
    private static let episodeIDs = [1: 441, 2: 442, 3: 443, 4: 444, 5: 447, 6: 448, 7: 449]
    private static let fourthEpisodeBytes: Int64 = 3_400_000_000
    private static let connectionLost =
      PutioOfflineFailure.resolving(PutioRuntimeError.transient) ?? .download
    private static let english = PutioOfflineTrack(languageCode: "en", displayName: "English")
    private static let turkish = PutioOfflineTrack(languageCode: "tr", displayName: "Turkish")
    private static let englishSDH = PutioOfflineTrack(
      languageCode: "en", displayName: "English SDH")

    private static func episode(
      _ number: Int, _ stage: PutioOfflineItem.Stage, created: Date,
      bytes: Int64 = 3_300_000_000
    ) -> PutioOfflineItem {
      item(
        id: episodeIDs[number] ?? 0, parentID: seasonFolderID,
        name: "Blue.Lights.S04E0\(number).1080p.HDTV.H264-ORGANiC.mkv", kind: .video, stage: stage,
        created: created, estimatedBytes: bytes)
    }

    private static func connectionLostFourthEpisode(created: Date) -> PutioOfflineItem {
      var item = episode(
        4, .failed(connectionLost), created: created, bytes: fourthEpisodeBytes)
      item.failedProgress = 900_000_000 / Double(fourthEpisodeBytes)
      return item
    }

    private static func finishedFirstEpisode(created: Date) -> PutioOfflineItem {
      var item = item(
        id: 441, parentID: seasonFolderID,
        name: "Blue.Lights.S04E01.1080p.HDTV.H264-ORGANiC.mkv", kind: .video, stage: .completed,
        created: created, estimatedBytes: 3_200_000_000)
      item.localPath = mediaPrefix + "multi-audio/runtime-proof-multi.m3u8"
      item.storedBytes = 3_240_000_000
      item.storedAudioTracks = [english, turkish]
      item.storedSubtitleTracks = [english, englishSDH, turkish]
      item.resumePositionSeconds = 18 * 60 + 42
      return item
    }

    private static func sintel(created: Date) -> PutioOfflineItem {
      var item = item(
        id: 9_001, parentID: .root, name: "Sintel.2010.1080p.mkv", kind: .video,
        stage: .completed, created: created, estimatedBytes: 1_090_000_000)
      item.localPath = mediaPrefix + "multi-audio/runtime-proof-multi.m3u8"
      item.storedBytes = 1_090_000_000
      item.storedAudioTracks = [english]
      item.storedSubtitleTracks = [english]
      item.isWatched = true
      return item
    }

    private static func treeRings(created: Date) -> PutioOfflineItem {
      var item = item(
        id: 408, parentID: .root, name: "FFTT Tree Rings October 23, 2026.mp3", kind: .audio,
        stage: .completed, created: created, estimatedBytes: 48_000_000)
      item.localPath = mediaPrefix + "runtime-proof-audio.m4a"
      item.storedBytes = 48_000_000
      return item
    }

    private static func item(
      id: Int, parentID: PutioFileID, name: String, kind: PutioOfflineItem.Kind,
      stage: PutioOfflineItem.Stage, created: Date, estimatedBytes: Int64
    ) -> PutioOfflineItem {
      PutioOfflineItem(
        id: PutioFileID(rawValue: id), parentID: parentID, name: name, kind: kind,
        createdAt: created, stage: stage, localPath: nil, storedBytes: 0,
        storedAudioTracks: [], storedSubtitleTracks: [], resumePositionSeconds: 0,
        pendingPositionSeconds: nil, estimatedBytes: estimatedBytes)
    }

    private static func latestOctober24(onOrBefore date: Date) -> Date {
      let calendar = Calendar.current
      let year = calendar.component(.year, from: date)
      let thisYear = calendar.date(from: DateComponents(year: year, month: 10, day: 24))
      guard let thisYear, thisYear <= date else {
        return calendar.date(from: DateComponents(year: year - 1, month: 10, day: 24)) ?? date
      }
      return thisYear
    }
  }

  @MainActor
  final class HarnessFrozenOfflineEngine: PutioOfflineDownloadEngine {
    var onProgress: ((PutioFileID, Double) -> Void)?
    var onLocation: ((PutioFileID, URL) -> Void)?
    var onFinished: ((PutioFileID, Error?) -> Void)?
    var onCancelled: ((PutioFileID) -> Void)?
    var onPersistenceFailure: ((Error) -> Void)?
    private let transferring: [PutioFileID]

    init(transferring: [PutioFileID]) {
      self.transferring = transferring
    }

    func estimatedBytes(url: URL) async throws -> Int64 { 0 }
    func start(fileID: PutioFileID, url: URL, title: String) async throws {}
    func startOriginal(fileID: PutioFileID, url: URL) async throws {}
    func originalDirectory(for fileID: PutioFileID) -> URL {
      FileManager.default.temporaryDirectory.appending(
        path: "harness-frozen-originals/\(fileID.rawValue)", directoryHint: .isDirectory)
    }
    func pause(fileID: PutioFileID) {}
    func resume(fileID: PutioFileID) {}
    func cancel(fileID: PutioFileID) {}
    func restoreTasks() async -> [PutioFileID] { transferring }
    func stop() {}
    func retryPersisting() throws {}
  }
#endif
