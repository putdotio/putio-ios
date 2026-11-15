import Foundation
import PutioCore
import Testing
import XCTest

@testable import Putio

@MainActor
private final class CastControllerStub: PutioCastControlling {
  var connection: PutioCastConnection = .connected(deviceName: "Living Room")
  var discovery = PutioCastDiscovery()
  var approximatePositionSeconds: Double?
  var onConnectionChanged: ((PutioCastConnection) -> Void)?
  var onDiscoveryChanged: ((PutioCastDiscovery) -> Void)?
  var onMediaStatusChanged: ((PutioCastMediaStatus?) -> Void)?
  private(set) var loads: [(media: PutioCastMedia, startSeconds: Int)] = []
  private(set) var commands: [String] = []
  var loadResults: [Result<Void, PutioCastControllerError>] = []
  var loadGate: CheckedContinuation<Void, Never>?
  var holdsLoad = false
  private(set) var completedLoads = 0
  var commandFailure: PutioCastControllerError?
  var reportsSessionEnd = true

  func startDiscovery() { commands.append("discover") }
  func connect(toDevice id: PutioCastDevice.ID) { commands.append("connect:\(id)") }

  func load(_ media: PutioCastMedia, startSeconds: Int, autoplay: Bool) async throws {
    defer { completedLoads += 1 }
    loads.append((media, startSeconds))
    if holdsLoad {
      await withCheckedContinuation { loadGate = $0 }
    }
    if !loadResults.isEmpty { try loadResults.removeFirst().get() }
  }

  func play() async throws { try send("play") }
  func pause() async throws { try send("pause") }
  func seek(toSeconds seconds: Double) async throws { try send("seek:\(Int(seconds))") }
  func stop() async throws { commands.append("stop") }

  private func send(_ command: String) throws {
    commands.append(command)
    if let commandFailure { throw commandFailure }
  }

  func releaseLoad() {
    let gate = loadGate
    loadGate = nil
    gate?.resume()
  }

  func endSession() {
    commands.append("end")
    guard reportsSessionEnd else { return }
    connection = .disconnected
    onConnectionChanged?(.disconnected)
  }

  func connect(_ connection: PutioCastConnection) {
    self.connection = connection
    onConnectionChanged?(connection)
  }

  func report(_ status: PutioCastMediaStatus?) {
    onMediaStatusChanged?(status)
  }
}

@MainActor
private final class SaveTicks {
  private var callbacks: [@MainActor @Sendable () -> Void] = []
  private(set) var intervals: [Duration] = []

  func schedule(
    _ interval: Duration, _ callback: @escaping @MainActor @Sendable () -> Void
  ) -> any PutioPositionReportSchedule {
    intervals.append(interval)
    callbacks.append(callback)
    return Tick()
  }

  func fire() {
    for callback in callbacks { callback() }
  }

  private final class Tick: PutioPositionReportSchedule {
    func invalidate() {}
  }
}

@MainActor
struct CastLifecycleTests {
  enum Ending: CaseIterable {
    case idle, missing, otherIdle, disconnect
  }

  @Test(arguments: Ending.allCases, [false, true])
  fileprivate func endingDiscardsQueuedControls(ending: Ending, loading: Bool) async throws {
    let controller = CastControllerStub()
    controller.holdsLoad = loading
    controller.reportsSessionEnd = false
    let fileID = PutioFileID(rawValue: 412)
    let media = PutioCastMedia(
      id: fileID, parentID: .root, title: "Movie",
      url: try #require(URL(string: "https://example.com/movie.m3u8")), artworkURL: nil,
      durationSeconds: 900, startFromSeconds: 0)
    let model = PutioCastModel(
      controller: controller, resolve: { _ in .ready(media) }, startConversion: { _ in },
      loadConversionStatus: { _ in .completed })
    defer {
      controller.connect(.disconnected)
      controller.releaseLoad()
    }
    model.cast(
      PutioVideoRoute(id: fileID, parentID: .root, title: "Movie"),
      saves: PutioCastPositionSaves(
        remembersPosition: false, pipeline: PutioPlaybackPositionPipeline(),
        report: { _, _ in }))
    let deadline = ContinuousClock.now + .seconds(2)
    while controller.loads.isEmpty, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    try #require(controller.loads.count == 1)
    controller.report(
      PutioCastMediaStatus(
        fileID: fileID, playerState: .playing, positionSeconds: 30, durationSeconds: 900))
    let pause = try #require(model.togglePlayback())
    let seek = try #require(model.seek(toSeconds: 45))
    switch ending {
    case .idle, .otherIdle:
      controller.report(
        PutioCastMediaStatus(
          fileID: ending == .idle ? fileID : PutioFileID(rawValue: 414),
          playerState: .idle, positionSeconds: 0, durationSeconds: 900))
    case .missing:
      controller.report(nil)
    case .disconnect:
      model.disconnect()
    }
    #expect(model.media == nil)
    #expect(model.status == nil)
    #expect(model.activity == .idle)
    #expect(!model.hasSession)
    if ending == .disconnect {
      #expect(!model.isConnected)
    } else {
      #expect(model.isConnected)
    }
    controller.releaseLoad()
    await pause.value
    await seek.value
    #expect(controller.commands == (ending == .disconnect ? ["end"] : []))
    #expect(model.media == nil)
    #expect(model.activity == .idle)
  }
}

@MainActor
final class ChromecastTests: XCTestCase {
  private var controllers: [CastControllerStub] = []

  override func tearDown() async throws {
    for controller in controllers {
      controller.connect(.disconnected)
      controller.releaseLoad()
    }
    controllers = []
  }

  private let route = PutioVideoRoute(
    id: PutioFileID(rawValue: 412), parentID: .root, title: "Movie.mkv")

  private func media(id: Int = 412, start: Int = 589) -> PutioCastMedia {
    PutioCastMedia(
      id: PutioFileID(rawValue: id), parentID: .root, title: "Movie.mkv",
      url: URL(string: "https://api.put.io/v2/files/\(id)/hls/media.m3u8?oauth_token=secret")!,
      artworkURL: nil, durationSeconds: 5400, startFromSeconds: start)
  }

  private func status(
    id: Int = 412, _ state: PutioCastPlayerState, position: Double = 600
  ) -> PutioCastMediaStatus {
    PutioCastMediaStatus(
      fileID: PutioFileID(rawValue: id), playerState: state, positionSeconds: position,
      durationSeconds: 5400)
  }

  private func makeModel(
    controller: CastControllerStub,
    resolutions: [Result<PutioCastResolution, PutioRuntimeError>],
    conversionStatuses: [PutioVideoConversionStatus] = []
  ) -> (PutioCastModel, Box) {
    controllers.append(controller)
    let box = Box(resolutions: resolutions, conversionStatuses: conversionStatuses)
    let ticks = box.ticks
    let model = PutioCastModel(
      controller: controller,
      conversionPollInterval: .milliseconds(5),
      resolve: { id in
        box.resolveRequests.append(id)
        guard !box.resolutions.isEmpty else { throw PutioRuntimeError.unknown }
        return try box.resolutions.removeFirst().get()
      },
      startConversion: { _ in box.conversionStarts += 1 },
      loadConversionStatus: { _ in
        guard !box.conversionStatuses.isEmpty else { return .completed }
        return box.conversionStatuses.removeFirst()
      },
      schedulePositionSaves: { ticks.schedule($0, $1) })
    return (model, box)
  }

  @MainActor
  final class Box {
    var resolutions: [Result<PutioCastResolution, PutioRuntimeError>]
    var conversionStatuses: [PutioVideoConversionStatus]
    var resolveRequests: [PutioFileID] = []
    var conversionStarts = 0
    var reports: [(PutioFileID, Int)] = []
    var remembersPosition = true
    let pipeline = PutioPlaybackPositionPipeline()
    fileprivate let ticks = SaveTicks()

    init(
      resolutions: [Result<PutioCastResolution, PutioRuntimeError>],
      conversionStatuses: [PutioVideoConversionStatus]
    ) {
      self.resolutions = resolutions
      self.conversionStatuses = conversionStatuses
    }

    var saves: PutioCastPositionSaves {
      PutioCastPositionSaves(
        remembersPosition: remembersPosition, pipeline: pipeline,
        report: { [weak self] id, seconds in self?.reports.append((id, seconds)) })
    }
  }

  /// XCTAssert autoclosures cannot await, so waits assert through this helper.
  private func expect(
    _ condition: @escaping @MainActor () -> Bool, _ message: String = "",
    file: StaticString = #filePath, line: UInt = #line
  ) async throws {
    let met = try await waitUntil(condition)
    XCTAssertTrue(met, message, file: file, line: line)
    guard met else { throw WaitTimeout() }
  }

  private struct WaitTimeout: Error {}

  private func waitUntil(
    _ condition: @escaping @MainActor () -> Bool, timeout: Duration = .seconds(2)
  )
    async throws -> Bool
  {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if condition() { return true }
      try await Task.sleep(for: .milliseconds(5))
    }
    return condition()
  }

  private func castPlaying(
    _ model: PutioCastModel, _ controller: CastControllerStub, _ box: Box,
    position: Double = 600
  ) async throws {
    model.cast(route, saves: box.saves)
    try await expect({ model.media != nil && model.activity == .idle })
    controller.report(status(.playing, position: position))
  }

  func testCastLoadsTheHLSStreamFromTheSavedPositionThroughLoadingToPlaying() async throws {
    let controller = CastControllerStub()
    let expected = media()
    let (model, box) = makeModel(controller: controller, resolutions: [.success(.ready(expected))])
    XCTAssertTrue(model.isConnected)
    XCTAssertNil(model.phase)
    model.cast(route, saves: box.saves)
    XCTAssertEqual(model.castingRoute, route)
    XCTAssertEqual(model.phase, .loading)
    try await expect({ model.activity == .idle && model.media != nil })
    XCTAssertEqual(box.resolveRequests, [route.id])
    XCTAssertEqual(controller.loads.count, 1)
    XCTAssertEqual(controller.loads.first?.media.url.path, "/v2/files/412/hls/media.m3u8")
    XCTAssertEqual(controller.loads.first?.startSeconds, 589)
    XCTAssertEqual(model.phase, .loading, "loaded but not yet reported by the receiver")
    controller.report(status(.loading))
    XCTAssertEqual(model.phase, .loading, "the receiver is still loading the stream")
    controller.report(status(.playing))
    XCTAssertEqual(model.phase, .playing)
    XCTAssertTrue(model.isPlaying)
  }

  func testCastWaitsForThePhonesPendingSaveBeforeResolving() async throws {
    let controller = CastControllerStub()
    let (model, box) = makeModel(controller: controller, resolutions: [.success(.ready(media()))])
    let save = PendingSave()
    box.pipeline.enqueue(fileID: route.id, position: 120) { _, _ in
      await withCheckedContinuation { save.continuation = $0 }
    }
    model.cast(route, saves: box.saves)
    try await expect({ save.continuation != nil })
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertTrue(box.resolveRequests.isEmpty, "resolved before the local save landed")
    save.continuation?.resume()
    try await expect({ box.resolveRequests == [self.route.id] })
  }

  @MainActor
  private final class PendingSave {
    var continuation: CheckedContinuation<Void, Never>?
  }

  func testConversionGateConvertsThenReResolvesAndFailureIsRetryable() async throws {
    let controller = CastControllerStub()
    let expected = media()
    let (model, box) = makeModel(
      controller: controller,
      resolutions: [.success(.conversionRequired), .success(.ready(expected))],
      conversionStatuses: [.queued, .converting(progress: 0.5), .completed])
    model.cast(route, saves: box.saves)
    try await expect({ model.media == expected })
    XCTAssertEqual(box.conversionStarts, 1)
    XCTAssertEqual(box.resolveRequests.count, 2)
    XCTAssertEqual(controller.loads.count, 1)

    let failing = CastControllerStub()
    let (failed, failedBox) = makeModel(
      controller: failing,
      resolutions: [
        .success(.conversionRequired), .success(.conversionRequired), .success(.ready(expected)),
      ],
      conversionStatuses: [.failed])
    failed.cast(route, saves: failedBox.saves)
    try await expect({ failed.phase == .failed(canRetry: true) })
    XCTAssertNil(failed.media)
    XCTAssertTrue(failing.loads.isEmpty)
    failedBox.conversionStatuses = [.completed]
    failed.retry()
    try await expect({ failed.media == expected })
    XCTAssertEqual(failedBox.conversionStarts, 2)
  }

  func testReceiverLoadFailureShowsTheFailedLayoutAndTryAgainLoads() async throws {
    let controller = CastControllerStub()
    controller.loadResults = [.failure(PutioCastControllerError(failure: .receiver)), .success(())]
    let expected = media()
    let (model, box) = makeModel(
      controller: controller, resolutions: [.success(.ready(expected)), .success(.ready(expected))])
    model.cast(route, saves: box.saves)
    try await expect({ model.phase == .failed(canRetry: true) })
    XCTAssertNil(model.media)
    XCTAssertEqual(model.castingRoute, route, "the failed layout stays on the casting route")
    model.retry()
    XCTAssertEqual(model.phase, .loading)
    try await expect({ model.media == expected && model.activity == .idle })
    XCTAssertEqual(controller.loads.count, 2)

    let notFound = CastControllerStub()
    let (missing, missingBox) = makeModel(controller: notFound, resolutions: [.failure(.notFound)])
    missing.cast(route, saves: missingBox.saves)
    try await expect({ missing.phase == .failed(canRetry: false) })

    let expired = CastControllerStub()
    let (signedOut, expiredBox) = makeModel(
      controller: expired, resolutions: [.failure(.sessionExpired)])
    signedOut.cast(route, saves: expiredBox.saves)
    try await expect({ signedOut.activity == .idle && !signedOut.hasSession })
  }

  func testNewerCastWinsOverAStaleLoadAndSessionEndClearsEverything() async throws {
    let controller = CastControllerStub()
    controller.holdsLoad = true
    let first = media(id: 412)
    let second = media(id: 414)
    let (model, box) = makeModel(
      controller: controller, resolutions: [.success(.ready(first)), .success(.ready(second))])
    model.cast(route, saves: box.saves)
    try await expect({ controller.loads.count == 1 })
    controller.holdsLoad = false
    model.cast(
      PutioVideoRoute(id: PutioFileID(rawValue: 414), parentID: .root, title: "Next"),
      saves: box.saves)
    try await expect({ controller.loads.count == 2 })
    controller.releaseLoad()
    try await expect({ controller.completedLoads == 2 && model.media == second })
    XCTAssertEqual(model.media, second, "the stale load must not overwrite the newer cast")
    controller.report(status(id: 414, .playing))
    XCTAssertEqual(model.status?.fileID, PutioFileID(rawValue: 414))
    controller.report(status(id: 412, .playing))
    XCTAssertEqual(
      model.status?.fileID, PutioFileID(rawValue: 414), "another file's status is ignored")

    controller.connect(.disconnected)
    XCTAssertNil(model.media)
    XCTAssertNil(model.status)
    XCTAssertEqual(model.activity, .idle)
    XCTAssertFalse(model.hasSession)
    XCTAssertTrue(model.showsCastButton)
    controller.connect(.unavailable)
    XCTAssertFalse(model.showsCastButton)
    model.cast(route, saves: box.saves)
    XCTAssertEqual(model.activity, .idle, "casting while disconnected is a no-op")
  }

  func testCastButtonExplainsLocalNetworkInsteadOfOpeningThePicker() {
    let controller = CastControllerStub()
    controller.connection = .disconnected
    let (model, _) = makeModel(controller: controller, resolutions: [])
    model.castButtonTapped()
    XCTAssertTrue(model.presentsPicker)
    XCTAssertEqual(controller.commands, ["discover"])
    XCTAssertFalse(model.presentsLocalNetworkAlert)
    model.presentsPicker = false

    controller.connect(.localNetworkDenied)
    XCTAssertTrue(model.showsCastButton, "Local Network off hid the Cast button")
    model.castButtonTapped()
    XCTAssertFalse(model.presentsPicker, "Local Network off opened the picker")
    XCTAssertEqual(controller.commands, ["discover"], "Local Network off searched anyway")
    XCTAssertTrue(model.presentsLocalNetworkAlert)

    controller.connect(.unavailable)
    XCTAssertFalse(model.showsCastButton)
  }

  func testPickerListsDiscoveryAndChoosingADeviceClosesItAndConnects() {
    let controller = CastControllerStub()
    controller.connection = .disconnected
    let (model, _) = makeModel(controller: controller, resolutions: [])
    let tv = PutioCastDevice(
      id: "tv", name: "Living Room TV", model: "Chromecast with Google TV", kind: .tv,
      audioOnly: false, isSelected: false)
    let speaker = PutioCastDevice(
      id: "speaker", name: "Kitchen speaker", model: nil, kind: .speaker, audioOnly: true,
      isSelected: true)
    let found = PutioCastDiscovery(devices: [tv, speaker], isSearching: true)
    controller.onDiscoveryChanged?(found)
    XCTAssertEqual(model.discovery, found)

    model.castButtonTapped()
    model.choose(tv)
    XCTAssertFalse(model.presentsPicker, "choosing a device kept the picker open")
    XCTAssertEqual(controller.commands, ["discover", "connect:tv"])

    model.castButtonTapped()
    model.choose(speaker)
    XCTAssertFalse(model.presentsPicker)
    XCTAssertEqual(
      controller.commands, ["discover", "connect:tv", "discover"],
      "choosing the connected device reconnected it")
  }

  func testTransportSkipsTenSecondsAndClampsToTheMedia() async throws {
    let controller = CastControllerStub()
    let (model, box) = makeModel(controller: controller, resolutions: [.success(.ready(media()))])
    model.togglePlayback()
    model.skip(by: 10)
    model.cast(route, saves: box.saves)
    try await expect({ model.media != nil })
    XCTAssertTrue(controller.commands.isEmpty, "controls need a receiver status")
    controller.report(status(.playing, position: 600))
    model.togglePlayback()
    try await expect({ controller.commands == ["pause"] })
    controller.report(status(.paused, position: 600))
    model.togglePlayback()
    try await expect({ controller.commands.last == "play" })
    controller.approximatePositionSeconds = 604
    model.skip(by: PutioVideoTimeline.skipInterval)
    try await expect({ controller.commands.last == "seek:614" })
    model.skip(by: -PutioVideoTimeline.skipInterval)
    try await expect({ controller.commands.last == "seek:594" })
    model.seek(toSeconds: -5)
    try await expect({ controller.commands.last == "seek:0" })
    model.seek(toSeconds: 9_000)
    try await expect({ controller.commands.last == "seek:5400" })
  }

  func testStopHandsBackTheReceiverPositionAndKeepsTheDevice() async throws {
    let controller = CastControllerStub()
    let (model, box) = makeModel(controller: controller, resolutions: [.success(.ready(media()))])
    try await castPlaying(model, controller, box, position: 700)
    controller.approximatePositionSeconds = 702.6
    model.stopCasting()
    XCTAssertEqual(model.handback, PutioCastHandback(route: route, seconds: 702))
    XCTAssertNil(model.castingRoute)
    XCTAssertTrue(model.isConnected)
    try await expect({ controller.commands.last == "stop" })
    try await expect({ box.reports.map(\.1) == [702] }, "stop saves the receiver's position")
    model.clearHandback()
    XCTAssertNil(model.handback)
  }

  func testStopFromTheFailedLayoutHandsBackWithoutAPosition() async throws {
    let controller = CastControllerStub()
    controller.loadResults = [.failure(PutioCastControllerError(failure: .receiver))]
    let (model, box) = makeModel(controller: controller, resolutions: [.success(.ready(media()))])
    model.cast(route, saves: box.saves)
    try await expect({ model.phase == .failed(canRetry: true) })
    model.stopCasting()
    XCTAssertEqual(model.handback, PutioCastHandback(route: route, seconds: nil))
    XCTAssertFalse(controller.commands.contains("stop"), "nothing was loaded to stop")
  }

  func testLosingTheConnectionHandsBackAndDisconnectEndsTheSession() async throws {
    let controller = CastControllerStub()
    let (model, box) = makeModel(
      controller: controller, resolutions: [.success(.ready(media())), .success(.ready(media()))])
    try await castPlaying(model, controller, box, position: 650)
    controller.connect(.disconnected)
    XCTAssertEqual(model.handback?.seconds, 650)

    controller.connect(.connected(deviceName: "Living Room"))
    try await castPlaying(model, controller, box, position: 660)
    XCTAssertNil(model.handback, "a new cast clears the old hand-back")
    model.disconnect()
    XCTAssertEqual(model.handback?.seconds, 660)
    XCTAssertEqual(controller.commands.last, "end")
  }

  func testQueuedControlsAreDiscardedWhenAnotherCastStarts() async throws {
    let controller = CastControllerStub()
    let first = media()
    let second = media(id: 414)
    let (model, box) = makeModel(
      controller: controller, resolutions: [.success(.ready(first)), .success(.ready(second))])
    model.cast(route, saves: box.saves)
    try await expect({ model.media == first && model.activity == .idle })

    controller.report(status(.playing))
    let pause = try XCTUnwrap(model.togglePlayback())
    controller.report(status(.paused))
    let play = try XCTUnwrap(model.togglePlayback())
    let seek = try XCTUnwrap(model.seek(toSeconds: 30))
    // No suspension before replacement: every control still belongs to the old cast.
    model.cast(PutioVideoRoute(id: second.id, parentID: .root, title: "Next"), saves: box.saves)

    await pause.value
    await play.value
    await seek.value
    XCTAssertTrue(controller.commands.isEmpty, "queued controls must not reach the next cast")

    try await expect({ model.media == second && model.activity == .idle })
    controller.report(status(id: 414, .playing))
    await model.togglePlayback()?.value
    controller.report(status(id: 414, .paused))
    await model.togglePlayback()?.value
    await model.seek(toSeconds: 45)?.value
    XCTAssertEqual(controller.commands, ["pause", "play", "seek:45"])
  }

  func testControlFailureShowsTheFailedLayoutAndReceiverStatusRecovers() async throws {
    let controller = CastControllerStub()
    let expected = media()
    let (model, box) = makeModel(controller: controller, resolutions: [.success(.ready(expected))])
    model.cast(route, saves: box.saves)
    try await expect({ model.media == expected })

    let actions: [(String, () -> Void)] = [
      ("pause", { model.togglePlayback() }),
      ("seek:30", { model.seek(toSeconds: 30) }),
    ]
    for (command, action) in actions {
      controller.report(status(.playing))
      controller.commandFailure = PutioCastControllerError(failure: .receiver)
      action()
      try await expect(
        { model.phase == .failed(canRetry: true) && controller.commands.last == command },
        command)
      XCTAssertEqual(model.media, expected)
      XCTAssertTrue(model.isConnected)

      controller.commandFailure = nil
      controller.report(status(.paused))
      XCTAssertEqual(model.phase, .playing)
      model.togglePlayback()
      try await expect({ controller.commands.last == "play" })
    }
  }

  func testReceiverPositionSavesEveryTenSecondsAndOnPauseAndSeek() async throws {
    let controller = CastControllerStub()
    let (model, box) = makeModel(controller: controller, resolutions: [.success(.ready(media()))])
    try await castPlaying(model, controller, box, position: 589.9)
    XCTAssertEqual(box.ticks.intervals, [PutioVideoPositionReporter.interval])
    XCTAssertEqual(PutioVideoPositionReporter.interval, .seconds(10))
    box.ticks.fire()
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertTrue(box.reports.isEmpty, "the start position is not saved again")

    controller.report(status(.playing, position: 599.4))
    box.ticks.fire()
    try await expect({ box.reports.map(\.1) == [599] })
    XCTAssertEqual(model.reportedPosition?.seconds, 599)
    box.ticks.fire()
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertEqual(box.reports.count, 1, "an unchanged position is not repeated")

    controller.report(status(.paused, position: 604))
    try await expect({ box.reports.map(\.1) == [599, 604] }, "pause saves at once")

    controller.approximatePositionSeconds = 640
    await model.seek(toSeconds: 640)?.value
    try await expect({ box.reports.map(\.1) == [599, 604, 640] }, "seek saves at once")
  }

  func testPlayingToTheEndSavesTheEndForTheWatchedMark() async throws {
    let controller = CastControllerStub()
    let (model, box) = makeModel(controller: controller, resolutions: [.success(.ready(media()))])
    try await castPlaying(model, controller, box, position: 5_399.5)
    controller.report(status(.idle, position: 0))
    try await expect({ box.reports.map(\.1) == [5_399] })
    XCTAssertTrue(
      PutioPlaybackProgress.isWatched(positionSeconds: 5_399, durationSeconds: 5_400))
    XCTAssertFalse(model.hasSession)
    XCTAssertNil(model.handback, "an ended video is not handed back")
  }

  func testAnAccountThatForgetsPositionsSavesNothing() async throws {
    let controller = CastControllerStub()
    let (model, box) = makeModel(controller: controller, resolutions: [.success(.ready(media()))])
    box.remembersPosition = false
    try await castPlaying(model, controller, box, position: 601)
    box.ticks.fire()
    controller.report(status(.paused, position: 700))
    model.stopCasting()
    try await Task.sleep(for: .milliseconds(40))
    XCTAssertTrue(box.reports.isEmpty)
    XCTAssertNil(model.reportedPosition)
    XCTAssertEqual(model.handback?.seconds, 700, "the phone still continues from the receiver")
  }

  func testReceiverIDComesFromTheBundleWithAPublicFallback() {
    XCTAssertEqual(PutioCastReceiver.appID(bundle: Bundle(for: ChromecastTests.self)), "CC1AD845")
    XCTAssertEqual(PutioCastReceiver.appID(bundle: .main), "CC1AD845")
    XCTAssertTrue(PutioCastReceiver.isValid("ABCD1234"))
    for bad in ["$(PUTIO_CHROMECAST_RECEIVER_APP_ID)", "abcd1234", "ABCD123", "ABCD123G", ""] {
      XCTAssertFalse(PutioCastReceiver.isValid(bad), bad)
    }
  }
}
