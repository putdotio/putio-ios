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
    var started: [(PutioFileID, [String])] = []
    var paused: [PutioFileID] = []
    var resumed: [PutioFileID] = []
    var cancelled: [PutioFileID] = []
    var alive: [PutioFileID] = []
    var inventory = PutioOfflineInventory(videoBytes: 1_000, audioOptions: [], subtitleTracks: [])

    func inventory(url: URL) async throws -> PutioOfflineInventory { inventory }
    func start(fileID: PutioFileID, url: URL, title: String, audioLanguages: [String]) async throws
    {
      started.append((fileID, audioLanguages))
    }
    func pause(fileID: PutioFileID) { paused.append(fileID) }
    func resume(fileID: PutioFileID) { resumed.append(fileID) }
    func cancel(fileID: PutioFileID) { cancelled.append(fileID) }
    func restoreTasks() async -> [PutioFileID] { alive }
    func stop() {}

    func finish(_ id: PutioFileID, at directory: URL) {
      let location = directory.appending(path: "\(id.rawValue).movpkg")
      try? FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
      try? Data(count: 512).write(to: location.appending(path: "segment.bin"))
      onLocation?(id, location)
      onFinished?(id, nil)
    }
  }

  /// A one-shot latch for tests that interleave a queue action with an
  /// in-flight resolution.
  private actor AsyncGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
      if opened { return }
      await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
      opened = true
      for waiter in waiters { waiter.resume() }
      waiters = []
    }
  }

  private var directory: URL!
  private var engine: FakeEngine!
  private var reports: [(Int, Int)] = []
  private var reportShouldFail = false
  private var resolutions: [Int: [PutioPlaybackResolution]] = [:]
  private var conversionStatuses: [PutioVideoConversionStatus] = []
  private var conversionStarts = 0

  override func setUp() async throws {
    directory = FileManager.default.temporaryDirectory.appending(
      path: "offline-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    engine = FakeEngine()
    reports = []
    reportShouldFail = false
    resolutions = [:]
    conversionStatuses = []
    conversionStarts = 0
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: directory)
  }

  private func makeQueue(availableBytes: Int64 = 10_000_000_000) -> PutioOfflineQueue {
    PutioOfflineQueue(
      store: PutioOfflineStore(directory: directory),
      engine: engine,
      conversionPollInterval: .zero,
      sleep: { _ in },
      availableStorage: { availableBytes },
      readTracks: { _ in
        ([PutioOfflineTrack(languageCode: "en", displayName: "English")], [])
      },
      resolve: { fileID, _ in
        if var queued = self.resolutions[fileID.rawValue], !queued.isEmpty {
          let next = queued.removeFirst()
          self.resolutions[fileID.rawValue] = queued
          return next
        }
        return .ready(
          PutioPlaybackSource(
            url: URL(string: "https://media.test/\(fileID.rawValue).m3u8")!, startFromSeconds: 7))
      },
      startConversion: { _ in self.conversionStarts += 1 },
      conversionStatus: { _ in
        self.conversionStatuses.isEmpty ? .completed : self.conversionStatuses.removeFirst()
      },
      reportPosition: { fileID, seconds in
        if self.reportShouldFail { throw PutioRuntimeError.transient }
        self.reports.append((fileID.rawValue, seconds))
      }
    )
  }

  private func settle() async {
    for _ in 0..<40 { await Task.yield() }
    try? await Task.sleep(for: .milliseconds(50))
    for _ in 0..<40 { await Task.yield() }
  }

  func testConcurrencyLimitBoundsActiveDownloadsAcrossMixedKinds() async {
    let queue = makeQueue()
    queue.setConcurrencyLimit(2)
    for (id, kind) in [(1, PutioOfflineItem.Kind.video), (2, .audio), (3, .video)] {
      queue.enqueue(fileID: PutioFileID(rawValue: id), parentID: .root, name: "\(id)", kind: kind)
    }
    await settle()
    XCTAssertEqual(engine.started.map(\.0.rawValue), [1, 2])
    XCTAssertEqual(queue.item(for: PutioFileID(rawValue: 3))?.stage, .queued)

    engine.finish(PutioFileID(rawValue: 1), at: directory)
    await settle()
    XCTAssertEqual(engine.started.map(\.0.rawValue), [1, 2, 3])
    XCTAssertEqual(queue.item(for: PutioFileID(rawValue: 1))?.stage, .completed)
    XCTAssertEqual(queue.item(for: PutioFileID(rawValue: 1))?.resumePositionSeconds, 7)
    XCTAssertGreaterThan(queue.storedBytes, 0)
  }

  func testQueuePersistsAndRestoresPausingOrphanedDownloads() async {
    let queue = makeQueue()
    queue.enqueue(fileID: PutioFileID(rawValue: 1), parentID: .root, name: "a", kind: .video)
    queue.enqueue(fileID: PutioFileID(rawValue: 2), parentID: .root, name: "b", kind: .video)
    await settle()
    engine.onProgress?(PutioFileID(rawValue: 1), 0.4)
    engine.finish(PutioFileID(rawValue: 2), at: directory)
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
    var (items, limit) = survivorStore.load()
    items[0].stage = .downloading(progress: 0.4)
    survivorStore.save(items: items, concurrencyLimit: limit)
    let survivor = FakeEngine()
    survivor.alive = [PutioFileID(rawValue: 1)]
    engine = survivor
    let persisted = makeQueue()
    await persisted.restore()
    await settle()
    XCTAssertEqual(
      persisted.item(for: PutioFileID(rawValue: 1))?.stage, .downloading(progress: 0.4))
    XCTAssertTrue(survivor.started.isEmpty, "a live task must not be restarted")
    survivor.finish(PutioFileID(rawValue: 1), at: directory)
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

  func testPauseDuringResolutionWinsOverTheWorker() async {
    let gate = AsyncGate()
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
    await settle()
    queue.pause(fileID: PutioFileID(rawValue: 4))
    await gate.open()
    await settle()
    XCTAssertEqual(queue.item(for: PutioFileID(rawValue: 4))?.stage, .paused(progress: 0))
    XCTAssertTrue(engine.started.isEmpty, "a paused item must not start a download")
  }

  func testResumeAtTheLimitWaitsForASlot() async {
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
    engine.finish(PutioFileID(rawValue: 2), at: directory)
    await settle()
    XCTAssertEqual(engine.resumed, [PutioFileID(rawValue: 1)])
    XCTAssertEqual(engine.started.count, 2, "the suspended task resumed without a restart")
    XCTAssertEqual(queue.item(for: PutioFileID(rawValue: 1))?.stage, .downloading(progress: 0.5))
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

  func testEstimateBeyondFreeSpaceFailsBeforeStarting() async {
    let queue = makeQueue(availableBytes: 500_000_000)
    queue.enqueue(
      fileID: PutioFileID(rawValue: 1), parentID: .root, name: "a", kind: .video,
      estimatedBytes: 900_000_000)
    await settle()
    XCTAssertEqual(queue.item(for: PutioFileID(rawValue: 1))?.stage, .failed(.storage))
    XCTAssertTrue(engine.started.isEmpty)
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

  func testConversionHandoffKeepsOneIdentityAndSelectedTracks() async {
    resolutions[5] = [.conversionRequired]
    conversionStatuses = [.queued, .converting(progress: 0.5), .completed]
    let queue = makeQueue()
    queue.enqueue(
      fileID: PutioFileID(rawValue: 5), parentID: .root, name: "c", kind: .video,
      audioLanguages: ["tr", "en"])
    await settle()
    XCTAssertEqual(conversionStarts, 1)
    XCTAssertEqual(queue.items.count, 1)
    XCTAssertEqual(engine.started.first?.1, ["tr", "en"])
    XCTAssertEqual(queue.item(for: PutioFileID(rawValue: 5))?.stage, .downloading(progress: 0))
    XCTAssertEqual(queue.item(for: PutioFileID(rawValue: 5))?.selectedAudioLanguages, ["tr", "en"])
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

  func testPauseResumeCancelAndStorageFailure() async {
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

    engine.finish(PutioFileID(rawValue: 1), at: directory)
    await settle()
    let stored = queue.storedBytes
    XCTAssertGreaterThan(stored, 0)
    let path = try! XCTUnwrap(queue.item(for: PutioFileID(rawValue: 1))?.localPath)
    queue.remove(fileIDs: [PutioFileID(rawValue: 1)])
    XCTAssertEqual(queue.storedBytes, 0)
    XCTAssertTrue(queue.items.isEmpty)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: PutioOfflineQueue.localURL(for: path).path))

    let full = makeQueue(availableBytes: 1)
    full.enqueue(fileID: PutioFileID(rawValue: 9), parentID: .root, name: "z", kind: .audio)
    await settle()
    XCTAssertEqual(full.item(for: PutioFileID(rawValue: 9))?.stage, .failed(.storage))
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
    resolutions[2] = []
    let notFound = makeQueue()
    notFound.enqueue(fileID: PutioFileID(rawValue: 2), parentID: .root, name: "b", kind: .video)
    // The default resolver succeeds; force notFound through a fresh resolver.
    XCTAssertTrue(PutioOfflineFailure.resolving(PutioRuntimeError.notFound)?.canRetry == false)
    XCTAssertEqual(PutioOfflineFailure.resolving(PutioRuntimeError.sessionExpired), .authentication)
  }

  func testPositionsRecordLocallyAndSyncWhenReportingRecovers() async {
    let queue = makeQueue()
    queue.enqueue(fileID: PutioFileID(rawValue: 1), parentID: .root, name: "a", kind: .video)
    await settle()
    engine.finish(PutioFileID(rawValue: 1), at: directory)
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

  func testInventoryEstimateAndBudget() {
    let inventory = PutioOfflineInventory(
      videoBytes: 1_000,
      audioOptions: [
        PutioOfflineAudioOption(languageCode: "en", displayName: "English", estimatedBytes: 100),
        PutioOfflineAudioOption(languageCode: "tr", displayName: "Turkish", estimatedBytes: 200),
      ],
      subtitleTracks: [])
    XCTAssertEqual(inventory.estimatedBytes(selecting: []), 1_000)
    XCTAssertEqual(inventory.estimatedBytes(selecting: ["tr"]), 1_200)
    XCTAssertEqual(inventory.estimatedBytes(selecting: ["en", "tr"]), 1_300)
  }

  func testPreferredLanguageFallsBackPredictably() {
    let stored = [
      PutioOfflineTrack(languageCode: "en", displayName: "English"),
      PutioOfflineTrack(languageCode: "tr", displayName: "Turkish"),
    ]
    XCTAssertEqual(
      PutioOfflineLanguage.preferred(from: stored, preferredLanguages: ["tr-TR", "en-US"])?
        .languageCode, "tr")
    XCTAssertEqual(
      PutioOfflineLanguage.preferred(from: stored, preferredLanguages: ["de-DE"])?.languageCode,
      "en")
    XCTAssertNil(PutioOfflineLanguage.preferred(from: [], preferredLanguages: ["en"]))
    let single = [PutioOfflineTrack(languageCode: "und", displayName: "Default")]
    XCTAssertEqual(
      PutioOfflineLanguage.preferred(from: single, preferredLanguages: ["tr"])?.languageCode,
      "und")
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
}
