#if DEBUG
  import Foundation
  import PutioCore
  import SwiftUI

  enum HarnessDownloadsFixture: String, CaseIterable {
    case list
    case selection
    case downloadingStates = "downloading-states"
    case attentionStates = "attention-states"
    case empty
    case offline
    case fileStates = "file-states"
    case fileWaiting = "file-waiting"

    static let launchArgument = "--putio-harness-downloads"
    static let mediaPrefix = "harness-media/"
    static let missingPackage = mediaPrefix + "missing.movpkg"
    static let removingPackage = mediaPrefix + "removing.movpkg"

    static func parse(_ arguments: [String]) -> Self? {
      guard let flag = arguments.firstIndex(of: launchArgument),
        arguments.indices.contains(flag + 1)
      else { return nil }
      return Self(rawValue: arguments[flag + 1])
    }

    static let windowWidthArgument = "--putio-harness-downloads-width"

    static func windowWidth(_ arguments: [String]) -> Double? {
      guard let flag = arguments.firstIndex(of: windowWidthArgument),
        arguments.indices.contains(flag + 1)
      else { return nil }
      return Double(arguments[flag + 1])
    }

    var concurrencyLimit: Int {
      self == .downloadingStates ? 4 : PutioOfflineQueue.defaultConcurrencyLimit
    }

    var removingIDs: [PutioFileID] {
      self == .downloadingStates ? [Self.firstEpisodeID] : []
    }

    var deletePackages: PutioOfflinePackageDeletion? {
      guard self == .downloadingStates else { return nil }
      return { urls in
        guard urls.contains(where: { $0.lastPathComponent == "removing.movpkg" }) else { return }
        while !Task.isCancelled { try? await Task.sleep(for: .seconds(3_600)) }
      }
    }

    func freeBytes(isPad: Bool) -> Int64 {
      switch self {
      case .downloadingStates, .fileWaiting: 3_100_000_000
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

    func conversions(now: Date) -> [PutioFileID: PutioVideoConversionStatus] {
      items(now: now).reduce(into: [:]) { statuses, item in
        switch item.stage {
        case .waitingToConvert: statuses[item.id] = .queued
        case .converting(let value): statuses[item.id] = .converting(progress: value)
        default: break
        }
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
      case .selection:
        return [
          Self.episode(2, .downloading(progress: 0.42), created: today),
          Self.episode(3, .paused(progress: 0.42), created: today),
          Self.connectionLostFourthEpisode(created: today),
          Self.finishedFirstEpisode(created: today),
          Self.sintel(created: yesterday),
          Self.treeRings(created: october24),
        ]
      case .downloadingStates:
        var removing = Self.finishedFirstEpisode(created: today)
        removing.localPath = Self.removingPackage
        return [
          Self.episode(2, .downloading(progress: 0.42), created: today),
          Self.episode(5, .converting(progress: 0.12), created: today),
          Self.episode(8, .waitingToConvert, created: today),
          Self.episode(3, .paused(progress: 0.42), created: today),
          Self.episode(6, .waitingForNetwork(progress: 0.42), created: today),
          Self.episode(4, .waitingForStorage, created: today, bytes: Self.fourthEpisodeBytes),
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
      case .fileStates:
        return [
          Self.finishedFirstEpisode(created: today),
          Self.episode(2, .downloading(progress: 0.4243), created: today),
          Self.episode(3, .converting(progress: 0.12), created: today, bytes: 3_100_000_000),
          Self.episode(4, .paused(progress: 0.2648), created: today, bytes: 3_400_000_000),
          Self.episode(5, .queued, created: today),
          Self.episode(6, .failed(Self.connectionLost), created: today, bytes: 3_400_000_000),
        ]
      case .fileWaiting:
        var missing = Self.episode(4, .completed, created: today, bytes: 3_400_000_000)
        missing.localPath = Self.missingPackage
        missing.storedBytes = 3_400_000_000
        return [
          Self.finishedFirstEpisode(created: today),
          Self.episode(2, .waitingForNetwork(progress: 0), created: today),
          Self.episode(3, .waitingForStorage, created: today, bytes: 3_400_000_000),
          missing,
        ]
      case .empty:
        return []
      }
    }

    private static let seasonFolderID = PutioFileID(rawValue: 440)
    private static let firstEpisodeID = PutioFileID(rawValue: 441)
    private static let fourthEpisodeBytes: Int64 = 3_400_000_000
    private static let episodeIDs = [
      1: 441, 2: 442, 3: 443, 4: 444, 5: 447, 6: 448, 7: 449, 8: 450,
    ]
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

  struct HarnessStoredPlaybackProbe: View {
    static let fileID = 412

    var body: some View {
      TimelineView(.periodic(from: .now, by: 0.25)) { _ in
        ZStack {
          probe(
            "Requests for the stored file while the network is cut",
            value: HarnessSeededAPI.cutFileRequestCount(fileID: Self.fileID),
            identifier: "downloads.cut-requests")
          probe(
            "Stored file position on put.io",
            value: HarnessSeededAPI.playbackPosition(fileID: Self.fileID),
            identifier: "downloads.seeded-position")
        }
      }
    }

    private func probe(_ label: String, value: Int, identifier: String) -> some View {
      Color.clear
        .frame(width: 1, height: 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(value)")
        .accessibilityIdentifier(identifier)
        .allowsHitTesting(false)
    }
  }

  @MainActor
  enum HarnessDownloadsNetwork {
    static let restoreNotification = "io.put.harness.downloads-network-restore"
    static let syncedFileID = 441
    private static weak var queue: PutioOfflineQueue?

    static func cut(_ queue: PutioOfflineQueue) {
      self.queue = queue
      queue.setOnline(false)
      CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(), nil,
        { _, _, _, _, _ in Task { @MainActor in HarnessDownloadsNetwork.restore() } },
        restoreNotification as CFString, nil, .deliverImmediately)
    }

    static func restore() {
      HarnessSeededAPI.restoreDownloadsNetwork()
      queue?.setOnline(true)
    }
  }

  struct HarnessDownloadsSyncProbe: View {
    private let isCut = HarnessDownloadsFixture.parse(HarnessLaunch.arguments) == .offline

    var body: some View {
      if isCut {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
          Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Download position on put.io")
            .accessibilityValue(
              "\(HarnessSeededAPI.playbackPosition(fileID: HarnessDownloadsNetwork.syncedFileID))"
            )
            .accessibilityIdentifier("downloads.synced-position")
            .allowsHitTesting(false)
        }
      }
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
