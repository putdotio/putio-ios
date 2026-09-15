import Foundation
import PutioCore
import XCTest

@testable import Putio

@MainActor
private final class CastControllerStub: PutioCastControlling {
  var connection: PutioCastConnection = .connected(deviceName: "Living Room")
  var onConnectionChanged: ((PutioCastConnection) -> Void)?
  var onMediaStatusChanged: ((PutioCastMediaStatus?) -> Void)?
  var providesSystemCastButton = false
  private(set) var loads: [(PutioCastMedia, String?)] = []
  private(set) var commands: [String] = []
  var loadResults: [Result<Void, PutioCastControllerError>] = []
  var loadGate: CheckedContinuation<Void, Never>?
  var holdsLoad = false
  private(set) var completedLoads = 0
  var commandFailure: PutioCastControllerError?

  func presentDevicePicker() { commands.append("picker") }

  func load(_ media: PutioCastMedia, subtitleKey: String?) async throws {
    defer { completedLoads += 1 }
    loads.append((media, subtitleKey))
    if holdsLoad {
      await withCheckedContinuation { loadGate = $0 }
    }
    if !loadResults.isEmpty { try loadResults.removeFirst().get() }
  }

  func play() async throws { try send("play") }
  func pause() async throws { try send("pause") }
  func seek(toSeconds seconds: Double) async throws { try send("seek:\(Int(seconds))") }
  func setSubtitle(key: String?) async throws { try send("subtitle:\(key ?? "off")") }
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

  private func media(id: Int = 412, subtitles: [PutioCastSubtitle] = [], defaultKey: String? = nil)
    -> PutioCastMedia
  {
    PutioCastMedia(
      id: PutioFileID(rawValue: id), parentID: .root, title: "Movie.mkv", playbackType: .mp4,
      url: URL(string: "https://api.put.io/v2/files/\(id)/mp4/download?oauth_token=secret")!,
      artworkURL: nil, durationSeconds: 5400, startFromSeconds: 589, subtitles: subtitles,
      defaultSubtitleKey: defaultKey)
  }

  private func subtitle(_ key: String) -> PutioCastSubtitle {
    PutioCastSubtitle(
      key: key, language: key, languageCode: key, name: "\(key).srt",
      url: URL(string: "https://api.put.io/s/\(key)")!)
  }

  private func status(
    id: Int = 412, _ state: PutioCastPlayerState, position: Double = 600, subtitle: String? = nil
  ) -> PutioCastMediaStatus {
    PutioCastMediaStatus(
      fileID: PutioFileID(rawValue: id), playerState: state, positionSeconds: position,
      durationSeconds: 5400, activeSubtitleKey: subtitle)
  }

  private func makeModel(
    controller: CastControllerStub,
    resolutions: [Result<PutioCastResolution, PutioRuntimeError>],
    playbackType: Result<PutioCastPlaybackType, PutioRuntimeError> = .success(.mp4),
    conversionStatuses: [PutioVideoConversionStatus] = [],
    reportInterval: Duration = .milliseconds(40)
  ) -> (PutioCastModel, Box) {
    controllers.append(controller)
    let box = Box(resolutions: resolutions, conversionStatuses: conversionStatuses)
    let model = PutioCastModel(
      controller: controller, positionReportInterval: reportInterval,
      conversionPollInterval: .milliseconds(5),
      resolve: { id, type in
        box.resolveRequests.append((id, type))
        guard !box.resolutions.isEmpty else { throw PutioRuntimeError.unknown }
        return try box.resolutions.removeFirst().get()
      },
      loadPlaybackType: {
        box.playbackTypeLoads += 1
        if let load = box.loadPlaybackType { return try await load() }
        return try playbackType.get()
      },
      savePlaybackType: { type in
        box.savedTypes.append(type)
        if let failure = box.saveFailure {
          box.saveFailure = nil
          throw failure
        }
      },
      startConversion: { _ in box.conversionStarts += 1 },
      loadConversionStatus: { _ in
        guard !box.conversionStatuses.isEmpty else { return .completed }
        return box.conversionStatuses.removeFirst()
      },
      reportPosition: { id, seconds in box.reports.append((id, seconds)) })
    return (model, box)
  }

  @MainActor
  final class Box {
    var resolutions: [Result<PutioCastResolution, PutioRuntimeError>]
    var conversionStatuses: [PutioVideoConversionStatus]
    var resolveRequests: [(PutioFileID, PutioCastPlaybackType)] = []
    var playbackTypeLoads = 0
    var loadPlaybackType: PutioCastPlaybackTypeLoad?
    var savedTypes: [PutioCastPlaybackType] = []
    var saveFailure: PutioRuntimeError?
    var conversionStarts = 0
    var reports: [(PutioFileID, Int)] = []

    init(
      resolutions: [Result<PutioCastResolution, PutioRuntimeError>],
      conversionStatuses: [PutioVideoConversionStatus]
    ) {
      self.resolutions = resolutions
      self.conversionStatuses = conversionStatuses
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

  func testCastLoadsWithDefaultSubtitleAndPresentsControls() async throws {
    let controller = CastControllerStub()
    let expected = media(subtitles: [subtitle("en"), subtitle("tr")], defaultKey: "tr")
    let (model, box) = makeModel(controller: controller, resolutions: [.success(.ready(expected))])
    XCTAssertTrue(model.isConnected)
    XCTAssertFalse(model.hasSession)
    model.cast(route)
    XCTAssertTrue(model.presentsControls)
    XCTAssertEqual(model.activity, .resolving(route.id))
    try await expect({ model.activity == .idle && model.media != nil })
    XCTAssertEqual(box.resolveRequests.map(\.1), [.mp4])
    XCTAssertEqual(box.playbackTypeLoads, 1)
    XCTAssertEqual(controller.loads.count, 1)
    XCTAssertEqual(controller.loads.first?.1, "tr")
    XCTAssertEqual(model.media, expected)
    XCTAssertTrue(model.hasSession)
    controller.report(status(.playing, subtitle: "tr"))
    XCTAssertTrue(model.isPlaying)
    XCTAssertEqual(model.status?.activeSubtitleKey, "tr")
  }

  func testConversionGateConvertsThenReResolvesAndFailureIsRetryable() async throws {
    let controller = CastControllerStub()
    let expected = media()
    let (model, box) = makeModel(
      controller: controller,
      resolutions: [.success(.conversionRequired), .success(.ready(expected))],
      conversionStatuses: [.queued, .converting(progress: 0.5), .completed])
    model.cast(route)
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
    failed.cast(route)
    try await expect({
      if case .failed(_, let failure) = failed.activity { return failure.kind == .conversion }
      return false
    })
    XCTAssertNil(failed.media)
    XCTAssertTrue(failing.loads.isEmpty)
    failedBox.conversionStatuses = [.completed]
    failed.retry()
    try await expect({ failed.media == expected })
    XCTAssertEqual(failedBox.conversionStarts, 2)
  }

  func testReceiverLoadFailureIsRetryableAndRuntimeErrorsMap() async throws {
    let controller = CastControllerStub()
    controller.loadResults = [.failure(PutioCastControllerError(failure: .receiver)), .success(())]
    let expected = media()
    let (model, _) = makeModel(
      controller: controller, resolutions: [.success(.ready(expected)), .success(.ready(expected))])
    model.cast(route)
    try await expect({
      if case .failed(let id, let failure) = model.activity {
        return id == self.route.id && failure.kind == .receiver
      }
      return false
    })
    XCTAssertNil(model.media)
    XCTAssertTrue(model.presentsControls)
    model.retry()
    try await expect({ model.media == expected && model.activity == .idle })
    XCTAssertEqual(controller.loads.count, 2)

    let notFound = CastControllerStub()
    let (missing, _) = makeModel(controller: notFound, resolutions: [.failure(.notFound)])
    missing.cast(route)
    try await expect({
      if case .failed(_, let failure) = missing.activity {
        return failure.kind == .notFound && !failure.canRetry
      }
      return false
    })

    let expired = CastControllerStub()
    let (signedOut, _) = makeModel(controller: expired, resolutions: [.failure(.sessionExpired)])
    signedOut.cast(route)
    try await expect({ signedOut.activity == .idle && !signedOut.presentsControls })
  }

  func testNewerCastWinsOverAStaleLoadAndSessionEndClearsEverything() async throws {
    let controller = CastControllerStub()
    controller.holdsLoad = true
    let first = media(id: 412)
    let second = media(id: 414)
    let (model, _) = makeModel(
      controller: controller, resolutions: [.success(.ready(first)), .success(.ready(second))])
    model.cast(route)
    try await expect({ controller.loads.count == 1 })
    controller.holdsLoad = false
    model.cast(PutioVideoRoute(id: PutioFileID(rawValue: 414), parentID: .root, title: "Next"))
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
    XCTAssertFalse(model.presentsControls)
    XCTAssertFalse(model.hasSession)
    XCTAssertTrue(model.showsCastButton)
    controller.connect(.unavailable)
    XCTAssertFalse(model.showsCastButton)
    model.cast(route)
    XCTAssertEqual(model.activity, .idle, "casting while disconnected is a no-op")
  }

  func testControlsForwardToTheReceiverAndStopClearsWithoutDisconnecting() async throws {
    let controller = CastControllerStub()
    let expected = media(subtitles: [subtitle("en")], defaultKey: "en")
    let (model, _) = makeModel(controller: controller, resolutions: [.success(.ready(expected))])
    model.togglePlayback()
    model.seek(toSeconds: 10)
    model.cast(route)
    try await expect({ model.media != nil })
    XCTAssertTrue(controller.commands.isEmpty, "controls need loaded media")
    controller.report(status(.playing))
    model.togglePlayback()
    try await expect({ controller.commands == ["pause"] })
    controller.report(status(.paused))
    model.togglePlayback()
    try await expect({ controller.commands.last == "play" })
    model.seek(toSeconds: -5)
    try await expect({ controller.commands.last == "seek:0" })
    model.selectSubtitle(key: "nope")
    model.selectSubtitle(key: "en")
    try await expect({ controller.commands.last == "subtitle:en" })
    model.selectSubtitle(key: nil)
    try await expect({ controller.commands.last == "subtitle:off" })
    XCTAssertEqual(controller.commands, ["pause", "play", "seek:0", "subtitle:en", "subtitle:off"])
    model.stopCasting()
    try await expect({ controller.commands.last == "stop" })
    XCTAssertEqual(controller.commands.last, "stop")
    XCTAssertNil(model.media)
    XCTAssertFalse(model.presentsControls)
    XCTAssertTrue(model.isConnected)
    controller.report(nil)
    XCTAssertNil(model.status)
  }

  func testQueuedControlsAreDiscardedWhenAnotherCastStarts() async throws {
    let controller = CastControllerStub()
    let first = media(subtitles: [subtitle("en")])
    let second = media(id: 414, subtitles: [subtitle("tr")])
    let (model, _) = makeModel(
      controller: controller, resolutions: [.success(.ready(first)), .success(.ready(second))])
    model.cast(route)
    try await expect({ model.media == first && model.activity == .idle })

    controller.report(status(.playing))
    let pause = try XCTUnwrap(model.togglePlayback())
    controller.report(status(.paused))
    let play = try XCTUnwrap(model.togglePlayback())
    let seek = try XCTUnwrap(model.seek(toSeconds: 30))
    let subtitles = try XCTUnwrap(model.selectSubtitle(key: "en"))
    let subtitlesOff = try XCTUnwrap(model.selectSubtitle(key: nil))
    // No suspension before replacement: every control still belongs to the old cast.
    model.cast(PutioVideoRoute(id: second.id, parentID: .root, title: "Next"))

    await pause.value
    await play.value
    await seek.value
    await subtitles.value
    await subtitlesOff.value
    XCTAssertTrue(controller.commands.isEmpty, "queued controls must not reach the next cast")

    try await expect({ model.media == second && model.activity == .idle })
    controller.report(status(id: 414, .playing))
    await model.togglePlayback()?.value
    controller.report(status(id: 414, .paused))
    await model.togglePlayback()?.value
    await model.seek(toSeconds: 45)?.value
    await model.selectSubtitle(key: "tr")?.value
    await model.selectSubtitle(key: nil)?.value
    XCTAssertEqual(
      controller.commands, ["pause", "play", "seek:45", "subtitle:tr", "subtitle:off"])
  }

  func testQueuedControlsAreDiscardedWhenTheReceiverDisconnects() async throws {
    let controller = CastControllerStub()
    let expected = media(subtitles: [subtitle("en")])
    let (model, _) = makeModel(controller: controller, resolutions: [.success(.ready(expected))])
    model.cast(route)
    try await expect({ model.media == expected && model.activity == .idle })

    controller.report(status(.playing))
    let pause = try XCTUnwrap(model.togglePlayback())
    let seek = try XCTUnwrap(model.seek(toSeconds: 30))
    let subtitles = try XCTUnwrap(model.selectSubtitle(key: "en"))
    controller.connect(.disconnected)

    await pause.value
    await seek.value
    await subtitles.value
    XCTAssertTrue(controller.commands.isEmpty, "queued controls must not reach an ended session")
    XCTAssertFalse(model.hasSession)
  }

  func testControlFailurePreservesMediaAndReceiverStatusRecoversTheControls() async throws {
    let controller = CastControllerStub()
    let expected = media(subtitles: [subtitle("en")])
    let (model, _) = makeModel(controller: controller, resolutions: [.success(.ready(expected))])
    model.cast(route)
    try await expect({ model.media == expected })

    let actions: [(String, () -> Void)] = [
      ("pause", { model.togglePlayback() }),
      ("seek:30", { model.seek(toSeconds: 30) }),
      ("subtitle:en", { model.selectSubtitle(key: "en") }),
    ]
    for (command, action) in actions {
      controller.report(status(.playing))
      controller.commandFailure = PutioCastControllerError(failure: .receiver)
      action()
      try await expect(
        {
          model.activity == .failed(self.route.id, .receiver)
            && controller.commands.last == command
        }, command)
      XCTAssertEqual(model.media, expected)
      XCTAssertTrue(model.presentsControls)
      XCTAssertTrue(model.isConnected)

      controller.commandFailure = nil
      controller.report(status(.paused))
      XCTAssertEqual(model.activity, .idle)
      model.togglePlayback()
      try await expect({ controller.commands.last == "play" })
    }
  }

  func testPositionReportsAreThrottledDistinctAndFlushedOnStop() async throws {
    let controller = CastControllerStub()
    let expected = media()
    let (model, box) = makeModel(
      controller: controller, resolutions: [.success(.ready(expected))],
      reportInterval: .milliseconds(30))
    model.cast(route)
    try await expect({ model.media != nil })
    controller.report(status(.playing, position: 589.9))
    try await Task.sleep(for: .milliseconds(80))
    XCTAssertTrue(box.reports.isEmpty, "the start position is not re-reported")
    controller.report(status(.playing, position: 601.4))
    try await expect({ box.reports.count == 1 })
    XCTAssertEqual(box.reports.first?.1, 601)
    XCTAssertEqual(model.reportedPosition?.seconds, 601)
    try await Task.sleep(for: .milliseconds(80))
    XCTAssertEqual(box.reports.count, 1, "an unchanged position is not repeated")
    controller.report(status(.buffering, position: 650))
    try await Task.sleep(for: .milliseconds(80))
    XCTAssertEqual(box.reports.count, 1, "buffering positions are not trusted")
    controller.report(status(.paused, position: 700))
    model.stopCasting()
    try await expect({ box.reports.count == 2 })
    XCTAssertEqual(box.reports.map(\.1), [601, 700], "stop flushes the last paused position")
    try await Task.sleep(for: .milliseconds(80))
    XCTAssertEqual(box.reports.count, 2, "reporting stops with the session")
  }

  func testReceiverIdleEndsTheSessionSurfaceAndAnotherSendersMediaIsIgnored() async throws {
    let controller = CastControllerStub()
    let expected = media()
    let (model, box) = makeModel(controller: controller, resolutions: [.success(.ready(expected))])
    model.cast(route)
    try await expect({ model.media != nil })
    controller.report(status(.playing, position: 700))
    controller.report(status(.idle, position: 900))
    try await expect({ box.reports.count == 1 })
    XCTAssertNil(model.media)
    XCTAssertFalse(model.presentsControls)
    XCTAssertEqual(box.reports.map(\.1), [700], "the last playing position is flushed, not idle's")
    XCTAssertTrue(model.isConnected)
  }

  func testPlaybackTypeSavesOnlyFlipOnAcknowledgement() async throws {
    let controller = CastControllerStub()
    let (model, box) = makeModel(controller: controller, resolutions: [])
    await model.loadPlaybackTypeIfNeeded()
    XCTAssertEqual(model.playbackType, .mp4)
    box.saveFailure = .transient
    await model.savePlaybackType(.hls)
    XCTAssertEqual(model.playbackType, .mp4)
    XCTAssertEqual(model.playbackTypeFailure, "Check your connection and try again.")
    await model.savePlaybackType(.hls)
    XCTAssertEqual(model.playbackType, .hls)
    XCTAssertNil(model.playbackTypeFailure)
    XCTAssertEqual(box.savedTypes, [.hls, .hls])
    await model.savePlaybackType(.hls)
    XCTAssertEqual(box.savedTypes.count, 2, "saving the current value is a no-op")
    model.cast(route)
    try await expect({ model.activity != .resolving(self.route.id) })
    XCTAssertEqual(box.resolveRequests.last?.1, .hls, "casting uses the saved type")
    XCTAssertEqual(box.playbackTypeLoads, 1)
  }

  func testPlaybackTypeLoadFailureIsRetryable() async throws {
    let controller = CastControllerStub()
    let (model, box) = makeModel(
      controller: controller, resolutions: [], playbackType: .failure(.rateLimited))
    await model.loadPlaybackTypeIfNeeded()
    XCTAssertNil(model.playbackType)
    XCTAssertEqual(
      model.playbackTypeFailure, "put.io is receiving too many requests. Try again shortly.")
    await model.loadPlaybackTypeIfNeeded(force: true)
    XCTAssertEqual(box.playbackTypeLoads, 2)
  }

  func testPlaybackTypeRefreshCannotOverwriteAcknowledgedSave() async throws {
    let (model, box) = makeModel(controller: CastControllerStub(), resolutions: [])
    await model.loadPlaybackTypeIfNeeded()
    var pending: CheckedContinuation<PutioCastPlaybackType, Never>?
    box.loadPlaybackType = {
      await withCheckedContinuation { pending = $0 }
    }
    let refresh = Task { await model.loadPlaybackTypeIfNeeded(force: true) }
    _ = try await waitUntil { pending != nil }
    guard let pending else {
      refresh.cancel()
      return XCTFail("preference refresh did not start")
    }

    await model.savePlaybackType(.hls)
    XCTAssertEqual(model.playbackType, .hls)
    pending.resume(returning: .mp4)
    await refresh.value

    XCTAssertEqual(model.playbackType, .hls)
    XCTAssertNil(model.playbackTypeFailure)
    XCTAssertEqual(box.savedTypes, [.hls])
  }

  func testReceiverIDComesFromTheBundleWithAPublicFallback() {
    XCTAssertEqual(PutioCastReceiver.appID(bundle: Bundle(for: ChromecastTests.self)), "CC1AD845")
    XCTAssertEqual(PutioCastReceiver.appID(bundle: .main), "CC1AD845")
    XCTAssertTrue(PutioCastReceiver.isValid("ABCD1234"))
    for bad in ["$(PUTIO_CHROMECAST_RECEIVER_APP_ID)", "abcd1234", "ABCD123", "ABCD123G", ""] {
      XCTAssertFalse(PutioCastReceiver.isValid(bad), bad)
    }
  }

  func testClockFormatting() {
    XCTAssertEqual(PutioCastControlsView.clock(0), "0:00")
    XCTAssertEqual(PutioCastControlsView.clock(65.9), "1:05")
    XCTAssertEqual(PutioCastControlsView.clock(3661), "1:01:01")
  }
}
