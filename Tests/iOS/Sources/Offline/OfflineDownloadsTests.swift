import AVFoundation
import Foundation
import PutioCore
import XCTest

@testable import Putio

@MainActor
final class OfflineDownloadsTests: XCTestCase {
  private final class FakeEngine: PutioOfflineDownloadEngine {
    var onProgress: ((PutioFileID, Double) -> Void)?
    var onLocation: ((PutioFileID, URL) -> Void)?
    var onFinished: ((PutioFileID, Error?) -> Void)?
    var onCancelled: ((PutioFileID) -> Void)?
    var onPersistenceFailure: ((Error) -> Void)?
    var started: [(PutioFileID, URL)] = []
    var startedOriginals: [(PutioFileID, URL)] = []
    var originalsRoot = FileManager.default.temporaryDirectory.appending(
      path: "offline-originals-\(UUID().uuidString)")
    var paused: [PutioFileID] = []
    var resumed: [PutioFileID] = []
    var cancelled: [PutioFileID] = []
    var alive: [PutioFileID] = []
    var estimates: [Int: Int64] = [:]
    var estimateError: Error?
    var replayCompletionOnRestore: PutioFileID?
    var restoreGate: AsyncGate?
    var attached: Set<PutioFileID> = []
    var suspendedTasks: [PutioFileID] = []

    func estimatedBytes(url: URL) async throws -> Int64 {
      if let estimateError { throw estimateError }
      return Int(url.deletingPathExtension().lastPathComponent).flatMap { estimates[$0] } ?? 1_000
    }
    func start(fileID: PutioFileID, url: URL, title: String) async throws {
      started.append((fileID, url))
      attached.insert(fileID)
    }
    func startOriginal(fileID: PutioFileID, url: URL) async throws {
      startedOriginals.append((fileID, url))
      attached.insert(fileID)
    }
    func originalDirectory(for fileID: PutioFileID) -> URL {
      originalsRoot.appending(path: "\(fileID.rawValue)", directoryHint: .isDirectory)
    }
    func pause(fileID: PutioFileID) {
      paused.append(fileID)
      if attached.contains(fileID) { suspendedTasks.append(fileID) }
    }
    func resume(fileID: PutioFileID) { resumed.append(fileID) }
    func cancel(fileID: PutioFileID) {
      cancelled.append(fileID)
      onCancelled?(fileID)
    }
    func restoreTasks() async -> [PutioFileID] {
      if let restoreGate { await restoreGate.wait() }
      attached.formUnion(alive)
      if let id = replayCompletionOnRestore { onFinished?(id, nil) }
      return alive
    }
    func stop() {}
    func retryPersisting() throws {}

    func finish(_ id: PutioFileID, at directory: URL) throws {
      let location = directory.appending(path: "\(id.rawValue).movpkg")
      try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
      try Data(count: 512).write(to: location.appending(path: "segment.bin"))
      onLocation?(id, location)
      onFinished?(id, nil)
    }

    func finishOriginal(_ id: PutioFileID) throws {
      try Data(count: 2_048).write(
        to: PutioOfflineOriginalPackage.transferURL(in: originalDirectory(for: id)))
      onFinished?(id, nil)
    }
  }

  /// A one-shot latch for tests that interleave a queue action with an
  /// in-flight resolution.
  private actor AsyncGate {
    private var opened = false
    private var arrivals = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
      arrivals += 1
      if opened { return }
      await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilEntered() async throws {
      let deadline = ContinuousClock.now + .seconds(5)
      while arrivals == 0 {
        guard ContinuousClock.now < deadline else {
          throw GateTimeout()
        }
        try await Task.sleep(for: .milliseconds(1))
      }
    }

    private struct GateTimeout: Error {}

    func open() {
      opened = true
      for waiter in waiters { waiter.resume() }
      waiters = []
    }
  }

  /// An engine whose start() blocks on the gate, so a pause can land while
  /// the engine is still creating its task.
  private final class SlowStartEngine: PutioOfflineDownloadEngine {
    var onProgress: ((PutioFileID, Double) -> Void)?
    var onLocation: ((PutioFileID, URL) -> Void)?
    var onFinished: ((PutioFileID, Error?) -> Void)?
    var onCancelled: ((PutioFileID) -> Void)?
    var onPersistenceFailure: ((Error) -> Void)?
    var started: [PutioFileID] = []
    var resumed: [PutioFileID] = []
    var cancelled: [PutioFileID] = []
    var reportsCancellation = true
    private let gate: AsyncGate

    init(gate: AsyncGate) { self.gate = gate }

    func estimatedBytes(url: URL) async throws -> Int64 { 0 }
    func start(fileID: PutioFileID, url: URL, title: String) async throws {
      await gate.wait()
      started.append(fileID)
    }
    func startOriginal(fileID: PutioFileID, url: URL) async throws {
      await gate.wait()
      started.append(fileID)
    }
    func originalDirectory(for fileID: PutioFileID) -> URL {
      FileManager.default.temporaryDirectory.appending(path: "slow-original-\(fileID.rawValue)")
    }
    func pause(fileID: PutioFileID) {}
    func resume(fileID: PutioFileID) { resumed.append(fileID) }
    func cancel(fileID: PutioFileID) {
      cancelled.append(fileID)
      if reportsCancellation { onCancelled?(fileID) }
    }
    func restoreTasks() async -> [PutioFileID] { [] }
    func stop() {}
    func retryPersisting() throws {}
  }

  private var gates: [AsyncGate] = []

  @MainActor private final class ResolutionCount {
    var value = 0
  }

  private func makeGate() -> AsyncGate {
    let gate = AsyncGate()
    gates.append(gate)
    return gate
  }

  private var directory: URL!
  private var engine: FakeEngine!
  private var reports: [(Int, Int)] = []
  private var reportShouldFail = false
  private var resolutions: [Int: [PutioPlaybackResolution]] = [:]
  private var conversionStatuses: [PutioVideoConversionStatus] = []
  private var conversionStarts = 0
  private var failuresNotified: [(Int, PutioOfflineFailure)] = []
  private var runtimeCalls: [String] = []
  private var freeBytes: Int64 = 0
  private var serverWatched: [Int: Bool] = [:]

  override func setUp() async throws {
    directory = FileManager.default.temporaryDirectory.appending(
      path: "offline-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    engine = FakeEngine()
    engine.originalsRoot = directory.appending(path: "originals", directoryHint: .isDirectory)
    reports = []
    reportShouldFail = false
    resolutions = [:]
    conversionStatuses = []
    conversionStarts = 0
    failuresNotified = []
    runtimeCalls = []
    serverWatched = [:]
  }

  override func tearDown() async throws {
    for gate in gates { await gate.open() }
    gates = []
    try? FileManager.default.removeItem(at: directory)
  }

  func testTheTabGroupsDownloadsIntoSectionsWithQueuePlaces() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func item(_ id: Int, _ stage: PutioOfflineItem.Stage, daysAgo: Int = 0) -> PutioOfflineItem {
      PutioOfflineItem(
        id: PutioFileID(rawValue: id), parentID: .root, name: "\(id).mkv", kind: .video,
        createdAt: now.addingTimeInterval(-Double(daysAgo) * 86_400), stage: stage,
        localPath: nil, storedBytes: 0, storedAudioTracks: [],
        storedSubtitleTracks: [], resumePositionSeconds: 0, pendingPositionSeconds: nil,
        estimatedBytes: 3_300_000_000)
    }
    let sections = PutioOfflineSections([
      item(1, .completed, daysAgo: 3),
      item(2, .queued),
      item(3, .failed(.download)),
      item(4, .downloading(progress: 0.42)),
      item(5, .completed, daysAgo: 1),
      item(6, .queued),
      item(7, .paused(progress: 0.1)),
    ])

    XCTAssertEqual(sections.sections.map(\.kind), [.downloading, .attention, .onDevice])
    XCTAssertEqual(sections.sections[0].items.map(\.id.rawValue), [2, 4, 6, 7])
    XCTAssertEqual(sections.sections[1].items.map(\.id.rawValue), [3])
    XCTAssertEqual(sections.sections[2].items.map(\.id.rawValue), [5, 1])
    XCTAssertEqual(sections.queuePositions[PutioFileID(rawValue: 6)], 2)
    XCTAssertEqual(
      item(6, .queued).downloadState(
        queuePosition: sections.queuePositions[PutioFileID(rawValue: 6)]),
      .queued(position: 2))
    XCTAssertEqual(
      item(4, .downloading(progress: 0.42)).downloadState(queuePosition: nil),
      .downloading(receivedBytes: 1_386_000_000, totalBytes: 3_300_000_000))
    XCTAssertEqual(
      item(3, .failed(.notFound)).downloadState(queuePosition: nil),
      .failed(reason: "No longer available", canRetry: false))
    XCTAssertEqual(
      PutioOfflineSections([item(1, .completed)]).sections.map(\.kind), [.onDevice])
    XCTAssertTrue(PutioOfflineSections([]).sections.isEmpty)
  }

  func testNextVideoFollowsTheFolderNameOrderAmongDownloadedVideosOnly() async throws {
    let store = PutioOfflineStore(directory: directory)
    let parent = PutioFileID(rawValue: 900)
    func item(
      _ id: Int, _ name: String, parent: PutioFileID = parent, kind: PutioOfflineItem.Kind = .video,
      completed: Bool = true
    ) throws -> PutioOfflineItem {
      let location = directory.appending(path: "\(id).movpkg")
      try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
      try Data(count: 64).write(to: location.appending(path: "seg.bin"))
      return PutioOfflineItem(
        id: PutioFileID(rawValue: id), parentID: parent, name: name, kind: kind, createdAt: .now,
        stage: completed ? .completed : .downloading(progress: 0.5),
        localPath: completed ? location.path : nil, storedBytes: 64, storedAudioTracks: [],
        storedSubtitleTracks: [], resumePositionSeconds: 0,
        pendingPositionSeconds: nil, estimatedBytes: 64)
    }
    try store.save(
      items: [
        try item(1, "Episode 1.mp4"),
        try item(10, "Episode 10.mp4"),
        try item(2, "Episode 2.mp4", completed: false),
        try item(3, "Episode 3.mp4"),
        try item(4, "Episode 2.5.mp4", parent: .root),
        try item(5, "Episode 2.mp3", kind: .audio),
      ], concurrencyLimit: 2)
    let queue = makeQueue()
    await queue.restore()
    await settle()

    XCTAssertEqual(
      queue.nextVideo(after: PutioFileID(rawValue: 1)),
      PutioNextVideo(id: PutioFileID(rawValue: 3), parentID: parent, name: "Episode 3.mp4"),
      "skips the unfinished episode 2 and orders 3 before 10")
    XCTAssertEqual(
      queue.nextVideo(after: PutioFileID(rawValue: 3))?.id, PutioFileID(rawValue: 10))
    XCTAssertNil(
      queue.nextVideo(after: PutioFileID(rawValue: 10)), "the last episode has no successor")
    XCTAssertNil(
      queue.nextVideo(after: PutioFileID(rawValue: 999)), "an unknown file has no folder")
  }

  private func makeQueue(
    availableBytes: Int64 = 10_000_000_000, isLive: @escaping @MainActor () -> Bool = { true },
    engine: (any PutioOfflineDownloadEngine)? = nil,
    availableStorage: (@MainActor () -> Int64)? = nil,
    deletePackages: PutioOfflinePackageDeletion? = nil,
    watchedChanges: AsyncStream<PutioWatchedChange>? = nil,
    watchedStatus: PutioOfflineWatchedStatus? = nil
  ) -> PutioOfflineQueue {
    PutioOfflineQueue(
      store: PutioOfflineStore(directory: directory),
      engine: engine ?? self.engine,
      conversionPollInterval: .zero,
      sleep: { _ in },
      availableStorage: availableStorage ?? { availableBytes },
      readTracks: { _ in
        ([PutioOfflineTrack(languageCode: "en", displayName: "English")], [])
      },
      notifyFailure: { self.failuresNotified.append(($0.id.rawValue, $1)) },
      isPlayable: { url in
        !url.lastPathComponent.hasPrefix("partial")
          && PutioOfflineQueue.directorySize(url, fileManager: .default) > 0
      },
      resolve: { fileID, _ in
        self.runtimeCalls.append("resolve \(fileID.rawValue)")
        if var queued = self.resolutions[fileID.rawValue], !queued.isEmpty {
          let next = queued.removeFirst()
          self.resolutions[fileID.rawValue] = queued
          return next
        }
        return .ready(
          PutioPlaybackSource(
            url: URL(string: "https://media.test/\(fileID.rawValue).m3u8")!, startFromSeconds: 7))
      },
      startConversion: { fileID in
        self.runtimeCalls.append("convert \(fileID.rawValue)")
        self.conversionStarts += 1
      },
      conversionStatus: { fileID in
        self.runtimeCalls.append("conversion status \(fileID.rawValue)")
        return self.conversionStatuses.isEmpty ? .completed : self.conversionStatuses.removeFirst()
      },
      reportPosition: { fileID, seconds in
        self.runtimeCalls.append("position \(fileID.rawValue)")
        if self.reportShouldFail { throw PutioRuntimeError.transient }
        self.reports.append((fileID.rawValue, seconds))
      },
      isLive: isLive,
      deletePackages: deletePackages,
      watchedChanges: watchedChanges,
      watchedStatus: watchedStatus
    )
  }

  private func settle() async {
    for _ in 0..<40 { await Task.yield() }
    try? await Task.sleep(for: .milliseconds(50))
    for _ in 0..<40 { await Task.yield() }
  }

  func testEachMethodDownloadsItsOwnSourceAndKeepsItAcrossRelaunch() async throws {
    let original = URL(string: "https://api.test/v2/files/412/download")!
    let subtitles = [("en", "English", "eng"), ("tr", "Turkish", "tur")].map {
      PutioCastSubtitle(
        key: $0.0, language: $0.1, languageCode: $0.2, name: "\($0.1).srt",
        source: .openSubtitles, url: URL(string: "https://api.test/v2/files/412/subtitles/\($0.0)")!
      )
    }
    func makeQueue() -> PutioOfflineQueue {
      PutioOfflineQueue(
        store: PutioOfflineStore(directory: directory), engine: engine,
        conversionPollInterval: .zero, sleep: { _ in }, availableStorage: { 10_000_000_000 },
        readTracks: { _ in ([PutioOfflineTrack(languageCode: "en", displayName: "English")], []) },
        isPlayable: { _ in true },
        resolve: { fileID, _ in
          .ready(
            PutioPlaybackSource(
              url: URL(string: "https://media.test/\(fileID.rawValue).m3u8")!, startFromSeconds: 0))
        },
        resolveOriginal: { fileID in
          PutioOfflineOriginal(
            file: PutioFileDownloadSource(
              id: fileID, kind: .video, name: "Movie.mp4", url: original),
            subtitles: subtitles, startFromSeconds: 734, defaultSubtitleKey: "tr")
        },
        fetchSubtitle: { Data("WEBVTT \($0.lastPathComponent)".utf8) },
        startConversion: { _ in }, conversionStatus: { _ in .completed },
        reportPosition: { _, _ in })
    }
    let standard = PutioFileID(rawValue: 411)
    let directPlay = PutioFileID(rawValue: 412)
    let audio = PutioFileID(rawValue: 408)
    let queue = makeQueue()
    queue.enqueue(
      fileID: standard, parentID: .root, name: "Episode.mkv", kind: .video, estimatedBytes: 1_000,
      playbackMethod: .standard)
    queue.enqueue(
      fileID: directPlay, parentID: .root, name: "Movie.mp4", kind: .video,
      estimatedBytes: 2_048, playbackMethod: .directPlay)
    queue.enqueue(
      fileID: audio, parentID: .root, name: "Song.mp3", kind: .audio, playbackMethod: .directPlay)
    await settle()

    XCTAssertEqual(Set(engine.started.map(\.0)), [standard, audio])
    XCTAssertEqual(engine.started.first { $0.0 == standard }?.1.pathExtension, "m3u8")
    XCTAssertEqual(engine.startedOriginals.map(\.0), [directPlay])
    XCTAssertEqual(engine.startedOriginals.first?.1, original)
    let package = engine.originalDirectory(for: directPlay)
    let stored = PutioOfflineOriginalPackage.subtitles(in: package)
    XCTAssertEqual(stored.map(\.languageCode), ["en", "tr"])
    XCTAssertEqual(
      try stored.map {
        try String(contentsOf: package.appending(path: $0.fileName), encoding: .utf8)
      },
      ["WEBVTT en", "WEBVTT tr"])

    try engine.finishOriginal(directPlay)
    try engine.finish(standard, at: directory)
    await settle()
    let downloaded = try XCTUnwrap(queue.item(for: directPlay))
    XCTAssertEqual(downloaded.stage, .completed)
    XCTAssertEqual(downloaded.storedSubtitleTracks.map(\.languageCode), ["en", "tr"])
    let source = try XCTUnwrap(queue.localSource(for: directPlay))
    XCTAssertEqual(source.url.lastPathComponent, "original.mp4")
    XCTAssertEqual(source.startFromSeconds, 734)
    XCTAssertEqual(try Data(contentsOf: source.url).count, 2_048)
    let playback = try XCTUnwrap(source.original, "a Direct play download lost the engine")
    XCTAssertEqual(playback.player, .engine)
    XCTAssertEqual(playback.subtitles.map(\.languageCode), ["en", "tr"])
    XCTAssertEqual(playback.subtitles.map(\.language), ["English", "Turkish"])
    XCTAssertEqual(
      try playback.subtitles.map { try String(contentsOf: $0.url, encoding: .utf8) },
      ["WEBVTT en", "WEBVTT tr"])
    XCTAssertEqual(
      playback.subtitles.first { $0.key == playback.defaultSubtitleKey }?.languageCode, "tr",
      "a stored original lost put.io's default subtitle")
    let hls = try XCTUnwrap(queue.localSource(for: standard))
    XCTAssertEqual(hls.url.pathExtension, "movpkg")
    XCTAssertNil(hls.original, "a Standard download left AVPlayer")

    let relaunched = makeQueue()
    XCTAssertEqual(relaunched.item(for: standard)?.playbackMethod, .standard)
    XCTAssertEqual(relaunched.item(for: directPlay)?.playbackMethod, .directPlay)
    XCTAssertNil(relaunched.item(for: audio)?.playbackMethod)
    XCTAssertEqual(relaunched.localSource(for: directPlay)?.url, source.url)
  }

  func testAStoredOriginalWithoutADefaultSubtitleStartsWithNone() throws {
    let subtitles = ["en", "tr"].map {
      (
        subtitle: PutioCastSubtitle(
          key: $0, language: $0, languageCode: $0, name: $0, source: .openSubtitles,
          url: URL(string: "https://api.test/v2/files/412/subtitles/\($0)")!),
        data: Data("WEBVTT".utf8)
      )
    }
    try PutioOfflineOriginalPackage.store(subtitles, defaultKey: nil, in: directory)
    let stored = PutioOfflineOriginalPackage.playbackSubtitles(in: directory)
    XCTAssertEqual(stored.subtitles.count, 2)
    XCTAssertNil(stored.defaultKey, "a stored original invented a default subtitle")
  }

  func testAFinishedOriginalIsPlayableWhenTheEngineOrAVPlayerDecodesIt() {
    func finished(_ name: String, _ method: PutioPlaybackMethod, enginePlays: Bool? = nil)
      -> PutioOfflineItem
    {
      PutioOfflineItem(
        id: PutioFileID(rawValue: 412), parentID: .root, name: name, kind: .video,
        createdAt: .now, stage: .completed, localPath: "/tmp/412", storedBytes: 1,
        storedAudioTracks: [], storedSubtitleTracks: [], resumePositionSeconds: 0,
        pendingPositionSeconds: nil, estimatedBytes: 1, playbackMethod: method,
        enginePlaysOriginal: enginePlays)
    }
    XCTAssertTrue(finished("Movie.mkv", .directPlay).isPlayable)
    XCTAssertTrue(finished("Movie.mkv", .directPlay, enginePlays: true).isPlayable)
    XCTAssertTrue(finished("Movie.MP4", .directPlay).isPlayable)
    XCTAssertTrue(finished("Movie.mkv", .standard).isPlayable)
    XCTAssertFalse(finished("Movie.mkv", .directPlay, enginePlays: false).isPlayable)
    XCTAssertTrue(finished("Movie.MOV", .directPlay, enginePlays: false).isPlayable)
    XCTAssertTrue(finished("Movie.MOV", .directPlay, enginePlays: false).playsOriginalInAVPlayer)
    XCTAssertTrue(
      finished("Movie.mp4", .directPlay).playsOriginalInAVPlayer,
      "an original stored before the engine check left AVPlayer")
    XCTAssertFalse(finished("Movie.mp4", .directPlay, enginePlays: true).playsOriginalInAVPlayer)
  }

  func testConcurrencyLimitBoundsActiveDownloadsAcrossMixedKinds() async throws {
    let queue = makeQueue()
    queue.setConcurrencyLimit(2)
    for (id, kind) in [(1, PutioOfflineItem.Kind.video), (2, .audio), (3, .video)] {
      queue.enqueue(fileID: PutioFileID(rawValue: id), parentID: .root, name: "\(id)", kind: kind)
    }
    await settle()
    XCTAssertEqual(engine.started.map(\.0.rawValue), [1, 2])
    XCTAssertEqual(queue.item(for: PutioFileID(rawValue: 3))?.stage, .queued)

    try engine.finish(PutioFileID(rawValue: 1), at: directory)
    await settle()
    XCTAssertEqual(engine.started.map(\.0.rawValue), [1, 2, 3])
    XCTAssertEqual(queue.item(for: PutioFileID(rawValue: 1))?.stage, .completed)
    XCTAssertEqual(queue.item(for: PutioFileID(rawValue: 1))?.resumePositionSeconds, 7)
    XCTAssertGreaterThan(queue.storedBytes, 0)
  }

  func testANewLimitAppliesToTheRunningQueueAtOnce() async throws {
    let queue = makeQueue()
    queue.setConcurrencyLimit(4)
    let ids = (1...5).map { PutioFileID(rawValue: $0) }
    for id in ids {
      queue.enqueue(fileID: id, parentID: .root, name: "\(id.rawValue)", kind: .video)
    }
    await settle()
    for id in ids.prefix(4) { engine.onProgress?(id, 0.3) }
    XCTAssertEqual(queue.items.filter(\.isActive).map(\.id), Array(ids.prefix(4)))

    queue.setConcurrencyLimit(1)
    await settle()
    XCTAssertEqual(queue.items.filter(\.isActive).map(\.id), [ids[0]], "one download runs")
    XCTAssertEqual(engine.paused, Array(ids[1...3]))
    for id in ids[1...3] {
      XCTAssertEqual(queue.item(for: id)?.stage, .paused(progress: 0.3))
      XCTAssertTrue(queue.isWaitingForSlot(id), "\(id.rawValue) does not wait for a slot")
    }
    XCTAssertEqual(queue.item(for: ids[4])?.stage, .queued)

    queue.setConcurrencyLimit(4)
    await settle()
    XCTAssertEqual(engine.resumed, Array(ids[1...3]), "waiting downloads resume in place")
    XCTAssertEqual(queue.items.filter(\.isActive).map(\.id), Array(ids.prefix(4)))
    XCTAssertEqual(queue.item(for: ids[4])?.stage, .queued)

    try engine.finish(ids[0], at: directory)
    await settle()
    XCTAssertEqual(engine.started.map(\.0), ids, "the freed slot starts the next in line")
  }

  func testDownloadsWaitingForASlotStillStartAfterARelaunch() async throws {
    let queue = makeQueue()
    queue.setConcurrencyLimit(3)
    let ids = (1...3).map { PutioFileID(rawValue: $0) }
    for id in ids {
      queue.enqueue(fileID: id, parentID: .root, name: "\(id.rawValue)", kind: .video)
    }
    await settle()
    for id in ids { engine.onProgress?(id, 0.3) }
    queue.setConcurrencyLimit(1)
    await settle()

    let relaunched = FakeEngine()
    relaunched.alive = [ids[0], ids[1]]
    engine = relaunched
    let restored = makeQueue()
    await restored.restore()
    await settle()
    XCTAssertEqual(restored.concurrencyLimit, 1)
    XCTAssertTrue(restored.isWaitingForSlot(ids[1]), "the kept task no longer waits")
    XCTAssertEqual(restored.item(for: ids[2])?.stage, .queued, "the lost task is not re-queued")

    try relaunched.finish(ids[0], at: directory)
    await settle()
    XCTAssertEqual(relaunched.resumed, [ids[1]], "the kept task never resumed")
    try relaunched.finish(ids[1], at: directory)
    await settle()
    XCTAssertEqual(relaunched.started.map(\.0), [ids[2]], "the lost task never restarted")
  }

  func testWaitingDownloadsResumeInTheOrderTheyWereAdded() async throws {
    let queue = makeQueue()
    queue.setConcurrencyLimit(4)
    let ids = (1...4).map { PutioFileID(rawValue: $0) }
    for id in ids {
      queue.enqueue(fileID: id, parentID: .root, name: "\(id.rawValue)", kind: .video)
    }
    await settle()
    for id in ids { engine.onProgress?(id, 0.3) }
    queue.setConcurrencyLimit(3)
    queue.setConcurrencyLimit(1)
    try engine.finish(ids[0], at: directory)
    await settle()
    XCTAssertEqual(engine.resumed, [ids[1]], "a later download jumped the line")
  }

  func testAFinishReplayedOnRelaunchStillResumesTheWaiters() async throws {
    let queue = makeQueue()
    queue.setConcurrencyLimit(2)
    let ids = (1...2).map { PutioFileID(rawValue: $0) }
    for id in ids {
      queue.enqueue(fileID: id, parentID: .root, name: "\(id.rawValue)", kind: .video)
    }
    await settle()
    for id in ids { engine.onProgress?(id, 0.3) }
    queue.setConcurrencyLimit(1)
    await settle()

    let relaunched = FakeEngine()
    relaunched.alive = [ids[1]]
    relaunched.replayCompletionOnRestore = ids[0]
    engine = relaunched
    let restored = makeQueue()
    await restored.restore()
    await settle()
    XCTAssertEqual(relaunched.resumed, [ids[1]], "the waiter was dropped during restore")
  }

  func testARequeuedDownloadStartsBeforeALaterWaitingOne() async throws {
    let gate = makeGate()
    let queue = PutioOfflineQueue(
      store: PutioOfflineStore(directory: directory), engine: engine, conversionPollInterval: .zero,
      sleep: { _ in }, availableStorage: { 1_000_000_000 },
      readTracks: { _ in ([], []) },
      resolve: { fileID, _ in
        if fileID.rawValue == 2 { await gate.wait() }
        return .ready(
          PutioPlaybackSource(url: URL(string: "https://media.test/x.m3u8")!, startFromSeconds: 0))
      },
      startConversion: { _ in }, conversionStatus: { _ in .completed },
      reportPosition: { _, _ in })
    queue.setConcurrencyLimit(3)
    let ids = (1...3).map { PutioFileID(rawValue: $0) }
    for id in ids {
      queue.enqueue(fileID: id, parentID: .root, name: "\(id.rawValue)", kind: .video)
    }
    await settle()
    queue.setConcurrencyLimit(1)
    await gate.open()
    await settle()
    XCTAssertEqual(queue.item(for: ids[1])?.stage, .queued)
    XCTAssertTrue(queue.isWaitingForSlot(ids[2]))

    try engine.finish(ids[0], at: directory)
    await settle()
    XCTAssertEqual(engine.started.map(\.0), [ids[0], ids[2], ids[1]])
    XCTAssertTrue(engine.resumed.isEmpty, "the later download jumped the line")
  }

  func testAWaiterWhoseTaskEndedFinishedKeepsItsPackageOnRelaunch() async throws {
    let queue = makeQueue()
    queue.setConcurrencyLimit(2)
    let ids = (1...2).map { PutioFileID(rawValue: $0) }
    for id in ids {
      queue.enqueue(fileID: id, parentID: .root, name: "\(id.rawValue)", kind: .video)
    }
    await settle()
    let location = directory.appending(path: "2.movpkg")
    try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
    try Data(count: 512).write(to: location.appending(path: "segment.bin"))
    engine.onLocation?(ids[1], location)
    engine.onProgress?(ids[1], 0.9)
    queue.setConcurrencyLimit(1)
    await settle()
    XCTAssertTrue(queue.isWaitingForSlot(ids[1]))

    let relaunched = FakeEngine()
    relaunched.alive = [ids[0]]
    let restored = PutioOfflineQueue(
      store: PutioOfflineStore(directory: directory), engine: relaunched,
      conversionPollInterval: .zero, sleep: { _ in }, availableStorage: { 1_000_000_000 },
      readTracks: { _ in ([], []) }, isPlayable: { _ in true },
      resolve: { _, _ in
        .ready(
          PutioPlaybackSource(url: URL(string: "https://media.test/x.m3u8")!, startFromSeconds: 0))
      },
      startConversion: { _ in }, conversionStatus: { _ in .completed },
      reportPosition: { _, _ in })
    await restored.restore()
    await settle()
    XCTAssertEqual(restored.item(for: ids[1])?.stage, .completed)
    XCTAssertTrue(relaunched.started.isEmpty, "the finished package was downloaded again")
    XCTAssertTrue(FileManager.default.fileExists(atPath: location.path))
  }

  func testAWaiterWhoseTaskFailsGoesBackInLine() async throws {
    let queue = makeQueue()
    queue.setConcurrencyLimit(2)
    let ids = (1...2).map { PutioFileID(rawValue: $0) }
    for id in ids {
      queue.enqueue(fileID: id, parentID: .root, name: "\(id.rawValue)", kind: .video)
    }
    await settle()
    queue.setConcurrencyLimit(1)
    engine.onFinished?(ids[1], URLError(.networkConnectionLost))
    XCTAssertEqual(queue.item(for: ids[1])?.stage, .queued)

    try engine.finish(ids[0], at: directory)
    await settle()
    XCTAssertEqual(engine.started.map(\.0), [ids[0], ids[1], ids[1]], "the waiter never restarted")
  }

  func testADownloadStillStartingWhenItYieldsGoesBackInLine() async {
    let gate = makeGate()
    let slow = SlowStartEngine(gate: gate)
    slow.reportsCancellation = false
    let queue = PutioOfflineQueue(
      store: PutioOfflineStore(directory: directory), engine: slow, conversionPollInterval: .zero,
      sleep: { _ in }, availableStorage: { 1_000_000_000 },
      resolve: { _, _ in
        .ready(
          PutioPlaybackSource(url: URL(string: "https://media.test/x.m3u8")!, startFromSeconds: 0))
      },
      startConversion: { _ in }, conversionStatus: { _ in .completed },
      reportPosition: { _, _ in })
    queue.setConcurrencyLimit(2)
    queue.enqueue(fileID: PutioFileID(rawValue: 1), parentID: .root, name: "a", kind: .video)
    queue.enqueue(fileID: PutioFileID(rawValue: 2), parentID: .root, name: "b", kind: .video)
    await settle()
    queue.setConcurrencyLimit(1)
    await gate.open()
    await settle()
    XCTAssertEqual(slow.cancelled, [PutioFileID(rawValue: 2)])
    XCTAssertEqual(queue.item(for: PutioFileID(rawValue: 2))?.stage, .queued)
    XCTAssertFalse(queue.isWaitingForSlot(PutioFileID(rawValue: 2)))
  }

  func testAWaiterThatFinishesAnywayKeepsItsPackage() async throws {
    let gate = makeGate()
    let queue = PutioOfflineQueue(
      store: PutioOfflineStore(directory: directory), engine: engine, conversionPollInterval: .zero,
      sleep: { _ in }, availableStorage: { 1_000_000_000 },
      readTracks: { _ in
        await gate.wait()
        return ([], [])
      },
      resolve: { _, _ in
        .ready(
          PutioPlaybackSource(url: URL(string: "https://media.test/x.m3u8")!, startFromSeconds: 0))
      },
      startConversion: { _ in }, conversionStatus: { _ in .completed },
      reportPosition: { _, _ in })
    queue.setConcurrencyLimit(2)
    let ids = (1...3).map { PutioFileID(rawValue: $0) }
    for id in ids.prefix(2) {
      queue.enqueue(fileID: id, parentID: .root, name: "\(id.rawValue)", kind: .video)
    }
    await settle()
    queue.setConcurrencyLimit(1)
    try engine.finish(ids[1], at: directory)
    queue.enqueue(fileID: ids[2], parentID: .root, name: "3", kind: .video)
    await gate.open()
    await settle()
    XCTAssertEqual(queue.item(for: ids[1])?.stage, .completed)
    XCTAssertEqual(engine.started.map(\.0), [ids[0], ids[1]], "the finished download restarted")
  }

  func testLoweringTheLimitKeepsAPauseTheUserChose() async {
    let gate = makeGate()
    let slow = SlowStartEngine(gate: gate)
    let queue = PutioOfflineQueue(
      store: PutioOfflineStore(directory: directory), engine: slow, conversionPollInterval: .zero,
      sleep: { _ in }, availableStorage: { 1_000_000_000 },
      resolve: { _, _ in
        .ready(
          PutioPlaybackSource(url: URL(string: "https://media.test/x.m3u8")!, startFromSeconds: 0))
      },
      startConversion: { _ in }, conversionStatus: { _ in .completed },
      reportPosition: { _, _ in })
    queue.setConcurrencyLimit(2)
    queue.enqueue(fileID: PutioFileID(rawValue: 1), parentID: .root, name: "a", kind: .video)
    queue.enqueue(fileID: PutioFileID(rawValue: 2), parentID: .root, name: "b", kind: .video)
    await settle()
    queue.pause(fileID: PutioFileID(rawValue: 2))
    queue.setConcurrencyLimit(1)
    await gate.open()
    await settle()
    XCTAssertEqual(queue.item(for: PutioFileID(rawValue: 2))?.stage, .paused(progress: 0))
    XCTAssertFalse(queue.isWaitingForSlot(PutioFileID(rawValue: 2)))
  }

  func testLoweringTheLimitRequeuesADownloadStillResolving() async {
    let gate = makeGate()
    let queue = PutioOfflineQueue(
      store: PutioOfflineStore(directory: directory), engine: engine, conversionPollInterval: .zero,
      sleep: { _ in }, availableStorage: { 1_000_000_000 },
      resolve: { fileID, _ in
        if fileID.rawValue == 2 { await gate.wait() }
        return .ready(
          PutioPlaybackSource(url: URL(string: "https://media.test/x.m3u8")!, startFromSeconds: 0))
      },
      startConversion: { _ in }, conversionStatus: { _ in .completed },
      reportPosition: { _, _ in })
    queue.setConcurrencyLimit(2)
    queue.enqueue(fileID: PutioFileID(rawValue: 1), parentID: .root, name: "a", kind: .video)
    queue.enqueue(fileID: PutioFileID(rawValue: 2), parentID: .root, name: "b", kind: .video)
    await settle()
    queue.setConcurrencyLimit(1)
    await gate.open()
    await settle()
    XCTAssertEqual(engine.started.map(\.0.rawValue), [1], "the resolving download never started")
    XCTAssertEqual(queue.item(for: PutioFileID(rawValue: 2))?.stage, .queued)
  }

  func testALimitLoweredDuringRestoreSuspendsTheTasksItReclaims() async throws {
    let queue = makeQueue()
    queue.setConcurrencyLimit(2)
    let ids = (1...2).map { PutioFileID(rawValue: $0) }
    for id in ids {
      queue.enqueue(fileID: id, parentID: .root, name: "\(id.rawValue)", kind: .video)
    }
    await settle()
    for id in ids { engine.onProgress?(id, 0.3) }

    let gate = makeGate()
    let relaunched = FakeEngine()
    relaunched.alive = ids
    relaunched.restoreGate = gate
    engine = relaunched
    let restored = makeQueue()
    let restoring = Task { await restored.restore() }
    try await gate.waitUntilEntered()
    restored.setConcurrencyLimit(1)
    await gate.open()
    await restoring.value
    await settle()
    XCTAssertEqual(relaunched.suspendedTasks, [ids[1]], "the transfer kept running past the limit")
    XCTAssertEqual(restored.item(for: ids[0])?.stage, .downloading(progress: 0.3))
    XCTAssertEqual(restored.item(for: ids[1])?.stage, .paused(progress: 0.3))
    XCTAssertTrue(restored.isWaitingForSlot(ids[1]))
  }

  func testAWaiterWithAPartialPackageKeepsItsPlaceAcrossRelaunch() async throws {
    let queue = makeQueue()
    queue.setConcurrencyLimit(2)
    let ids = (1...3).map { PutioFileID(rawValue: $0) }
    for id in ids {
      queue.enqueue(fileID: id, parentID: .root, name: "\(id.rawValue)", kind: .video)
    }
    await settle()
    let location = directory.appending(path: "2.movpkg")
    try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
    engine.onLocation?(ids[1], location)
    engine.onProgress?(ids[1], 0.4)
    queue.setConcurrencyLimit(1)
    await settle()
    XCTAssertTrue(queue.isWaitingForSlot(ids[1]))
    XCTAssertEqual(queue.item(for: ids[2])?.stage, .queued)

    let gate = makeGate()
    let relaunched = FakeEngine()
    relaunched.alive = []
    let restored = PutioOfflineQueue(
      store: PutioOfflineStore(directory: directory), engine: relaunched,
      conversionPollInterval: .zero, sleep: { _ in }, availableStorage: { 1_000_000_000 },
      readTracks: { _ in ([], []) },
      isPlayable: { _ in
        await gate.wait()
        return false
      },
      resolve: { _, _ in
        .ready(
          PutioPlaybackSource(url: URL(string: "https://media.test/x.m3u8")!, startFromSeconds: 0))
      },
      startConversion: { _ in }, conversionStatus: { _ in .completed },
      reportPosition: { _, _ in })
    let restoring = Task { await restored.restore() }
    try await gate.waitUntilEntered()
    XCTAssertEqual(
      PutioOfflineStore(directory: directory).load().waitingForSlot, [ids[1]],
      "a kill during the probe loses the waiter")
    XCTAssertTrue(relaunched.started.isEmpty, "a later download took the slot during the probe")

    await gate.open()
    await restoring.value
    await settle()
    XCTAssertEqual(relaunched.started.map(\.0), [ids[1]], "a later download jumped the line")
    XCTAssertEqual(restored.item(for: ids[2])?.stage, .queued)
  }

  func testFreshQueueAllowsThreeAndAStoredLimitSurvivesTheUpgrade() throws {
    XCTAssertEqual(makeQueue().concurrencyLimit, 3)
    XCTAssertEqual(PutioOfflineQueue.concurrencyLimits, [1, 2, 3, 4])
    try PutioOfflineStore(directory: directory).save(items: [], concurrencyLimit: 2)
    XCTAssertEqual(makeQueue().concurrencyLimit, 2)
  }

  func testSizeIsShownOnlyOnceTheDownloadCompletes() {
    var item = PutioOfflineItem(
      id: PutioFileID(rawValue: 8), parentID: .root, name: "h", kind: .video, createdAt: .now,
      stage: .queued, localPath: nil, storedBytes: 0,
      storedAudioTracks: [], storedSubtitleTracks: [],
      resumePositionSeconds: 0, pendingPositionSeconds: nil, estimatedBytes: 4_000)
    let unfinished: [PutioOfflineItem.Stage] = [
      .queued, .converting(progress: 0.2), .downloading(progress: 0.4), .paused(progress: 0.4),
      .failed(.download),
    ]
    for stage in unfinished {
      item.stage = stage
      XCTAssertNil(item.storedSizeText, "\(stage) shows a size")
    }
    item.stage = .completed
    XCTAssertEqual(item.storedSizeText, "0 B")
  }

  func testASingleFileDownloadRecordsItsSize() async throws {
    let queue = makeQueue()
    let fileID = PutioFileID(rawValue: 1)
    queue.enqueue(fileID: fileID, parentID: .root, name: "a.m4a", kind: .audio)
    await settle()
    let location = directory.appending(path: "1.m4a")
    try Data(count: 85_000).write(to: location)
    engine.onLocation?(fileID, location)
    engine.onFinished?(fileID, nil)
    await settle()
    XCTAssertEqual(queue.item(for: fileID)?.stage, .completed)
    XCTAssertGreaterThanOrEqual(queue.item(for: fileID)?.storedBytes ?? 0, 85_000)
  }

  func testQueuePersistsAndRestoresPausingOrphanedDownloads() async throws {
    let queue = makeQueue()
    queue.enqueue(fileID: PutioFileID(rawValue: 1), parentID: .root, name: "a", kind: .video)
    queue.enqueue(fileID: PutioFileID(rawValue: 2), parentID: .root, name: "b", kind: .video)
    await settle()
    engine.onProgress?(PutioFileID(rawValue: 1), 0.4)
    try engine.finish(PutioFileID(rawValue: 2), at: directory)
    await settle()

    let relaunched = FakeEngine()
    relaunched.alive = []
    engine = relaunched
    let restored = makeQueue()
    XCTAssertEqual(restored.items.map(\.id.rawValue), [1, 2])
    await restored.restore()
    XCTAssertEqual(restored.item(for: PutioFileID(rawValue: 1))?.stage, .paused(progress: 0.4))
    XCTAssertEqual(restored.item(for: PutioFileID(rawValue: 2))?.stage, .completed)
    XCTAssertNotNil(restored.localSource(for: PutioFileID(rawValue: 2)))

    // A task the system kept alive stays downloading and finishes in place.
    let survivorStore = PutioOfflineStore(directory: directory)
    let survivorLoaded = survivorStore.load()
    var (items, limit) = (survivorLoaded.items, survivorLoaded.concurrencyLimit)
    items[0].stage = .downloading(progress: 0.4)
    try survivorStore.save(items: items, concurrencyLimit: limit)
    let survivor = FakeEngine()
    survivor.alive = [PutioFileID(rawValue: 1)]
    engine = survivor
    let persisted = makeQueue()
    await persisted.restore()
    await settle()
    XCTAssertEqual(
      persisted.item(for: PutioFileID(rawValue: 1))?.stage, .downloading(progress: 0.4))
    XCTAssertTrue(survivor.started.isEmpty, "a live task must not be restarted")
    try survivor.finish(PutioFileID(rawValue: 1), at: directory)
    await settle()
    XCTAssertEqual(persisted.item(for: PutioFileID(rawValue: 1))?.stage, .completed)
  }

  func testPausedTaskKeptAliveResumesInPlace() async {
    let queue = makeQueue()
    queue.enqueue(fileID: PutioFileID(rawValue: 1), parentID: .root, name: "a", kind: .video)
    await settle()
    engine.onProgress?(PutioFileID(rawValue: 1), 0.5)
    queue.pause(fileID: PutioFileID(rawValue: 1))
    queue.resume(fileID: PutioFileID(rawValue: 1))
    await settle()
    XCTAssertEqual(engine.resumed, [PutioFileID(rawValue: 1)])
    XCTAssertEqual(engine.started.count, 1, "a suspended task resumes without a new download")
    XCTAssertEqual(queue.item(for: PutioFileID(rawValue: 1))?.stage, .downloading(progress: 0.5))
  }

  func testAuthenticationLossIsAStableFailureNotALoop() async {
    var attempts = 0
    let queue = PutioOfflineQueue(
      store: PutioOfflineStore(directory: directory), engine: engine, conversionPollInterval: .zero,
      sleep: { _ in }, availableStorage: { 1_000_000_000 },
      resolve: { _, _ in
        attempts += 1
        throw PutioRuntimeError.sessionExpired
      },
      startConversion: { _ in }, conversionStatus: { _ in .completed },
      reportPosition: { _, _ in })
    queue.enqueue(fileID: PutioFileID(rawValue: 3), parentID: .root, name: "c", kind: .video)
    await settle()
    XCTAssertEqual(attempts, 1)
    XCTAssertEqual(queue.item(for: PutioFileID(rawValue: 3))?.stage, .failed(.authentication))
    XCTAssertTrue(PutioOfflineFailure.authentication.canRetry)
  }

  func testSignInAgainDoesNotRetryUntilTheSessionIsValid() async {
    var live = true
    var attempts = 0
    let queue = PutioOfflineQueue(
      store: PutioOfflineStore(directory: directory), engine: engine, conversionPollInterval: .zero,
      sleep: { _ in }, availableStorage: { 1_000_000_000 },
      resolve: { _, _ in
        attempts += 1
        throw PutioRuntimeError.sessionExpired
      },
      startConversion: { _ in }, conversionStatus: { _ in .completed },
      reportPosition: { _, _ in }, isLive: { live })
    let fileID = PutioFileID(rawValue: 3)
    queue.enqueue(fileID: fileID, parentID: .root, name: "c", kind: .video)
    await settle()
    live = false
    queue.retry(fileID: fileID)
    await settle()
    XCTAssertEqual(attempts, 1)
    XCTAssertEqual(queue.item(for: fileID)?.stage, .failed(.authentication))
  }

  func testFailuresReadTheirBoardReason() {
    let reasons = [
      PutioOfflineFailure.resolving(PutioRuntimeError.transient),
      .resolving(PutioRuntimeError.sessionExpired),
      .resolving(PutioRuntimeError.authenticationRequired),
      .resolving(PutioRuntimeError.notFound),
      .storage,
      .download,
      .conversion,
      .resolving(PutioRuntimeError.unknown),
      .resolving(PutioRuntimeError.invalidResponse),
      .resolving(PutioRuntimeError.rateLimited),
    ].map { $0?.reason }
    XCTAssertEqual(
      reasons,
      [
        "Connection lost", "Sign in again", "Sign in again", "No longer available",
        "Not enough storage", "Couldn’t download", "Couldn’t download", "Couldn’t download",
        "Couldn’t download", "Couldn’t download",
      ])
  }

  func testAFinishedDownloadWhosePackageIsGoneReadsMissingAtLaunch() async throws {
    let store = PutioOfflineStore(directory: directory)
    func finished(_ id: Int, at path: String) -> PutioOfflineItem {
      PutioOfflineItem(
        id: PutioFileID(rawValue: id), parentID: .root, name: "\(id).mkv", kind: .video,
        createdAt: .now, stage: .completed, localPath: path, storedBytes: 512,
        storedAudioTracks: [], storedSubtitleTracks: [],
        resumePositionSeconds: 0, pendingPositionSeconds: nil, estimatedBytes: 512)
    }
    let kept = directory.appending(path: "1.movpkg")
    try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
    try Data(count: 512).write(to: kept.appending(path: "segment.bin"))
    try store.save(
      items: [
        finished(1, at: kept.path), finished(2, at: directory.appending(path: "2.movpkg").path),
      ], concurrencyLimit: 2)
    let queue = makeQueue()
    await queue.restore()
    await settle()

    let gone = PutioFileID(rawValue: 2)
    XCTAssertEqual(queue.item(for: PutioFileID(rawValue: 1))?.stage, .completed)
    XCTAssertEqual(queue.item(for: gone)?.stage, .missing)
    XCTAssertNil(queue.item(for: gone)?.localPath)
    XCTAssertEqual(queue.storedBytes, 512)
    XCTAssertEqual(
      queue.item(for: gone)?.downloadState(queuePosition: nil), .missing)
    XCTAssertEqual(
      PutioOfflineSections(queue.items).sections.map(\.kind), [.attention, .onDevice])
    XCTAssertEqual(store.load().items.last?.stage, .missing)

    queue.retry(fileID: gone)
    await settle()
    XCTAssertEqual(engine.started.map(\.0), [gone])
    XCTAssertEqual(queue.item(for: gone)?.stage, .downloading(progress: 0))
  }

  func testPauseDuringResolutionWinsOverTheWorker() async throws {
    let gate = makeGate()
    let queue = PutioOfflineQueue(
      store: PutioOfflineStore(directory: directory), engine: engine, conversionPollInterval: .zero,
      sleep: { _ in }, availableStorage: { 1_000_000_000 },
      resolve: { _, _ in
        await gate.wait()
        return .ready(
          PutioPlaybackSource(url: URL(string: "https://media.test/x.m3u8")!, startFromSeconds: 0))
      },
      startConversion: { _ in }, conversionStatus: { _ in .completed },
      reportPosition: { _, _ in })
    queue.enqueue(fileID: PutioFileID(rawValue: 4), parentID: .root, name: "d", kind: .video)
    try await gate.waitUntilEntered()
    queue.pause(fileID: PutioFileID(rawValue: 4))
    await gate.open()
    await settle()
    XCTAssertEqual(queue.item(for: PutioFileID(rawValue: 4))?.stage, .paused(progress: 0))
    XCTAssertTrue(engine.started.isEmpty, "a paused item must not start a download")
  }

  func testResumeAtTheLimitWaitsForASlot() async throws {
    let queue = makeQueue()
    queue.setConcurrencyLimit(1)
    queue.enqueue(fileID: PutioFileID(rawValue: 1), parentID: .root, name: "a", kind: .video)
    await settle()
    engine.onProgress?(PutioFileID(rawValue: 1), 0.5)
    queue.pause(fileID: PutioFileID(rawValue: 1))
    queue.enqueue(fileID: PutioFileID(rawValue: 2), parentID: .root, name: "b", kind: .video)
    await settle()
    XCTAssertEqual(engine.started.map(\.0.rawValue), [1, 2])
    queue.resume(fileID: PutioFileID(rawValue: 1))
    XCTAssertTrue(engine.resumed.isEmpty, "no slot was free")
    XCTAssertEqual(queue.item(for: PutioFileID(rawValue: 1))?.stage, .paused(progress: 0.5))
    let waiting = PutioOfflineSections(queue.items, waitingForSlot: queue.slotWaiters)
    let place = waiting.queuePositions[PutioFileID(rawValue: 1)]
    XCTAssertEqual(place, 1, "a resumed row waiting for a slot reads as queued")
    XCTAssertEqual(
      queue.item(for: PutioFileID(rawValue: 1))?.downloadState(queuePosition: place),
      .queued(position: 1))
    try engine.finish(PutioFileID(rawValue: 2), at: directory)
    await settle()
    XCTAssertEqual(engine.resumed, [PutioFileID(rawValue: 1)])
    XCTAssertEqual(engine.started.count, 2, "the suspended task resumed without a restart")
    XCTAssertEqual(queue.item(for: PutioFileID(rawValue: 1))?.stage, .downloading(progress: 0.5))
  }

  func testAFileRowReadsItsPlaceInLineAndControlsTheQueue() async throws {
    let queue = makeQueue()
    queue.setConcurrencyLimit(1)
    for id in 1...3 {
      queue.enqueue(fileID: PutioFileID(rawValue: id), parentID: .root, name: "\(id)", kind: .video)
    }
    await settle()
    XCTAssertEqual(
      queue.downloadState(for: PutioFileID(rawValue: 3), on: .iPhone), .queued(position: 2))
    XCTAssertEqual(queue.downloadState(for: PutioFileID(rawValue: 99), on: .iPhone), .idle)
    queue.perform(.cancel, fileID: PutioFileID(rawValue: 2))
    XCTAssertEqual(
      queue.downloadState(for: PutioFileID(rawValue: 3), on: .iPhone), .queued(position: 1))
    try engine.finish(PutioFileID(rawValue: 1), at: directory)
    await settle()
    XCTAssertEqual(
      queue.downloadState(for: PutioFileID(rawValue: 1), on: .iPhone), .idle,
      "a finished download leaves the row to its on-device marker")
  }

  func testAStorageWaitStartsOnItsOwnOnceSpaceFrees() async {
    freeBytes = 500_000_000
    let queue = makeQueue(availableStorage: { self.freeBytes })
    let fileID = PutioFileID(rawValue: 1)
    engine.estimates[1] = 900_000_000
    queue.enqueue(fileID: fileID, parentID: .root, name: "a", kind: .video)
    await settle()
    XCTAssertEqual(queue.item(for: fileID)?.stage, .waitingForStorage)
    XCTAssertEqual(PutioOfflineSections(queue.items).sections.map(\.kind), [.downloading])
    XCTAssertTrue(engine.started.isEmpty)

    freeBytes = 2_000_000_000
    queue.refreshStorage()
    await settle()
    XCTAssertEqual(engine.started.map(\.0.rawValue), [1])
    XCTAssertEqual(queue.item(for: fileID)?.stage, .downloading(progress: 0))
  }

  func testANetworkWaitResumesOnItsOwnWhenThePathReturns() async {
    let queue = makeQueue()
    let first = PutioFileID(rawValue: 1)
    queue.enqueue(fileID: first, parentID: .root, name: "a", kind: .video)
    await settle()
    engine.onProgress?(first, 0.4)

    queue.setOnline(false)
    XCTAssertEqual(queue.item(for: first)?.stage, .waitingForNetwork(progress: 0.4))
    queue.enqueue(fileID: PutioFileID(rawValue: 2), parentID: .root, name: "b", kind: .audio)
    await settle()
    XCTAssertEqual(engine.started.map(\.0.rawValue), [1], "nothing new starts offline")
    XCTAssertEqual(queue.item(for: PutioFileID(rawValue: 2))?.stage, .queued)

    queue.setOnline(true)
    await settle()
    XCTAssertEqual(queue.item(for: first)?.stage, .downloading(progress: 0.4))
    XCTAssertEqual(engine.started.map(\.0.rawValue), [1, 2])

    queue.setOnline(false)
    engine.onProgress?(first, 0.5)
    XCTAssertEqual(
      queue.item(for: first)?.stage, .downloading(progress: 0.5), "arriving bytes end the wait")
  }

  func testAResumeWhileOfflineWaitsForTheNetwork() async {
    let queue = makeQueue()
    let first = PutioFileID(rawValue: 1)
    queue.enqueue(fileID: first, parentID: .root, name: "a", kind: .video)
    await settle()
    engine.onProgress?(first, 0.4)
    queue.pause(fileID: first)

    queue.setOnline(false)
    queue.resume(fileID: first)
    XCTAssertEqual(queue.item(for: first)?.stage, .waitingForNetwork(progress: 0.4))

    queue.setOnline(true)
    XCTAssertEqual(queue.item(for: first)?.stage, .downloading(progress: 0.4))
  }

  func testARetryWithoutNetworkFailsAsALostConnection() async {
    let queue = makeQueue()
    let fileID = PutioFileID(rawValue: 1)
    queue.enqueue(fileID: fileID, parentID: .root, name: "a", kind: .video)
    await settle()
    engine.onFinished?(fileID, URLError(.networkConnectionLost))
    XCTAssertEqual(queue.item(for: fileID)?.stage, .failed(.download))

    queue.setOnline(false)
    queue.retry(fileID: fileID)
    await settle()
    XCTAssertEqual(
      queue.item(for: fileID)?.stage,
      .failed(PutioOfflineFailure.resolving(PutioRuntimeError.transient) ?? .download))
    XCTAssertEqual(
      queue.item(for: fileID)?.downloadState(queuePosition: nil),
      .failed(reason: "Connection lost"))
    XCTAssertEqual(engine.started.count, 1, "an offline retry starts nothing")
  }

  func testAConnectionLostOfflineWaitsAndRestartsWhenThePathReturns() async {
    let queue = makeQueue()
    let fileID = PutioFileID(rawValue: 1)
    queue.enqueue(fileID: fileID, parentID: .root, name: "a", kind: .video)
    await settle()
    engine.onProgress?(fileID, 0.4)

    queue.setOnline(false)
    engine.onFinished?(fileID, URLError(.networkConnectionLost))
    XCTAssertEqual(queue.item(for: fileID)?.stage, .waitingForNetwork(progress: 0.4))

    queue.setOnline(true)
    await settle()
    XCTAssertEqual(engine.started.map(\.0.rawValue), [1, 1], "the lost task restarts")
    XCTAssertEqual(queue.item(for: fileID)?.stage, .downloading(progress: 0))
  }

  func testAFullDiskOfflineStillFailsAsStorage() async {
    let queue = makeQueue()
    let fileID = PutioFileID(rawValue: 1)
    queue.enqueue(fileID: fileID, parentID: .root, name: "a", kind: .video)
    await settle()
    queue.setOnline(false)
    engine.onFinished?(
      fileID, NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError))
    XCTAssertEqual(queue.item(for: fileID)?.stage, .failed(.storage))
  }

  func testAPositionSavedOfflineIsSentWhenThePathReturns() async {
    let queue = makeQueue()
    let fileID = PutioFileID(rawValue: 1)
    queue.enqueue(fileID: fileID, parentID: .root, name: "a", kind: .video)
    await settle()
    queue.setOnline(false)
    reportShouldFail = true
    await queue.recordPosition(fileID: fileID, seconds: 42)
    XCTAssertEqual(queue.pendingPositionCount, 1)

    reportShouldFail = false
    queue.setOnline(true)
    await settle()
    XCTAssertEqual(reports.map(\.0), [1])
    XCTAssertEqual(reports.map(\.1), [42])
    XCTAssertEqual(queue.pendingPositionCount, 0)
  }

  func testAWatchStatusChangedElsewhereUpdatesTheStoredFlagAcrossRelaunch() async {
    let (changes, sender) = AsyncStream.makeStream(of: PutioWatchedChange.self)
    let queue = makeQueue(watchedChanges: changes)
    let video = PutioFileID(rawValue: 1)
    let song = PutioFileID(rawValue: 2)
    queue.enqueue(fileID: video, parentID: .root, name: "a", kind: .video, isWatched: false)
    queue.enqueue(fileID: song, parentID: .root, name: "b", kind: .audio)

    sender.yield(PutioWatchedChange(fileID: video, isWatched: true))
    sender.yield(PutioWatchedChange(fileID: song, isWatched: true))
    await settle()
    XCTAssertEqual(queue.item(for: video)?.isWatched, true)
    XCTAssertEqual(queue.item(for: song)?.isWatched, false)
    XCTAssertEqual(makeQueue().item(for: video)?.isWatched, true)

    sender.yield(PutioWatchedChange(fileID: video, isWatched: false))
    await settle()
    XCTAssertEqual(queue.item(for: video)?.isWatched, false)
    XCTAssertEqual(makeQueue().item(for: video)?.isWatched, false)

    reportShouldFail = true
    await queue.recordPosition(fileID: video, seconds: 0)
    sender.yield(PutioWatchedChange(fileID: video, isWatched: true))
    await settle()
    XCTAssertEqual(
      makeQueue().item(for: video)?.isWatched, false, "a position waiting to sync wins")

    queue.stop()
    await settle()
    sender.yield(PutioWatchedChange(fileID: video, isWatched: true))
    await settle()
    XCTAssertEqual(
      queue.item(for: video)?.isWatched, false, "a stopped queue follows no later change")
  }

  func testOpeningDownloadsTakesTheWatchStatusPutioStoresAcrossRelaunch() async {
    serverWatched = [1: true, 2: false, 3: false]
    let queue = makeQueue(watchedStatus: { fileID in
      self.runtimeCalls.append("watched \(fileID.rawValue)")
      guard let watched = self.serverWatched[fileID.rawValue] else {
        throw PutioRuntimeError.transient
      }
      return watched
    })
    let watchedElsewhere = PutioFileID(rawValue: 1)
    let unwatchedElsewhere = PutioFileID(rawValue: 2)
    let pending = PutioFileID(rawValue: 3)
    let unreachable = PutioFileID(rawValue: 4)
    queue.enqueue(
      fileID: watchedElsewhere, parentID: .root, name: "a", kind: .video, isWatched: false)
    queue.enqueue(
      fileID: unwatchedElsewhere, parentID: .root, name: "b", kind: .video, isWatched: true)
    queue.enqueue(fileID: pending, parentID: .root, name: "c", kind: .video, isWatched: false)
    queue.enqueue(fileID: unreachable, parentID: .root, name: "d", kind: .video, isWatched: true)
    queue.enqueue(fileID: PutioFileID(rawValue: 5), parentID: .root, name: "e", kind: .audio)
    await settle()
    reportShouldFail = true
    await queue.recordPosition(fileID: pending, seconds: 30)

    await queue.refreshWatched()
    XCTAssertEqual(
      runtimeCalls.filter { $0.hasPrefix("watched") }, ["watched 1", "watched 2", "watched 4"])
    let relaunched = makeQueue()
    XCTAssertEqual(relaunched.item(for: watchedElsewhere)?.isWatched, true)
    XCTAssertEqual(relaunched.item(for: unwatchedElsewhere)?.isWatched, false)
    XCTAssertEqual(relaunched.item(for: pending)?.isWatched, true)
    XCTAssertEqual(relaunched.item(for: unreachable)?.isWatched, true)

    serverWatched[1] = false
    queue.setOnline(false)
    await queue.refreshWatched()
    XCTAssertEqual(
      runtimeCalls.filter { $0.hasPrefix("watched") }, ["watched 1", "watched 2", "watched 4"],
      "an offline queue asks put.io nothing")
    XCTAssertEqual(queue.item(for: watchedElsewhere)?.isWatched, true)
  }

  func testWatchingTheStoredCopyOfflineMarksItWatchedAcrossRelaunch() async {
    let queue = makeQueue()
    let fileID = PutioFileID(rawValue: 1)
    queue.enqueue(fileID: fileID, parentID: .root, name: "a", kind: .video, isWatched: false)
    await settle()
    queue.setOnline(false)
    reportShouldFail = true

    await queue.recordPosition(fileID: fileID, seconds: 1_200)
    XCTAssertEqual(queue.item(for: fileID)?.isWatched, true)
    XCTAssertEqual(makeQueue().item(for: fileID)?.isWatched, true)

    await queue.recordPosition(fileID: fileID, seconds: 0)
    XCTAssertEqual(makeQueue().item(for: fileID)?.isWatched, false)
  }

  func testARemovedRowReadsAsRemovingUntilItsPackageIsGone() async throws {
    let gate = makeGate()
    let queue = makeQueue(deletePackages: { urls in
      await gate.wait()
      for url in urls { try? FileManager.default.removeItem(at: url) }
    })
    let fileID = PutioFileID(rawValue: 1)
    queue.enqueue(fileID: fileID, parentID: .root, name: "a", kind: .video)
    await settle()
    try engine.finish(fileID, at: directory)
    await settle()
    let path = try XCTUnwrap(queue.item(for: fileID)?.localPath)

    let removal = queue.remove(fileIDs: [fileID])
    XCTAssertNil(queue.item(for: fileID))
    XCTAssertEqual(queue.removing.map(\.id), [fileID])
    let sections = PutioOfflineSections(queue.items, removing: queue.removing)
    XCTAssertEqual(sections.sections.map(\.kind), [.onDevice])
    XCTAssertEqual(PutioOfflineStore(directory: directory).loadPackages(), [path])

    await gate.open()
    await removal.value
    XCTAssertTrue(queue.removing.isEmpty)
    XCTAssertTrue(PutioOfflineStore(directory: directory).loadPackages().isEmpty)
  }

  func testADownloadAgainWaitsUntilTheRemovedPackageIsGone() async throws {
    let gate = makeGate()
    let queue = makeQueue(deletePackages: { urls in
      await gate.wait()
      for url in urls { try? FileManager.default.removeItem(at: url) }
    })
    let fileID = PutioFileID(rawValue: 1)
    queue.enqueue(fileID: fileID, parentID: .root, name: "a", kind: .video)
    await settle()
    try engine.finish(fileID, at: directory)
    await settle()

    let removal = queue.remove(fileIDs: [fileID])
    queue.enqueue(fileID: fileID, parentID: .root, name: "a", kind: .video)
    await settle()
    XCTAssertEqual(engine.started.count, 1, "the new download started before the old one was gone")
    XCTAssertEqual(queue.item(for: fileID)?.stage, .queued)

    await gate.open()
    await removal.value
    await settle()
    XCTAssertEqual(engine.started.count, 2)
  }

  func testFailedDownloadsDropTheirPartialPackage() async throws {
    let queue = makeQueue()
    queue.enqueue(fileID: PutioFileID(rawValue: 1), parentID: .root, name: "a", kind: .video)
    await settle()
    let location = directory.appending(path: "partial.movpkg")
    try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
    try Data(count: 64).write(to: location.appending(path: "seg.bin"))
    engine.onLocation?(PutioFileID(rawValue: 1), location)
    engine.onFinished?(PutioFileID(rawValue: 1), URLError(.networkConnectionLost))
    XCTAssertEqual(queue.item(for: PutioFileID(rawValue: 1))?.stage, .failed(.download))
    XCTAssertNil(queue.item(for: PutioFileID(rawValue: 1))?.localPath)
    XCTAssertFalse(FileManager.default.fileExists(atPath: location.path))
    XCTAssertEqual(queue.storedBytes, 0)
  }

  func testStreamEstimateBeyondFreeSpaceWaitsBeforeStarting() async {
    engine.estimates[1] = 900_000_000
    let queue = makeQueue(availableBytes: 500_000_000)
    queue.enqueue(
      fileID: PutioFileID(rawValue: 1), parentID: .root, name: "a", kind: .video,
      estimatedBytes: 1)
    await settle()
    XCTAssertEqual(queue.item(for: PutioFileID(rawValue: 1))?.stage, .waitingForStorage)
    XCTAssertTrue(engine.started.isEmpty)
  }

  func testPauseDuringEngineStartReQueuesOnResume() async throws {
    let gate = makeGate()
    let slowEngine = SlowStartEngine(gate: gate)
    engine = FakeEngine()
    let queue = PutioOfflineQueue(
      store: PutioOfflineStore(directory: directory), engine: slowEngine,
      conversionPollInterval: .zero, sleep: { _ in }, availableStorage: { 1_000_000_000 },
      resolve: { _, _ in
        .ready(
          PutioPlaybackSource(url: URL(string: "https://media.test/x.m3u8")!, startFromSeconds: 0))
      },
      startConversion: { _ in }, conversionStatus: { _ in .completed },
      reportPosition: { _, _ in })
    queue.enqueue(fileID: PutioFileID(rawValue: 7), parentID: .root, name: "g", kind: .video)
    try await gate.waitUntilEntered()
    XCTAssertEqual(queue.item(for: PutioFileID(rawValue: 7))?.stage, .downloading(progress: 0))
    queue.pause(fileID: PutioFileID(rawValue: 7))
    await gate.open()
    await settle()
    XCTAssertEqual(slowEngine.cancelled, [PutioFileID(rawValue: 7)])
    XCTAssertEqual(queue.item(for: PutioFileID(rawValue: 7))?.stage, .paused(progress: 0))
    queue.resume(fileID: PutioFileID(rawValue: 7))
    await gate.open()
    await settle()
    XCTAssertTrue(slowEngine.resumed.isEmpty, "there was no task to resume in place")
    XCTAssertEqual(slowEngine.started.count, 2)
    XCTAssertEqual(queue.item(for: PutioFileID(rawValue: 7))?.stage, .downloading(progress: 0))
  }

  func testCompletionThatRacesAPauseStillCompletes() async throws {
    let queue = makeQueue()
    queue.enqueue(fileID: PutioFileID(rawValue: 1), parentID: .root, name: "a", kind: .video)
    await settle()
    engine.onProgress?(PutioFileID(rawValue: 1), 0.99)
    queue.pause(fileID: PutioFileID(rawValue: 1))
    try engine.finish(PutioFileID(rawValue: 1), at: directory)
    await settle()
    XCTAssertEqual(queue.item(for: PutioFileID(rawValue: 1))?.stage, .completed)
    XCTAssertNotNil(queue.localSource(for: PutioFileID(rawValue: 1)))
  }

  func testRestoreFinishesAPackageThatCompletedWhileTheAppWasGone() async throws {
    let store = PutioOfflineStore(directory: directory)
    let location = directory.appending(path: "done.movpkg")
    try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
    try Data(count: 256).write(to: location.appending(path: "seg.bin"))
    let item = PutioOfflineItem(
      id: PutioFileID(rawValue: 8), parentID: .root, name: "h", kind: .video, createdAt: .now,
      stage: .downloading(progress: 1), localPath: location.path, storedBytes: 0,
      storedAudioTracks: [], storedSubtitleTracks: [],
      resumePositionSeconds: 0, pendingPositionSeconds: nil, estimatedBytes: 0)
    try store.save(items: [item], concurrencyLimit: 2)
    let queue = makeQueue()
    await queue.restore()
    await settle()
    XCTAssertEqual(queue.item(for: PutioFileID(rawValue: 8))?.stage, .completed)
    XCTAssertGreaterThan(queue.storedBytes, 0)
    XCTAssertTrue(engine.started.isEmpty)
  }

  func testPauseDuringConversionPollKeepsThePause() async throws {
    let gate = makeGate()
    resolutions[9] = [.conversionRequired]
    let queue = PutioOfflineQueue(
      store: PutioOfflineStore(directory: directory), engine: engine, conversionPollInterval: .zero,
      sleep: { _ in try Task.checkCancellation() }, availableStorage: { 1_000_000_000 },
      resolve: { fileID, _ in
        if var queued = self.resolutions[fileID.rawValue], !queued.isEmpty {
          let next = queued.removeFirst()
          self.resolutions[fileID.rawValue] = queued
          return next
        }
        return .ready(
          PutioPlaybackSource(url: URL(string: "https://media.test/x.m3u8")!, startFromSeconds: 0))
      },
      startConversion: { _ in },
      conversionStatus: { _ in
        await gate.wait()
        return .converting(progress: 0.4)
      },
      reportPosition: { _, _ in })
    queue.enqueue(fileID: PutioFileID(rawValue: 9), parentID: .root, name: "i", kind: .video)
    try await gate.waitUntilEntered()
    XCTAssertEqual(queue.item(for: PutioFileID(rawValue: 9))?.stage, .waitingToConvert)
    queue.pause(fileID: PutioFileID(rawValue: 9))
    await gate.open()
    await settle()
    XCTAssertEqual(queue.item(for: PutioFileID(rawValue: 9))?.stage, .paused(progress: 0))
    queue.enqueue(fileID: PutioFileID(rawValue: 10), parentID: .root, name: "j", kind: .audio)
    queue.enqueue(fileID: PutioFileID(rawValue: 11), parentID: .root, name: "k", kind: .audio)
    await settle()
    XCTAssertEqual(engine.started.map(\.0.rawValue), [10, 11], "the paused item held no slot")
  }

  func testPausingAConversionCountsNoBytesOnTheDevice() async throws {
    let gate = makeGate()
    resolutions[12] = [.conversionRequired]
    let queue = PutioOfflineQueue(
      store: PutioOfflineStore(directory: directory), engine: engine, conversionPollInterval: .zero,
      sleep: { _ in
        await gate.wait()
        try Task.checkCancellation()
      },
      availableStorage: { 1_000_000_000 },
      resolve: { fileID, _ in
        if var queued = self.resolutions[fileID.rawValue], !queued.isEmpty {
          let next = queued.removeFirst()
          self.resolutions[fileID.rawValue] = queued
          return next
        }
        return .ready(
          PutioPlaybackSource(url: URL(string: "https://media.test/x.m3u8")!, startFromSeconds: 0))
      },
      startConversion: { _ in },
      conversionStatus: { _ in .converting(progress: 0.5) },
      reportPosition: { _, _ in })
    queue.enqueue(
      fileID: PutioFileID(rawValue: 12), parentID: .root, name: "l", kind: .video,
      estimatedBytes: 1_000)
    try await gate.waitUntilEntered()
    XCTAssertEqual(queue.item(for: PutioFileID(rawValue: 12))?.stage, .converting(progress: 0.5))
    queue.pause(fileID: PutioFileID(rawValue: 12))
    await gate.open()
    await settle()
    XCTAssertEqual(queue.item(for: PutioFileID(rawValue: 12))?.stage, .paused(progress: 0))
    XCTAssertEqual(queue.item(for: PutioFileID(rawValue: 12))?.bytesOnDevice, 0)
  }

  func testLateFailureDoesNotOverwriteAPause() async throws {
    let gate = makeGate()
    let queue = PutioOfflineQueue(
      store: PutioOfflineStore(directory: directory), engine: engine, conversionPollInterval: .zero,
      sleep: { _ in }, availableStorage: { 1_000_000_000 },
      resolve: { _, _ in
        await gate.wait()
        throw PutioRuntimeError.transient
      },
      startConversion: { _ in }, conversionStatus: { _ in .completed },
      reportPosition: { _, _ in })
    queue.enqueue(fileID: PutioFileID(rawValue: 12), parentID: .root, name: "l", kind: .video)
    try await gate.waitUntilEntered()
    queue.pause(fileID: PutioFileID(rawValue: 12))
    await gate.open()
    await settle()
    XCTAssertEqual(queue.item(for: PutioFileID(rawValue: 12))?.stage, .paused(progress: 0))
  }

  func testStoreIsScopedPerAccount() {
    let a = PutioOfflineStore(accountID: 1).directory
    let b = PutioOfflineStore(accountID: 2).directory
    XCTAssertNotEqual(a, b)
    XCTAssertTrue(a.path.hasSuffix("OfflineDownloads/account-1"))
    XCTAssertTrue(PutioOfflineQueue.fits(estimatedBytes: 100, freeBytes: 300 * 1024 * 1024))
    XCTAssertFalse(PutioOfflineQueue.fits(estimatedBytes: 100, freeBytes: 150 * 1024 * 1024))
  }

  func testALongMultiAudioVideoFitsWhenTheDeviceHasTheSpace() {
    let estimate = PutioSystemOfflineDownloadEngine.estimatedBytes(
      seconds: 9_600, videoBitrate: 6_000_000, audioRenditions: 10)
    XCTAssertTrue(PutioOfflineQueue.fits(estimatedBytes: estimate, freeBytes: 64_000_000_000))
  }

  func testRestoredPackagesRefillSlotsAndNotify() async throws {
    let store = PutioOfflineStore(directory: directory)
    var items: [PutioOfflineItem] = []
    for id in [20, 21] {
      let location = directory.appending(path: "\(id).movpkg")
      try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
      try Data(count: 128).write(to: location.appending(path: "seg.bin"))
      items.append(
        PutioOfflineItem(
          id: PutioFileID(rawValue: id), parentID: .root, name: "\(id)", kind: .video,
          createdAt: .now, stage: .downloading(progress: 0.95), localPath: location.path,
          storedBytes: 0, storedAudioTracks: [],
          storedSubtitleTracks: [], resumePositionSeconds: 0, pendingPositionSeconds: nil,
          estimatedBytes: 0))
    }
    items.append(
      PutioOfflineItem(
        id: PutioFileID(rawValue: 22), parentID: .root, name: "22", kind: .audio, createdAt: .now,
        stage: .queued, localPath: nil, storedBytes: 0, storedAudioTracks: [],
        storedSubtitleTracks: [], resumePositionSeconds: 0,
        pendingPositionSeconds: nil, estimatedBytes: 0))
    try store.save(items: items, concurrencyLimit: 2)
    var notified: [Int] = []
    let queue = PutioOfflineQueue(
      store: store, engine: engine, conversionPollInterval: .zero, sleep: { _ in },
      availableStorage: { 1_000_000_000 },
      readTracks: { _ in ([], []) },
      notifyCompletion: { notified.append($0.id.rawValue) },
      isPlayable: { _ in true },
      resolve: { fileID, _ in
        .ready(
          PutioPlaybackSource(
            url: URL(string: "https://media.test/\(fileID.rawValue)")!, startFromSeconds: 0))
      },
      startConversion: { _ in }, conversionStatus: { _ in .completed },
      reportPosition: { _, _ in })
    await queue.restore()
    await settle()
    XCTAssertEqual(queue.item(for: PutioFileID(rawValue: 20))?.stage, .completed)
    XCTAssertEqual(queue.item(for: PutioFileID(rawValue: 21))?.stage, .completed)
    XCTAssertEqual(Set(notified), [20, 21])
    XCTAssertEqual(engine.started.map(\.0.rawValue), [22], "freed slots started the queued item")
  }

  func testAFailedDownloadNotifiesOnceAndAPausedOneStaysQuiet() async {
    let queue = makeQueue()
    queue.enqueue(fileID: PutioFileID(rawValue: 1), parentID: .root, name: "a", kind: .video)
    queue.enqueue(fileID: PutioFileID(rawValue: 2), parentID: .root, name: "b", kind: .video)
    await settle()
    engine.onFinished?(PutioFileID(rawValue: 1), URLError(.networkConnectionLost))
    engine.onFinished?(PutioFileID(rawValue: 1), URLError(.networkConnectionLost))
    queue.pause(fileID: PutioFileID(rawValue: 2))
    engine.onFinished?(PutioFileID(rawValue: 2), URLError(.networkConnectionLost))
    XCTAssertEqual(queue.item(for: PutioFileID(rawValue: 1))?.stage, .failed(.download))
    XCTAssertEqual(failuresNotified.map(\.0), [1])
    XCTAssertEqual(failuresNotified.first?.1, .download)
  }

  func testSystemCancellationPausesADownloadingRow() async {
    let queue = makeQueue()
    queue.enqueue(fileID: PutioFileID(rawValue: 1), parentID: .root, name: "a", kind: .video)
    await settle()
    engine.onProgress?(PutioFileID(rawValue: 1), 0.3)
    engine.onCancelled?(PutioFileID(rawValue: 1))
    XCTAssertEqual(queue.item(for: PutioFileID(rawValue: 1))?.stage, .paused(progress: 0.3))
    queue.resume(fileID: PutioFileID(rawValue: 1))
    await settle()
    XCTAssertEqual(engine.started.count, 2, "resume re-queued; there was no task to resume")
  }

  func testAStreamEstimateFailureFailsTheItem() async {
    resolutions[31] = [.conversionRequired]
    engine.estimateError = PutioRuntimeError.transient
    let queue = makeQueue()
    queue.enqueue(fileID: PutioFileID(rawValue: 31), parentID: .root, name: "n", kind: .video)
    await settle()
    XCTAssertTrue(engine.started.isEmpty)
    guard case .failed(let failure) = queue.item(for: PutioFileID(rawValue: 31))?.stage else {
      return XCTFail("\(String(describing: queue.item(for: PutioFileID(rawValue: 31))?.stage))")
    }
    XCTAssertEqual(failure.kind, .resolution)
    XCTAssertTrue(failure.canRetry)
  }

  func testConversionRefreshesTheEstimateBeforeTheStorageGate() async {
    resolutions[32] = [.conversionRequired]
    engine.estimates[32] = 600_000_000
    let queue = makeQueue(availableBytes: 500_000_000)
    queue.enqueue(
      fileID: PutioFileID(rawValue: 32), parentID: .root, name: "p", kind: .video,
      estimatedBytes: 1)
    await settle()
    XCTAssertEqual(queue.item(for: PutioFileID(rawValue: 32))?.stage, .waitingForStorage)
    XCTAssertEqual(queue.item(for: PutioFileID(rawValue: 32))?.estimatedBytes, 600_000_000)
    XCTAssertTrue(engine.started.isEmpty)
  }

  func testCompletionReplayAndRestoreFinishOnce() async throws {
    let store = PutioOfflineStore(directory: directory)
    let location = directory.appending(path: "once.movpkg")
    try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
    try Data(count: 64).write(to: location.appending(path: "seg.bin"))
    try store.save(
      items: [
        PutioOfflineItem(
          id: PutioFileID(rawValue: 40), parentID: .root, name: "o", kind: .video, createdAt: .now,
          stage: .downloading(progress: 0.9), localPath: location.path, storedBytes: 0,
          storedAudioTracks: [], storedSubtitleTracks: [],
          resumePositionSeconds: 0, pendingPositionSeconds: nil, estimatedBytes: 0)
      ], concurrencyLimit: 2)
    var notified = 0
    engine.replayCompletionOnRestore = PutioFileID(rawValue: 40)
    let queue = PutioOfflineQueue(
      store: store, engine: engine, conversionPollInterval: .zero, sleep: { _ in },
      availableStorage: { 1_000_000_000 }, readTracks: { _ in ([], []) },
      notifyCompletion: { _ in notified += 1 }, isPlayable: { _ in true },
      resolve: { _, _ in
        .ready(PutioPlaybackSource(url: URL(string: "https://media.test/x")!, startFromSeconds: 0))
      },
      startConversion: { _ in }, conversionStatus: { _ in .completed },
      reportPosition: { _, _ in })
    await queue.restore()
    await settle()
    XCTAssertEqual(queue.item(for: PutioFileID(rawValue: 40))?.stage, .completed)
    XCTAssertEqual(notified, 1)
  }

  func testRestoreLeavesAnUnplayablePartialPackagePaused() async throws {
    let store = PutioOfflineStore(directory: directory)
    let location = directory.appending(path: "partial.movpkg")
    try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
    try Data(count: 512).write(to: location.appending(path: "seg.bin"))
    try store.save(
      items: [
        PutioOfflineItem(
          id: PutioFileID(rawValue: 50), parentID: .root, name: "q", kind: .video, createdAt: .now,
          stage: .downloading(progress: 0.4), localPath: location.path, storedBytes: 0,
          storedAudioTracks: [], storedSubtitleTracks: [],
          resumePositionSeconds: 0, pendingPositionSeconds: nil, estimatedBytes: 0)
      ], concurrencyLimit: 2)
    let queue = makeQueue()
    await queue.restore()
    await settle()
    XCTAssertEqual(queue.item(for: PutioFileID(rawValue: 50))?.stage, .paused(progress: 0.4))
    XCTAssertNil(queue.localSource(for: PutioFileID(rawValue: 50)))
  }

  func testPausingASlotWaiterKeepsItPausedInPlace() async throws {
    let queue = makeQueue()
    queue.setConcurrencyLimit(1)
    queue.enqueue(fileID: PutioFileID(rawValue: 1), parentID: .root, name: "a", kind: .video)
    await settle()
    engine.onProgress?(PutioFileID(rawValue: 1), 0.5)
    queue.pause(fileID: PutioFileID(rawValue: 1))
    queue.enqueue(fileID: PutioFileID(rawValue: 2), parentID: .root, name: "b", kind: .video)
    await settle()
    queue.resume(fileID: PutioFileID(rawValue: 1))
    XCTAssertTrue(queue.isWaitingForSlot(PutioFileID(rawValue: 1)))
    queue.pause(fileID: PutioFileID(rawValue: 1))
    XCTAssertFalse(queue.isWaitingForSlot(PutioFileID(rawValue: 1)))
    XCTAssertEqual(queue.item(for: PutioFileID(rawValue: 1))?.stage, .paused(progress: 0.5))
  }

  func testSystemCancelOfASlotWaiterReQueuesIt() async throws {
    let queue = makeQueue()
    queue.setConcurrencyLimit(1)
    queue.enqueue(fileID: PutioFileID(rawValue: 1), parentID: .root, name: "a", kind: .video)
    await settle()
    engine.onProgress?(PutioFileID(rawValue: 1), 0.5)
    queue.pause(fileID: PutioFileID(rawValue: 1))
    queue.enqueue(fileID: PutioFileID(rawValue: 2), parentID: .root, name: "b", kind: .video)
    await settle()
    queue.resume(fileID: PutioFileID(rawValue: 1))
    XCTAssertTrue(queue.isWaitingForSlot(PutioFileID(rawValue: 1)))
    engine.onCancelled?(PutioFileID(rawValue: 1))
    XCTAssertFalse(queue.isWaitingForSlot(PutioFileID(rawValue: 1)))
    XCTAssertEqual(queue.item(for: PutioFileID(rawValue: 1))?.stage, .queued)
    try engine.finish(PutioFileID(rawValue: 2), at: directory)
    await settle()
    XCTAssertEqual(engine.started.map(\.0.rawValue), [1, 2, 1])
  }

  func testStartGateReservesOtherInFlightEstimates() async {
    engine.estimates = [1: 500_000_000, 2: 500_000_000]
    let queue = makeQueue(availableBytes: 1_000_000_000)
    queue.setConcurrencyLimit(1)
    queue.enqueue(fileID: PutioFileID(rawValue: 1), parentID: .root, name: "a", kind: .video)
    await settle()
    XCTAssertEqual(engine.started.map(\.0.rawValue), [1])
    queue.enqueue(fileID: PutioFileID(rawValue: 2), parentID: .root, name: "b", kind: .video)
    queue.setConcurrencyLimit(2)
    await settle()
    // Item 1's unwritten estimate is reserved, so item 2 no longer fits.
    XCTAssertEqual(engine.started.map(\.0.rawValue), [1])
    XCTAssertEqual(queue.item(for: PutioFileID(rawValue: 2))?.stage, .waitingForStorage)
  }

  func testPlaybackMatchKeepsTheAssetDefaultWhenNothingMatches() {
    let stored = [
      PutioOfflineTrack(languageCode: "en", displayName: "English"),
      PutioOfflineTrack(languageCode: "tr", displayName: "Turkish"),
    ]
    XCTAssertEqual(
      PutioOfflineLanguage.match(from: stored, preferredLanguages: ["tr-TR"])?.languageCode, "tr")
    XCTAssertNil(PutioOfflineLanguage.match(from: stored, preferredLanguages: ["de-DE"]))
  }

  func testRestoreFinishesAPlayablePackageLeftPausedByAPreviousLaunch() async throws {
    let store = PutioOfflineStore(directory: directory)
    let location = directory.appending(path: "done2.movpkg")
    try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
    try Data(count: 256).write(to: location.appending(path: "seg.bin"))
    try store.save(
      items: [
        PutioOfflineItem(
          id: PutioFileID(rawValue: 60), parentID: .root, name: "r", kind: .video, createdAt: .now,
          stage: .paused(progress: 0.95), localPath: location.path, storedBytes: 0,
          storedAudioTracks: [], storedSubtitleTracks: [],
          resumePositionSeconds: 0, pendingPositionSeconds: nil, estimatedBytes: 0)
      ], concurrencyLimit: 2)
    let queue = makeQueue()
    await queue.restore()
    await settle()
    XCTAssertEqual(queue.item(for: PutioFileID(rawValue: 60))?.stage, .completed)
    XCTAssertTrue(engine.started.isEmpty)
  }

  func testResumeDuringCompletionReadWinsOverTheStalePackage() async throws {
    let gate = makeGate()
    let location = directory.appending(path: "race.movpkg")
    try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
    try Data(count: 64).write(to: location.appending(path: "seg.bin"))
    let queue = PutioOfflineQueue(
      store: PutioOfflineStore(directory: directory), engine: engine, conversionPollInterval: .zero,
      sleep: { _ in }, availableStorage: { 1_000_000_000 },
      readTracks: { _ in
        await gate.wait()
        return ([], [])
      },
      isPlayable: { _ in true },
      resolve: { _, _ in
        .ready(PutioPlaybackSource(url: URL(string: "https://media.test/x")!, startFromSeconds: 0))
      },
      startConversion: { _ in }, conversionStatus: { _ in .completed },
      reportPosition: { _, _ in })
    queue.enqueue(fileID: PutioFileID(rawValue: 61), parentID: .root, name: "s", kind: .video)
    await settle()
    engine.onProgress?(PutioFileID(rawValue: 61), 0.9)
    queue.pause(fileID: PutioFileID(rawValue: 61))
    engine.onLocation?(PutioFileID(rawValue: 61), location)
    engine.onFinished?(PutioFileID(rawValue: 61), nil)
    try await gate.waitUntilEntered()
    // The completion read is parked; the user resumes meanwhile.
    queue.resume(fileID: PutioFileID(rawValue: 61))
    await settle()
    await gate.open()
    await settle()
    XCTAssertNotEqual(queue.item(for: PutioFileID(rawValue: 61))?.stage, .completed)
  }

  func testStartGateIgnoresTheOriginalSizeOfAVideoStillResolving() async {
    let gate = makeGate()
    let queue = PutioOfflineQueue(
      store: PutioOfflineStore(directory: directory), engine: engine, conversionPollInterval: .zero,
      sleep: { _ in }, availableStorage: { 5_000_000_000 },
      resolve: { fileID, _ in
        if fileID.rawValue == 1 { await gate.wait() }
        return .ready(
          PutioPlaybackSource(
            url: URL(string: "https://media.test/\(fileID.rawValue)")!, startFromSeconds: 0))
      },
      startConversion: { _ in }, conversionStatus: { _ in .completed },
      reportPosition: { _, _ in })
    engine.estimates = [1: 1_000_000_000, 2: 1_000_000_000]
    queue.enqueue(
      fileID: PutioFileID(rawValue: 1), parentID: .root, name: "a", kind: .video,
      estimatedBytes: 10_000_000_000)
    queue.enqueue(
      fileID: PutioFileID(rawValue: 2), parentID: .root, name: "b", kind: .video,
      estimatedBytes: 10_000_000_000)
    await settle()
    XCTAssertEqual(engine.started.map(\.0.rawValue), [2])
    await gate.open()
    await settle()
    XCTAssertEqual(engine.started.map(\.0.rawValue), [2, 1])
  }

  func testRetriedVideoStopsReservingItsEarlierEstimateWhileItResolvesAgain() async {
    let gate = makeGate()
    let resolutions = ResolutionCount()
    let queue = PutioOfflineQueue(
      store: PutioOfflineStore(directory: directory), engine: engine, conversionPollInterval: .zero,
      sleep: { _ in }, availableStorage: { 5_000_000_000 },
      resolve: { fileID, _ in
        if fileID.rawValue == 1 {
          resolutions.value += 1
          if resolutions.value > 1 { await gate.wait() }
        }
        return .ready(
          PutioPlaybackSource(
            url: URL(string: "https://media.test/\(fileID.rawValue)")!, startFromSeconds: 0))
      },
      startConversion: { _ in }, conversionStatus: { _ in .completed },
      reportPosition: { _, _ in })
    engine.estimates = [1: 4_500_000_000, 2: 1_000_000_000]
    queue.enqueue(fileID: PutioFileID(rawValue: 1), parentID: .root, name: "a", kind: .video)
    await settle()
    engine.onFinished?(PutioFileID(rawValue: 1), URLError(.networkConnectionLost))
    XCTAssertEqual(queue.item(for: PutioFileID(rawValue: 1))?.stage, .failed(.download))
    queue.retry(fileID: PutioFileID(rawValue: 1))
    await settle()
    queue.enqueue(fileID: PutioFileID(rawValue: 2), parentID: .root, name: "b", kind: .video)
    await settle()
    XCTAssertEqual(engine.started.map(\.0.rawValue), [1, 2])
    await gate.open()
    await settle()
  }

  func testReQueueDropsThePreviousPartialPackage() async throws {
    let queue = makeQueue()
    queue.enqueue(fileID: PutioFileID(rawValue: 70), parentID: .root, name: "t", kind: .video)
    await settle()
    let location = directory.appending(path: "partial-70.movpkg")
    try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
    try Data(count: 64).write(to: location.appending(path: "seg.bin"))
    engine.onLocation?(PutioFileID(rawValue: 70), location)
    engine.onProgress?(PutioFileID(rawValue: 70), 0.3)
    engine.onCancelled?(PutioFileID(rawValue: 70))
    XCTAssertEqual(queue.item(for: PutioFileID(rawValue: 70))?.stage, .paused(progress: 0.3))
    queue.resume(fileID: PutioFileID(rawValue: 70))
    await settle()
    XCTAssertEqual(engine.started.count, 2)
    XCTAssertFalse(FileManager.default.fileExists(atPath: location.path))
    XCTAssertNil(queue.item(for: PutioFileID(rawValue: 70))?.localPath)
  }

  func testHLSPackageIsCompleteOnlyWhenEverySegmentExists() throws {
    let package = directory.appending(path: "check.movpkg")
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    try Data("#EXTM3U\n#EXTINF:10,\nseg-0.ts\n#EXTINF:10,\nseg-1.ts\n#EXT-X-ENDLIST\n".utf8)
      .write(to: package.appending(path: "index.m3u8"))
    try Data(count: 8).write(to: package.appending(path: "seg-0.ts"))
    XCTAssertFalse(PutioOfflineQueue.packageIsComplete(at: package))
    try Data(count: 8).write(to: package.appending(path: "seg-1.ts"))
    XCTAssertTrue(PutioOfflineQueue.packageIsComplete(at: package))
    try Data().write(to: package.appending(path: "seg-1.ts"))
    XCTAssertFalse(PutioOfflineQueue.packageIsComplete(at: package))
    XCTAssertFalse(
      PutioOfflineQueue.packageIsComplete(at: directory.appending(path: "missing.movpkg")))
  }

  func testHLSMasterPlaylistRenditionURIsMustExist() throws {
    let package = directory.appending(path: "multi.movpkg")
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    try Data(
      """
      #EXTM3U
      #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="Turkish",URI="tur.m3u8"
      #EXT-X-STREAM-INF:BANDWIDTH=1,AUDIO="a"
      video.m3u8
      """.utf8
    ).write(to: package.appending(path: "master.m3u8"))
    try Data("#EXTM3U\n#EXTINF:1,\nv.ts\n".utf8).write(to: package.appending(path: "video.m3u8"))
    try Data(count: 4).write(to: package.appending(path: "v.ts"))
    XCTAssertFalse(PutioOfflineQueue.packageIsComplete(at: package), "tur.m3u8 is missing")
    try Data("#EXTM3U\n#EXTINF:1,\nt.ts\n".utf8).write(to: package.appending(path: "tur.m3u8"))
    try Data(count: 4).write(to: package.appending(path: "t.ts"))
    XCTAssertTrue(PutioOfflineQueue.packageIsComplete(at: package))
    XCTAssertEqual(
      PutioOfflineQueue.playlistReferences(in: #"#EXT-X-KEY:METHOD=AES-128,URI="k.key",IV=1"#),
      ["k.key"])
    XCTAssertEqual(PutioOfflineQueue.playlistReferences(in: "#EXTINF:10,"), [])
  }

  func testPauseThenResumeWhileTheOldWorkerUnwindsRunsOneWorker() async throws {
    let gate = makeGate()
    var resolves = 0
    let queue = PutioOfflineQueue(
      store: PutioOfflineStore(directory: directory), engine: engine, conversionPollInterval: .zero,
      sleep: { _ in }, availableStorage: { 1_000_000_000 },
      resolve: { _, _ in
        resolves += 1
        await gate.wait()
        try Task.checkCancellation()
        return .ready(
          PutioPlaybackSource(url: URL(string: "https://media.test/x")!, startFromSeconds: 0))
      },
      startConversion: { _ in }, conversionStatus: { _ in .completed },
      reportPosition: { _, _ in })
    queue.enqueue(fileID: PutioFileID(rawValue: 80), parentID: .root, name: "w", kind: .video)
    try await gate.waitUntilEntered()
    queue.pause(fileID: PutioFileID(rawValue: 80))
    queue.resume(fileID: PutioFileID(rawValue: 80))
    await settle()
    await gate.open()
    await settle()
    XCTAssertEqual(resolves, 2, "the cancelled worker resolved once, the successor once")
    XCTAssertEqual(engine.started.count, 1, "only the successor started a download")
    XCTAssertEqual(queue.item(for: PutioFileID(rawValue: 80))?.stage, .downloading(progress: 0))
  }

  func testPauseAllHoldsEveryDownloadAndResumeAllRestartsThemWithinTheLimit() async throws {
    let queue = makeQueue()
    queue.setConcurrencyLimit(1)
    let ids = (1...3).map { PutioFileID(rawValue: $0) }
    for id in ids {
      queue.enqueue(fileID: id, parentID: .root, name: "\(id.rawValue)", kind: .video)
    }
    await settle()
    engine.onProgress?(ids[0], 0.5)
    XCTAssertEqual(queue.bulkAction, .pauseAll)

    queue.pauseAll()
    await settle()
    XCTAssertEqual(
      ids.map { queue.item(for: $0)?.stage },
      [.paused(progress: 0.5), .paused(progress: 0), .paused(progress: 0)])
    XCTAssertEqual(engine.started.map(\.0), [ids[0]], "a paused row started a download")
    XCTAssertEqual(queue.bulkAction, .resumeAll)

    queue.resumeAll()
    await settle()
    XCTAssertEqual(engine.resumed, [ids[0]], "the suspended task did not resume in place")
    XCTAssertEqual(
      ids.map { queue.item(for: $0)?.stage },
      [.downloading(progress: 0.5), .queued, .queued])
    XCTAssertEqual(queue.bulkAction, .pauseAll)

    await queue.remove(fileIDs: ids).value
    XCTAssertNil(queue.bulkAction, "an empty Downloading section still offers a bulk action")
  }

  func testCancelledWorkerFailureDoesNotFailItsReplacement() async throws {
    let failures: [Error] = [
      URLError(.cancelled), PutioRuntimeError.transient, PutioOfflineConversionError(),
    ]
    for failure in failures {
      let gate = makeGate()
      let engine = FakeEngine()
      let store = PutioOfflineStore(directory: directory.appending(path: UUID().uuidString))
      var resolves = 0
      let queue = PutioOfflineQueue(
        store: store, engine: engine, availableStorage: { 1_000_000_000 },
        resolve: { _, _ in
          resolves += 1
          if resolves == 1 {
            await gate.wait()
            throw failure
          }
          return .ready(
            PutioPlaybackSource(url: URL(string: "https://media.test/x")!, startFromSeconds: 0))
        },
        startConversion: { _ in }, conversionStatus: { _ in .completed },
        reportPosition: { _, _ in })
      let fileID = PutioFileID(rawValue: 80)
      queue.enqueue(fileID: fileID, parentID: .root, name: "w", kind: .video)
      try await gate.waitUntilEntered()
      queue.pause(fileID: fileID)
      queue.resume(fileID: fileID)
      await settle()
      XCTAssertEqual(engine.started.count, 1)
      await gate.open()
      await settle()
      XCTAssertEqual(queue.item(for: fileID)?.stage, .downloading(progress: 0), "\(failure)")
      XCTAssertTrue(engine.cancelled.isEmpty)
    }
  }

  func testConversionPollingStopsWhenItsSessionEnds() async throws {
    let gate = makeGate()
    var live = true
    var polls = 0
    let queue = PutioOfflineQueue(
      store: PutioOfflineStore(directory: directory), engine: engine,
      sleep: { _ in await gate.wait() }, availableStorage: { 1_000_000_000 },
      resolve: { _, _ in .conversionRequired }, startConversion: { _ in },
      conversionStatus: { _ in
        polls += 1
        return polls == 1 ? .queued : .failed
      },
      reportPosition: { _, _ in }, isLive: { live })
    let fileID = PutioFileID(rawValue: 81)
    queue.enqueue(fileID: fileID, parentID: .root, name: "w", kind: .video)
    try await gate.waitUntilEntered()
    XCTAssertEqual(polls, 1)
    live = false
    await gate.open()
    await settle()
    XCTAssertEqual(polls, 1, "the retired queue must not poll with the next session")
    XCTAssertTrue(engine.started.isEmpty)
    XCTAssertEqual(queue.item(for: fileID)?.stage, .waitingToConvert)
  }

  func testPositionSyncStopsWhenItsSessionEnds() async throws {
    let gate = makeGate()
    var live = true
    var syncing = false
    var synced: [PutioFileID] = []
    let queue = PutioOfflineQueue(
      store: PutioOfflineStore(directory: directory), engine: engine,
      availableStorage: { 1_000_000_000 },
      resolve: { _, _ in
        .ready(PutioPlaybackSource(url: URL(string: "https://media.test/x")!, startFromSeconds: 0))
      },
      startConversion: { _ in }, conversionStatus: { _ in .completed },
      reportPosition: { id, _ in
        guard syncing else { throw PutioRuntimeError.transient }
        synced.append(id)
        await gate.wait()
      }, isLive: { live })
    for rawID in 1...2 {
      let id = PutioFileID(rawValue: rawID)
      queue.enqueue(fileID: id, parentID: .root, name: "w", kind: .video)
      await queue.recordPosition(fileID: id, seconds: 10)
    }
    await settle()
    syncing = true
    let task = Task { await queue.syncPendingPositions() }
    try await gate.waitUntilEntered()
    XCTAssertEqual(synced, [PutioFileID(rawValue: 1)])
    live = false
    await gate.open()
    await task.value
    XCTAssertEqual(synced, [PutioFileID(rawValue: 1)])
    XCTAssertEqual(
      queue.pendingPositionCount, 2, "the retired queue leaves reconciliation to its successor")
  }

  func testEventJournalRoundTripsPerAccount() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "journal-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let entries = [
      PutioOfflineEventJournal.Entry(
        description: "7:412", location: "/tmp/a.movpkg", completed: true, failed: false),
      PutioOfflineEventJournal.Entry(
        description: "8:413", location: nil, completed: false, failed: true),
    ]
    try PutioOfflineEventJournal.save(entries)
    XCTAssertEqual(PutioOfflineEventJournal.load(), entries)
    try PutioOfflineEventJournal.save([])
    XCTAssertTrue(PutioOfflineEventJournal.load().isEmpty)
  }

  func testJournalReplayIgnoresEventsFromAReplacedTask() throws {
    try PutioOfflineEventJournal.save([])
    defer { try? PutioOfflineEventJournal.save([]) }
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    func task(_ description: String) -> URLSessionTask {
      let task = session.dataTask(with: URL(string: "https://download.test/task")!)
      task.taskDescription = description
      return task
    }
    // Identifiers grow in creation order, so each replacement is newer.
    let replaced = task("7:5")
    let live = task("7:5")
    let older = task("7:6")
    let newer = task("7:6")
    let otherAccount = task("8:5")
    let lost = URLError(.networkConnectionLost)
    try PutioOfflineEventJournal.append([
      .completion(task: replaced, error: lost),
      .location(task: live, URL(fileURLWithPath: "/tmp/live.movpkg")),
      .completion(task: older, error: lost),
      .location(task: newer, URL(fileURLWithPath: "/tmp/newer.movpkg")),
      .completion(task: newer, error: nil),
      .completion(task: otherAccount, error: nil),
    ])
    let engine = PutioSystemOfflineDownloadEngine(accountID: 7)
    var located: [Int] = []
    var finished: [(id: Int, succeeded: Bool)] = []
    engine.onLocation = { id, _ in located.append(id.rawValue) }
    engine.onFinished = { id, error in finished.append((id.rawValue, error == nil)) }

    PutioOfflineEventJournal.replay(
      into: engine, liveTasks: [PutioFileID(rawValue: 5): live.taskIdentifier])

    XCTAssertEqual(located, [5, 6])
    XCTAssertEqual(finished.map(\.id), [6], "the replaced task's failure never reaches file 5")
    XCTAssertEqual(finished.map(\.succeeded), [true], "the newest task speaks for file 6")
    XCTAssertEqual(PutioOfflineEventJournal.load().map(\.description), ["8:5"])
  }

  /// A non-empty directory where the journal goes fails every write.
  private func blockJournalWrites() throws {
    try PutioOfflineEventJournal.save([])
    try FileManager.default.createDirectory(
      at: PutioOfflineEventJournal.fileURL.appending(path: "blocked"),
      withIntermediateDirectories: true)
  }

  private func unblockJournalWrites() throws {
    try FileManager.default.removeItem(at: PutioOfflineEventJournal.fileURL)
  }

  /// Leaves no journal and nothing unwritten for the next test.
  private func resetJournal() {
    try? FileManager.default.removeItem(at: PutioOfflineEventJournal.fileURL)
    try? PutioOfflineEventJournal.retry()
    try? PutioOfflineEventJournal.save([])
  }

  func testAJournalWriteFailureIsReportedUntilARetryWritesIt() throws {
    try blockJournalWrites()
    defer { resetJournal() }
    let system = PutioSystemOfflineDownloadEngine(accountID: 7)
    let queue = makeQueue(engine: system)
    let relay = PutioOfflineDownloadRelay(dispatch: { work in MainActor.assumeIsolated { work() } })
    relay.engine = system
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let otherAccount = session.dataTask(with: URL(string: "https://download.test/task")!)
    otherAccount.taskDescription = "8:5"

    relay.urlSession(session, task: otherAccount, didCompleteWithError: nil)
    relay.urlSessionDidFinishEvents(forBackgroundURLSession: session)
    XCTAssertEqual(queue.persistenceFailure, .unsaved(outOfSpace: false))

    queue.retryPersisting()
    XCTAssertEqual(
      queue.persistenceFailure, .unsaved(outOfSpace: false), "a retry that fails again reports")

    try unblockJournalWrites()
    queue.retryPersisting()
    XCTAssertNil(queue.persistenceFailure)
    XCTAssertEqual(PutioOfflineEventJournal.load().map(\.description), ["8:5"])
  }

  func testAJournalThatCannotBeClearedReplaysEachEntryOnce() throws {
    try blockJournalWrites()
    defer { resetJournal() }
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    func task(_ description: String) -> URLSessionTask {
      let task = session.dataTask(with: URL(string: "https://download.test/task")!)
      task.taskDescription = description
      return task
    }
    XCTAssertThrowsError(
      try PutioOfflineEventJournal.append([
        .completion(task: task("7:5"), error: URLError(.networkConnectionLost)),
        .completion(task: task("8:6"), error: nil),
      ]))
    let engine = PutioSystemOfflineDownloadEngine(accountID: 7)
    var failed: [Int] = []
    var reported = 0
    engine.onFinished = { id, error in if error != nil { failed.append(id.rawValue) } }
    engine.onPersistenceFailure = { _ in reported += 1 }

    PutioOfflineEventJournal.replay(into: engine, liveTasks: [:])
    PutioOfflineEventJournal.replay(into: engine, liveTasks: [:])

    XCTAssertEqual(failed, [5], "the unwritten entry replays once; its claim is kept in memory")
    XCTAssertEqual(reported, 2, "each clear that does not reach disk is reported")
    try unblockJournalWrites()
    try PutioOfflineEventJournal.retry()
    XCTAssertEqual(PutioOfflineEventJournal.load().map(\.description), ["8:6"])
  }

  func testALegacyJournalEntryKeepsOnlyItsLocationForALiveTask() throws {
    try PutioOfflineEventJournal.save([
      PutioOfflineEventJournal.Entry(
        description: "7:5", location: "/tmp/legacy.movpkg", completed: false, failed: true),
      PutioOfflineEventJournal.Entry(
        description: "7:6", location: "/tmp/stale.movpkg", completed: false, failed: true),
      PutioOfflineEventJournal.Entry(
        description: "7:6", taskIdentifier: 9, location: "/tmp/live.movpkg", completed: true,
        failed: false),
    ])
    defer { resetJournal() }
    let engine = PutioSystemOfflineDownloadEngine(accountID: 7)
    var located: [String] = []
    var finished: [(id: Int, succeeded: Bool)] = []
    engine.onLocation = { id, url in located.append("\(id.rawValue):\(url.lastPathComponent)") }
    engine.onFinished = { id, error in finished.append((id.rawValue, error == nil)) }

    PutioOfflineEventJournal.replay(
      into: engine, liveTasks: [PutioFileID(rawValue: 5): 4, PutioFileID(rawValue: 6): 9])

    XCTAssertEqual(
      located, ["5:legacy.movpkg", "6:live.movpkg"],
      "a legacy destination is kept unless the live task's own entry has one")
    XCTAssertEqual(finished.map(\.id), [6], "a legacy failure never reaches a live task")
    XCTAssertEqual(finished.map(\.succeeded), [true])
  }

  func testSyncPointerSurvivesAWaitersFollowUpPass() async throws {
    let gate = makeGate()
    var attempts = 0
    let queue = PutioOfflineQueue(
      store: PutioOfflineStore(directory: directory), engine: engine, conversionPollInterval: .zero,
      sleep: { _ in }, availableStorage: { 1_000_000_000 },
      resolve: { _, _ in
        .ready(PutioPlaybackSource(url: URL(string: "https://media.test/x")!, startFromSeconds: 0))
      },
      startConversion: { _ in }, conversionStatus: { _ in .completed },
      reportPosition: { _, _ in
        attempts += 1
        if attempts == 1 { throw PutioRuntimeError.transient }
        if attempts == 2 { await gate.wait() }
      })
    queue.enqueue(fileID: PutioFileID(rawValue: 1), parentID: .root, name: "a", kind: .video)
    await settle()
    try engine.finish(PutioFileID(rawValue: 1), at: directory)
    await settle()
    await queue.recordPosition(fileID: PutioFileID(rawValue: 1), seconds: 5)
    let sync1 = Task { await queue.syncPendingPositions() }
    await settle()
    let sync2 = Task { await queue.syncPendingPositions() }
    await settle()
    // sync1 finished its pass; sync2's follow-up is parked on the gate.
    // A third caller must join that follow-up, not start a fourth loop.
    let sync3 = Task { await queue.syncPendingPositions() }
    await settle()
    await gate.open()
    await sync1.value
    await sync2.value
    await sync3.value
    XCTAssertEqual(attempts, 2, "the third caller joined the running pass")
    XCTAssertEqual(queue.pendingPositionCount, 0)
  }

  func testWaitersOnOnePassShareOneFollowUp() async throws {
    try await checkWaitersShareOneFollowUp(fails: false)
  }

  func testWaitersStopAfterTheirSharedFollowUpFails() async throws {
    try await checkWaitersShareOneFollowUp(fails: true)
  }

  private func checkWaitersShareOneFollowUp(fails: Bool) async throws {
    let firstPass = makeGate()
    let followUp = makeGate()
    var attempts = 0
    let queue = PutioOfflineQueue(
      store: PutioOfflineStore(directory: directory), engine: engine, conversionPollInterval: .zero,
      sleep: { _ in }, availableStorage: { 1_000_000_000 },
      resolve: { _, _ in
        .ready(PutioPlaybackSource(url: URL(string: "https://media.test/x")!, startFromSeconds: 0))
      },
      startConversion: { _ in }, conversionStatus: { _ in .completed },
      reportPosition: { _, _ in
        attempts += 1
        switch attempts {
        case 1: throw PutioRuntimeError.transient
        case 2:
          await firstPass.wait()
          throw PutioRuntimeError.transient
        default:
          await followUp.wait()
          if fails { throw PutioRuntimeError.transient }
        }
      })
    queue.enqueue(fileID: PutioFileID(rawValue: 1), parentID: .root, name: "a", kind: .video)
    await settle()
    try engine.finish(PutioFileID(rawValue: 1), at: directory)
    await settle()
    await queue.recordPosition(fileID: PutioFileID(rawValue: 1), seconds: 5)
    let sync1 = Task { await queue.syncPendingPositions() }
    await settle()
    // Both arrive while the first pass is parked; it then fails, so both wake
    // with the position still pending.
    let sync2 = Task { await queue.syncPendingPositions() }
    let sync3 = Task { await queue.syncPendingPositions() }
    await settle()
    await firstPass.open()
    await settle()
    XCTAssertEqual(attempts, 3, "one follow-up pass, not one per waiter")
    await followUp.open()
    await sync1.value
    await sync2.value
    await sync3.value
    XCTAssertEqual(attempts, 3)
    XCTAssertEqual(queue.pendingPositionCount, fails ? 1 : 0)
  }

  func testTaskDescriptionsCarryTheAccount() {
    XCTAssertEqual(PutioSystemOfflineDownloadEngine.parse("7:412")?.accountID, 7)
    XCTAssertEqual(PutioSystemOfflineDownloadEngine.parse("7:412")?.fileID.rawValue, 412)
    XCTAssertNil(PutioSystemOfflineDownloadEngine.parse("412"), "bare ids have no owner")
    XCTAssertNil(PutioSystemOfflineDownloadEngine.parse("x"))
  }

  func testEngineFailureRefillsTheSlot() async {
    let queue = makeQueue()
    queue.setConcurrencyLimit(1)
    queue.enqueue(fileID: PutioFileID(rawValue: 1), parentID: .root, name: "a", kind: .video)
    queue.enqueue(fileID: PutioFileID(rawValue: 2), parentID: .root, name: "b", kind: .video)
    await settle()
    XCTAssertEqual(engine.started.map(\.0.rawValue), [1])
    engine.onFinished?(PutioFileID(rawValue: 1), URLError(.networkConnectionLost))
    await settle()
    XCTAssertEqual(engine.started.map(\.0.rawValue), [1, 2])
  }

  func testCorruptDocumentIsSetAsideAndLimitIsClamped() throws {
    let store = PutioOfflineStore(directory: directory)
    try Data("not json".utf8).write(to: directory.appending(path: "queue.json"))
    let loaded = store.load()
    XCTAssertTrue(loaded.items.isEmpty)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: directory.appending(path: "queue.corrupt.json").path))
    try Data(#"{"version":1,"items":[],"concurrencyLimit":9}"#.utf8)
      .write(to: directory.appending(path: "queue.json"))
    XCTAssertEqual(store.load().concurrencyLimit, PutioOfflineQueue.defaultConcurrencyLimit)
    try Data(#"{"version":2,"items":[],"concurrencyLimit":1}"#.utf8)
      .write(to: directory.appending(path: "queue.json"))
    XCTAssertTrue(store.load().items.isEmpty)
  }

  /// Packages live outside the store directory, so a quarantined queue must
  /// not be the only record of them.
  func testPurgeDeletesPackagesAQuarantinedQueueNoLongerLists() async throws {
    let packages = FileManager.default.temporaryDirectory.appending(
      path: "offline-packages-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: packages, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: packages) }
    let queue = makeQueue()
    queue.enqueue(fileID: PutioFileID(rawValue: 1), parentID: .root, name: "a", kind: .video)
    queue.enqueue(fileID: PutioFileID(rawValue: 2), parentID: .root, name: "b", kind: .video)
    await settle()
    try engine.finish(PutioFileID(rawValue: 1), at: packages)
    try engine.finish(PutioFileID(rawValue: 2), at: packages)
    await settle()
    let kept = packages.appending(path: "1.movpkg")
    let removed = packages.appending(path: "2.movpkg")
    await queue.remove(fileIDs: [PutioFileID(rawValue: 2)]).value
    XCTAssertEqual(
      PutioOfflineStore(directory: directory).loadPackages(),
      [PutioOfflineQueue.relativePath(for: kept)])

    try Data("not json".utf8).write(to: directory.appending(path: "queue.json"))
    engine = FakeEngine()
    let relaunched = makeQueue()
    XCTAssertTrue(relaunched.items.isEmpty)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: directory.appending(path: "queue.corrupt.json").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))

    relaunched.purgeAccountStorage()
    XCTAssertFalse(FileManager.default.fileExists(atPath: kept.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: removed.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))

    // A location the system delivers after the purge is garbage: the task
    // ends, the package goes, and the account directory stays gone.
    try engine.finish(PutioFileID(rawValue: 3), at: packages)
    XCTAssertEqual(engine.cancelled, [PutioFileID(rawValue: 3)])
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: packages.appending(path: "3.movpkg").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
  }

  func testQueuesWrittenBeforeTheSidecarBackfillIt() async throws {
    let store = PutioOfflineStore(directory: directory)
    let item = PutioOfflineItem(
      id: PutioFileID(rawValue: 1), parentID: .root, name: "a", kind: .video, createdAt: .now,
      stage: .completed, localPath: "Library/Packages/1.movpkg", storedBytes: 512,
      storedAudioTracks: [], storedSubtitleTracks: [],
      resumePositionSeconds: 0, pendingPositionSeconds: nil, estimatedBytes: 0)
    try store.save(items: [item], concurrencyLimit: 2)
    XCTAssertTrue(store.loadPackages().isEmpty)
    _ = makeQueue()
    XCTAssertEqual(store.loadPackages(), ["Library/Packages/1.movpkg"])
  }

  /// Packages refuse to delete, as when a task still holds the directory;
  /// everything else, including the store directory, deletes normally.
  private final class StickyFileManager: FileManager {
    override func removeItem(at url: URL) throws {
      if url.pathExtension == "movpkg" { throw CocoaError(.fileWriteNoPermission) }
      try super.removeItem(at: url)
    }
  }

  func testAPackageThatFailsToDeleteStaysTrackedForThePurge() async throws {
    let queue = PutioOfflineQueue(
      store: PutioOfflineStore(directory: directory), engine: engine, conversionPollInterval: .zero,
      sleep: { _ in }, availableStorage: { 10_000_000_000 }, fileManager: StickyFileManager(),
      resolve: { _, _ in
        .ready(PutioPlaybackSource(url: URL(string: "https://m/1")!, startFromSeconds: 0))
      },
      startConversion: { _ in }, conversionStatus: { _ in .completed }, reportPosition: { _, _ in })
    queue.enqueue(fileID: PutioFileID(rawValue: 1), parentID: .root, name: "a", kind: .video)
    await settle()
    // Outside the store directory, where AVFoundation keeps real packages.
    let location = FileManager.default.temporaryDirectory.appending(
      path: "offline-sticky-\(UUID().uuidString).movpkg")
    try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: location) }
    engine.onLocation?(PutioFileID(rawValue: 1), location)
    await queue.remove(fileIDs: [PutioFileID(rawValue: 1)]).value
    let tracked: Set<String> = [PutioOfflineQueue.relativePath(for: location)]
    XCTAssertEqual(PutioOfflineStore(directory: directory).loadPackages(), tracked)

    // The purge wipes the store directory but brings the sidecar back for
    // the package that would not delete, so the next purge retries it.
    queue.purgeAccountStorage()
    XCTAssertTrue(FileManager.default.fileExists(atPath: location.path))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: directory.appending(path: "queue.json").path))
    XCTAssertEqual(PutioOfflineStore(directory: directory).loadPackages(), tracked)
  }

  func testConversionHandoffKeepsOneIdentity() async {
    resolutions[5] = [.conversionRequired]
    conversionStatuses = [.queued, .converting(progress: 0.5), .completed]
    let queue = makeQueue()
    queue.enqueue(fileID: PutioFileID(rawValue: 5), parentID: .root, name: "c", kind: .video)
    await settle()
    XCTAssertEqual(conversionStarts, 1)
    XCTAssertEqual(queue.items.count, 1)
    XCTAssertEqual(engine.started.map(\.0.rawValue), [5])
    XCTAssertEqual(queue.item(for: PutioFileID(rawValue: 5))?.stage, .downloading(progress: 0))
  }

  func testAQueueWrittenWithLanguageSelectionsStillLoads() throws {
    let store = PutioOfflineStore(directory: directory)
    let location = directory.appending(path: "old.movpkg")
    try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
    let stored = [
      PutioOfflineTrack(languageCode: "en", displayName: "English"),
      PutioOfflineTrack(languageCode: "tr", displayName: "Turkish"),
    ]
    try store.save(
      items: [
        PutioOfflineItem(
          id: PutioFileID(rawValue: 9), parentID: .root, name: "old", kind: .video,
          createdAt: .now, stage: .completed, localPath: location.path, storedBytes: 64,
          storedAudioTracks: stored, storedSubtitleTracks: [], resumePositionSeconds: 0,
          pendingPositionSeconds: nil, estimatedBytes: 64)
      ], concurrencyLimit: 2)
    let file = directory.appending(path: "queue.json")
    var document = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    var items = try XCTUnwrap(document["items"] as? [[String: Any]])
    items[0]["selectedAudioLanguages"] = ["en"]
    items[0]["awaitsLanguageSelection"] = false
    document["items"] = items
    try JSONSerialization.data(withJSONObject: document).write(to: file)

    let loaded = PutioOfflineStore(directory: directory).load().items
    XCTAssertEqual(loaded.map(\.id.rawValue), [9])
    XCTAssertEqual(loaded.first?.storedAudioTracks, stored)
    XCTAssertEqual(loaded.first?.isPlayable, true)
  }

  func testConversionFailureIsRetryableUnderTheSameItem() async {
    resolutions[6] = [.conversionRequired, .conversionRequired]
    conversionStatuses = [.failed, .completed]
    let queue = makeQueue()
    queue.enqueue(fileID: PutioFileID(rawValue: 6), parentID: .root, name: "d", kind: .video)
    await settle()
    XCTAssertEqual(queue.item(for: PutioFileID(rawValue: 6))?.stage, .failed(.conversion))
    queue.retry(fileID: PutioFileID(rawValue: 6))
    await settle()
    XCTAssertEqual(conversionStarts, 2)
    XCTAssertEqual(queue.item(for: PutioFileID(rawValue: 6))?.stage, .downloading(progress: 0))
  }

  func testPauseResumeCancelAndStorageWait() async throws {
    let queue = makeQueue()
    queue.enqueue(fileID: PutioFileID(rawValue: 1), parentID: .root, name: "a", kind: .video)
    await settle()
    engine.onProgress?(PutioFileID(rawValue: 1), 0.3)
    queue.pause(fileID: PutioFileID(rawValue: 1))
    XCTAssertEqual(engine.paused, [PutioFileID(rawValue: 1)])
    XCTAssertEqual(queue.item(for: PutioFileID(rawValue: 1))?.stage, .paused(progress: 0.3))
    // A completion callback for a paused item does not flip it to failed.
    engine.onFinished?(PutioFileID(rawValue: 1), URLError(.cancelled))
    XCTAssertEqual(queue.item(for: PutioFileID(rawValue: 1))?.stage, .paused(progress: 0.3))
    queue.resume(fileID: PutioFileID(rawValue: 1))
    await settle()
    XCTAssertEqual(engine.started.count, 2)

    try engine.finish(PutioFileID(rawValue: 1), at: directory)
    await settle()
    let stored = queue.storedBytes
    XCTAssertGreaterThan(stored, 0)
    let path = try! XCTUnwrap(queue.item(for: PutioFileID(rawValue: 1))?.localPath)
    await queue.remove(fileIDs: [PutioFileID(rawValue: 1)]).value
    XCTAssertEqual(queue.storedBytes, 0)
    XCTAssertTrue(queue.items.isEmpty)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: PutioOfflineQueue.localURL(for: path).path))

    let full = makeQueue(availableBytes: 1)
    full.enqueue(fileID: PutioFileID(rawValue: 9), parentID: .root, name: "z", kind: .audio)
    await settle()
    XCTAssertEqual(full.item(for: PutioFileID(rawValue: 9))?.stage, .waitingForStorage)
  }

  func testRemovingOrCancellingADownloadAsksPutioForNothing() async throws {
    let queue = makeQueue()
    let finished = PutioFileID(rawValue: 1)
    let running = PutioFileID(rawValue: 2)
    queue.enqueue(fileID: finished, parentID: .root, name: "a", kind: .video)
    queue.enqueue(fileID: running, parentID: .root, name: "b", kind: .audio)
    await settle()
    try engine.finish(finished, at: directory)
    await settle()
    let path = try XCTUnwrap(queue.item(for: finished)?.localPath)
    runtimeCalls = []

    await queue.remove(fileIDs: [running]).value
    await queue.remove(fileIDs: [finished]).value
    await settle()

    XCTAssertEqual(runtimeCalls, [], "removal reached put.io")
    XCTAssertTrue(engine.cancelled.contains(running))
    XCTAssertTrue(queue.items.isEmpty)
    XCTAssertEqual(queue.storedBytes, 0)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: PutioOfflineQueue.localURL(for: path).path))
  }

  func testAQueueThatOwedOriginalsKeepsItsRowsAndAsksPutioForNothing() async throws {
    let queue = makeQueue()
    let fileID = PutioFileID(rawValue: 1)
    queue.enqueue(fileID: fileID, parentID: .root, name: "a", kind: .audio)
    await settle()
    try engine.finish(fileID, at: directory)
    await settle()
    let document = directory.appending(path: "queue.json")
    var saved = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: document)) as? [String: Any])
    saved["pendingOriginals"] = [["id": 1, "name": "a", "movesToTrash": true]]
    try JSONSerialization.data(withJSONObject: saved).write(to: document)
    runtimeCalls = []

    let relaunched = makeQueue()
    await relaunched.restore()
    await settle()

    XCTAssertEqual(relaunched.items.map(\.id), [fileID], "an owed original removed the row")
    XCTAssertEqual(relaunched.item(for: fileID)?.stage, .completed)
    XCTAssertEqual(runtimeCalls, [], "the relaunch reached put.io")
  }

  func testRemovalCopyNamesTheDeviceAndKeepsTheFileInTheAccount() {
    let phone = PutioOfflineRemovalCopy(isPad: false)
    let pad = PutioOfflineRemovalCopy(isPad: true)
    XCTAssertEqual(phone.actionTitle, "Remove from this iPhone")
    XCTAssertEqual(pad.actionTitle, "Remove from this iPad")
    XCTAssertEqual(phone.title(count: 1), "Remove from this iPhone?")
    XCTAssertEqual(pad.title(count: 1), "Remove from this iPad?")
    XCTAssertEqual(phone.title(count: 2), "Remove 2 downloads from this iPhone?")
    XCTAssertEqual(
      phone.message(names: ["Sintel.2010.1080p.mkv"]),
      "“Sintel.2010.1080p.mkv” stays in your put.io files. Only the copy on this iPhone is removed."
    )
    XCTAssertEqual(
      pad.message(names: ["a", "b"]),
      "The files stay in your put.io account. Only the copies on this iPad are removed.")
  }

  private func blockQueueWrites() throws {
    try? FileManager.default.removeItem(at: directory.appending(path: "queue.json"))
    try FileManager.default.createDirectory(
      at: directory.appending(path: "queue.json/blocked"), withIntermediateDirectories: true)
  }

  private func unblockQueueWrites() throws {
    try FileManager.default.removeItem(at: directory.appending(path: "queue.json"))
  }

  func testARemovalThatCannotBeSavedRemovesNothing() async throws {
    let queue = makeQueue()
    let running = PutioFileID(rawValue: 1)
    let finished = PutioFileID(rawValue: 2)
    queue.enqueue(fileID: running, parentID: .root, name: "a", kind: .video)
    queue.enqueue(fileID: finished, parentID: .root, name: "b", kind: .video)
    await settle()
    try engine.finish(finished, at: directory)
    await settle()
    let package = try XCTUnwrap(queue.item(for: finished)?.localPath)
    try blockQueueWrites()

    XCTAssertNil(queue.removeSaved(fileIDs: [running, finished]))
    XCTAssertEqual(queue.items.map(\.id), [running, finished])
    XCTAssertTrue(queue.removing.isEmpty)
    XCTAssertTrue(engine.cancelled.isEmpty, "a failed removal cancelled the running download")
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: PutioOfflineQueue.localURL(for: package).path),
      "a failed removal deleted the package")
    XCTAssertNil(queue.persistenceFailure, "the removal failure also raised the save alert")

    try unblockQueueWrites()
    await queue.removeSaved(fileIDs: [running, finished])?.value
    XCTAssertTrue(queue.items.isEmpty)
    XCTAssertEqual(engine.cancelled, [running, finished])
    XCTAssertTrue(PutioOfflineStore(directory: directory).load().items.isEmpty)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: PutioOfflineQueue.localURL(for: package).path))
  }

  func testRemovalFailureCopyCountsAndNamesTheDevice() {
    let phone = PutioOfflineRemovalCopy(isPad: false)
    let pad = PutioOfflineRemovalCopy(isPad: true)
    XCTAssertEqual(phone.failureTitle(count: 3), "Could not remove downloads")
    XCTAssertEqual(
      phone.failureMessage(count: 3),
      "Nothing was removed because this iPhone could not save the change. Remove the downloads again."
    )
    XCTAssertEqual(pad.failureTitle(count: 1), "Could not remove download")
    XCTAssertEqual(
      pad.failureMessage(count: 1),
      "Nothing was removed because this iPad could not save the change. Remove the download again.")
  }

  func testSelectedSizeCountsOnlyBytesOnTheDevice() {
    func item(_ stage: PutioOfflineItem.Stage, stored: Int64 = 0) -> PutioOfflineItem {
      PutioOfflineItem(
        id: PutioFileID(rawValue: 1), parentID: .root, name: "a", kind: .video, createdAt: .now,
        stage: stage, localPath: nil, storedBytes: stored,
        storedAudioTracks: [], storedSubtitleTracks: [], resumePositionSeconds: 0,
        pendingPositionSeconds: nil, estimatedBytes: 1_000)
    }
    XCTAssertEqual(item(.completed, stored: 900).bytesOnDevice, 900)
    XCTAssertEqual(item(.downloading(progress: 0.42)).bytesOnDevice, 420)
    XCTAssertEqual(item(.paused(progress: 0.5)).bytesOnDevice, 500)
    XCTAssertEqual(item(.converting(progress: 0.5)).bytesOnDevice, 0)
    XCTAssertEqual(item(.queued).bytesOnDevice, 0)
  }

  func testAFailedQueueWriteStaysReportedUntilARetryWritesIt() async throws {
    let queue = makeQueue()
    try blockQueueWrites()
    queue.enqueue(fileID: PutioFileID(rawValue: 1), parentID: .root, name: "a", kind: .audio)
    XCTAssertEqual(queue.persistenceFailure, .unsaved(outOfSpace: false))

    queue.retryPersisting()
    XCTAssertEqual(
      queue.persistenceFailure, .unsaved(outOfSpace: false), "a retry that fails again reports")

    try unblockQueueWrites()
    queue.retryPersisting()
    XCTAssertNil(queue.persistenceFailure)
    XCTAssertEqual(PutioOfflineStore(directory: directory).load().items.map(\.id.rawValue), [1])
  }

  func testARetryForgetsAPackageWhoseRemovalWasNotRecorded() async throws {
    let queue = makeQueue()
    let fileID = PutioFileID(rawValue: 1)
    queue.enqueue(fileID: fileID, parentID: .root, name: "a", kind: .video)
    await settle()
    try engine.finish(fileID, at: directory)
    await settle()
    let path = try XCTUnwrap(queue.item(for: fileID)?.localPath)
    let store = PutioOfflineStore(directory: directory)
    XCTAssertEqual(store.loadPackages(), [path])
    // An immutable record reads but can be neither replaced nor removed.
    let record = directory.appending(path: "packages.json").path
    try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: record)
    defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: record) }

    await queue.remove(fileIDs: [fileID]).value
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: PutioOfflineQueue.localURL(for: path).path))
    XCTAssertEqual(queue.persistenceFailure, .unsaved(outOfSpace: false))

    try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: record)
    queue.retryPersisting()
    XCTAssertNil(queue.persistenceFailure)
    XCTAssertTrue(store.loadPackages().isEmpty, "the retry forgets the removed package")
  }

  func testAPurgeThatCannotClearTheQueueStaysReported() async throws {
    let queue = makeQueue()
    let fileID = PutioFileID(rawValue: 1)
    queue.enqueue(fileID: fileID, parentID: .root, name: "a", kind: .video)
    await settle()
    try engine.finish(fileID, at: directory)
    await settle()
    // An immutable queue document keeps the directory from being removed.
    let document = directory.appending(path: "queue.json").path
    try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: document)
    defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: document) }

    queue.purgeAccountStorage()
    XCTAssertEqual(queue.persistenceFailure, .unsaved(outOfSpace: false))

    try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: document)
    queue.retryPersisting()
    XCTAssertNil(queue.persistenceFailure)
    let store = PutioOfflineStore(directory: directory)
    XCTAssertTrue(store.load().items.isEmpty, "the purged row does not come back")
    XCTAssertTrue(store.loadPackages().isEmpty)
  }

  func testDownloadErrorsMapToRetryableFailures() async {
    let queue = makeQueue()
    queue.enqueue(fileID: PutioFileID(rawValue: 1), parentID: .root, name: "a", kind: .video)
    await settle()
    engine.onFinished?(PutioFileID(rawValue: 1), URLError(.networkConnectionLost))
    XCTAssertEqual(queue.item(for: PutioFileID(rawValue: 1))?.stage, .failed(.download))
    queue.retry(fileID: PutioFileID(rawValue: 1))
    await settle()
    engine.onFinished?(
      PutioFileID(rawValue: 1),
      NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError))
    XCTAssertEqual(queue.item(for: PutioFileID(rawValue: 1))?.stage, .failed(.storage))
    XCTAssertTrue(PutioOfflineFailure.resolving(PutioRuntimeError.notFound)?.canRetry == false)
    XCTAssertEqual(PutioOfflineFailure.resolving(PutioRuntimeError.sessionExpired), .authentication)
  }

  func testPositionsRecordLocallyAndSyncWhenReportingRecovers() async throws {
    let queue = makeQueue()
    queue.enqueue(fileID: PutioFileID(rawValue: 1), parentID: .root, name: "a", kind: .video)
    await settle()
    try engine.finish(PutioFileID(rawValue: 1), at: directory)
    await settle()

    reportShouldFail = true
    await queue.recordPosition(fileID: PutioFileID(rawValue: 1), seconds: 42)
    XCTAssertEqual(queue.pendingPositionCount, 1)
    XCTAssertEqual(queue.localSource(for: PutioFileID(rawValue: 1))?.startFromSeconds, 42)
    XCTAssertTrue(reports.isEmpty)

    // The pending position survives relaunch.
    let restored = makeQueue()
    XCTAssertEqual(restored.pendingPositionCount, 1)

    reportShouldFail = false
    await restored.syncPendingPositions()
    XCTAssertEqual(reports.map { $0.1 }, [42])
    XCTAssertEqual(restored.pendingPositionCount, 0)

    await restored.recordPosition(fileID: PutioFileID(rawValue: 1), seconds: 50)
    XCTAssertEqual(reports.map { $0.1 }, [42, 50])
    XCTAssertEqual(restored.pendingPositionCount, 0)
  }

  func testLocalPathsAreStoredRelativeToTheContainer() {
    let absolute = URL(
      fileURLWithPath:
        "/.nofollow/Users/x/Library/Developer/CoreSimulator/Devices/D/data/Containers/Data/Application/1EC0/Library/com.apple.UserManagedAssets.G/Movie.movpkg"
    )
    let relative = PutioOfflineQueue.relativePath(for: absolute)
    XCTAssertEqual(relative, "Library/com.apple.UserManagedAssets.G/Movie.movpkg")
    XCTAssertEqual(
      PutioOfflineQueue.localURL(for: relative).path,
      URL(fileURLWithPath: NSHomeDirectory()).appending(path: relative).path)
    let outside = URL(fileURLWithPath: "/tmp/elsewhere/Movie.movpkg")
    XCTAssertEqual(PutioOfflineQueue.relativePath(for: outside), "/tmp/elsewhere/Movie.movpkg")
    XCTAssertEqual(
      PutioOfflineQueue.localURL(for: "/tmp/elsewhere/Movie.movpkg").path,
      "/tmp/elsewhere/Movie.movpkg")
  }

  func testSyncRequestedMidSyncRunsASecondPass() async throws {
    let gate = makeGate()
    var attempts = 0
    let queue = PutioOfflineQueue(
      store: PutioOfflineStore(directory: directory), engine: engine, conversionPollInterval: .zero,
      sleep: { _ in }, availableStorage: { 1_000_000_000 },
      resolve: { _, _ in
        .ready(PutioPlaybackSource(url: URL(string: "https://media.test/x")!, startFromSeconds: 0))
      },
      startConversion: { _ in }, conversionStatus: { _ in .completed },
      reportPosition: { _, _ in
        attempts += 1
        if attempts <= 2 { throw PutioRuntimeError.transient }
        if attempts == 3 { await gate.wait() }
      })
    queue.enqueue(fileID: PutioFileID(rawValue: 1), parentID: .root, name: "a", kind: .video)
    queue.enqueue(fileID: PutioFileID(rawValue: 2), parentID: .root, name: "b", kind: .video)
    await settle()
    try engine.finish(PutioFileID(rawValue: 1), at: directory)
    try engine.finish(PutioFileID(rawValue: 2), at: directory)
    await settle()
    await queue.recordPosition(fileID: PutioFileID(rawValue: 1), seconds: 5)
    await queue.recordPosition(fileID: PutioFileID(rawValue: 2), seconds: 9)
    XCTAssertEqual(queue.pendingPositionCount, 2)
    // The first pass parks on item 1; a second sync request lands meanwhile.
    let sync1 = Task { await queue.syncPendingPositions() }
    try await gate.waitUntilEntered()
    let sync2 = Task { await queue.syncPendingPositions() }
    await settle()
    await gate.open()
    await sync1.value
    await sync2.value
    XCTAssertEqual(queue.pendingPositionCount, 0)
  }

  func testStreamEstimateCountsEveryAudioRendition() {
    XCTAssertEqual(
      PutioSystemOfflineDownloadEngine.estimatedBytes(
        seconds: 100, videoBitrate: 0, audioRenditions: 2),
      18_750_000 + 3_200_000)
    XCTAssertEqual(
      PutioSystemOfflineDownloadEngine.estimatedBytes(
        seconds: 100, videoBitrate: 4_000_000, audioRenditions: 1),
      50_000_000 + 1_600_000)
  }

  func testPreferredLanguageMatchesTheFirstStoredPreference() {
    let stored = [
      PutioOfflineTrack(languageCode: "en", displayName: "English"),
      PutioOfflineTrack(languageCode: "tr", displayName: "Turkish"),
    ]
    XCTAssertEqual(
      PutioOfflineLanguage.match(from: stored, preferredLanguages: ["tr-TR", "en-US"])?
        .languageCode, "tr")
    XCTAssertNil(PutioOfflineLanguage.match(from: stored, preferredLanguages: ["de-DE"]))
    XCTAssertNil(PutioOfflineLanguage.match(from: [], preferredLanguages: ["en"]))
  }

  /// AVFoundation refuses HLS playlists over file URLs, so the multi-audio
  /// fixture is proven through the journey's real download; here the bundled
  /// audio file proves the reader and the language normalisation.
  func testStoredTracksAreReadFromTheDownloadedAsset() async throws {
    let fixture = try XCTUnwrap(
      Bundle.main.url(
        forResource: "runtime-proof-audio", withExtension: "m4a", subdirectory: "HarnessMedia"))
    let tracks = await PutioOfflineQueue.storedTracks(at: fixture)
    XCTAssertEqual(tracks.audio.count, 1)
    XCTAssertTrue(tracks.subtitles.isEmpty)
    XCTAssertEqual(PutioOfflineLanguage.normalize("eng"), "en")
    XCTAssertEqual(PutioOfflineLanguage.normalize("tr-TR"), "tr")
    XCTAssertEqual(PutioOfflineLanguage.normalize("und"), "und")
  }

  func testTheIPadDetailOffersEachStateItsActionsAndFacts() throws {
    let english = Locale(identifier: "en_US")
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let tracks = [
      PutioOfflineTrack(languageCode: "en", displayName: "English"),
      PutioOfflineTrack(languageCode: "tr", displayName: "Turkish"),
    ]
    func item(
      _ stage: PutioOfflineItem.Stage, kind: PutioOfflineItem.Kind = .video,
      bytes: Int64 = 3_300_000_000
    ) -> PutioOfflineItem {
      PutioOfflineItem(
        id: PutioFileID(rawValue: 441), parentID: .root, name: "S04E01.mkv", kind: kind,
        createdAt: now, stage: stage, localPath: stage == .completed ? "a.movpkg" : nil,
        storedBytes: stage == .completed ? 3_240_000_000 : 0,
        storedAudioTracks: stage == .completed && kind == .video ? tracks : [],
        storedSubtitleTracks: stage == .completed && kind == .video
          ? tracks + [PutioOfflineTrack(languageCode: "en", displayName: "English")] : [],
        resumePositionSeconds: 18 * 60 + 42, pendingPositionSeconds: nil, estimatedBytes: bytes)
    }
    func facts(
      _ item: PutioOfflineItem, slot: Bool = false, subtitles: [String]? = nil
    ) -> PutioOfflineDetailFacts {
      PutioOfflineDetailFacts(
        item, queuePosition: nil, isWaitingForSlot: slot, remoteSubtitles: subtitles,
        locale: english, now: now)
    }

    let finished = facts(item(.completed))
    XCTAssertEqual(finished.actions, [.play, .remove])
    XCTAssertEqual(finished.resumeSeconds, 1_122)
    XCTAssertEqual(finished.size, "3.24 GB")
    XCTAssertNotNil(finished.downloaded)
    XCTAssertNil(finished.status)
    XCTAssertEqual(finished.audio, "English, Turkish")
    XCTAssertEqual(finished.subtitles, "English, Turkish")

    let audio = facts(item(.completed, kind: .audio))
    XCTAssertEqual(audio.actions, [.play, .remove])
    XCTAssertNil(audio.subtitles, "an audio download lists subtitles")
    XCTAssertNil(audio.audio)

    let running = facts(
      item(.downloading(progress: 0.42)), subtitles: ["English", "English SDH", "Turkish"])
    XCTAssertEqual(running.actions, [.pause, .cancel])
    XCTAssertNil(running.resumeSeconds, "a running download offers to resume playback")
    XCTAssertEqual(running.size, "1.39 of 3.3 GB")
    XCTAssertEqual(running.status, .init(text: "Downloading", numeric: "42%", isFailure: false))
    XCTAssertNil(running.downloaded)
    XCTAssertNil(running.audio, "a running download names tracks it has not stored")
    XCTAssertEqual(running.subtitles, "English, English SDH, Turkish")

    let paused = facts(item(.paused(progress: 0.42)))
    XCTAssertEqual(paused.actions, [.resume, .cancel])
    XCTAssertEqual(paused.size, "1.39 of 3.3 GB")
    XCTAssertEqual(paused.status?.text, "Paused")
    XCTAssertEqual(facts(item(.paused(progress: 0.42)), slot: true).actions, [.pause, .cancel])
    XCTAssertEqual(facts(item(.queued)).actions, [.pause, .cancel])

    let lost = try XCTUnwrap(PutioOfflineFailure.resolving(PutioRuntimeError.transient))
    let failed = facts(item(.failed(lost), bytes: 3_400_000_000), subtitles: ["English"])
    XCTAssertEqual(failed.actions, [.retry, .remove])
    XCTAssertEqual(failed.size, "3.4 GB")
    XCTAssertEqual(failed.status, .init(text: "Connection lost", numeric: nil, isFailure: true))
    XCTAssertNil(failed.audio, "a failed download lists audio")
    XCTAssertNil(failed.subtitles, "a failed download lists subtitles")

    XCTAssertEqual(facts(item(.missing)).actions, [.downloadAgain, .remove])
  }
}
