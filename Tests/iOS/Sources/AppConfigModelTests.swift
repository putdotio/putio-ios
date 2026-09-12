import Foundation
import PutioCore
import XCTest

@testable import Putio

@MainActor
final class AppConfigModelTests: XCTestCase {
  func testAutoplayIsOffUntilTheDocumentLoads() async {
    let model = model(load: { PutioAppConfig(autoplayNextVideo: true) })
    XCTAssertFalse(model.autoplayNextVideo)
    XCTAssertFalse(model.canSave)

    await model.loadIfNeeded()

    XCTAssertTrue(model.autoplayNextVideo)
    XCTAssertTrue(model.canSave)
  }

  func testFailedLoadOffersRetryThatReloadsTheDocument() async {
    var loads = 0
    let model = model(load: {
      loads += 1
      if loads == 1 { throw PutioRuntimeError.transient }
      return PutioAppConfig(autoplayNextVideo: true)
    })

    await model.loadIfNeeded()
    XCTAssertEqual(model.failure, "Check your connection and try again.")
    XCTAssertNil(model.config)

    await model.setAutoplayNextVideo(true)
    XCTAssertEqual(loads, 1, "an unloaded document must not accept writes")

    await model.retry()
    XCTAssertNil(model.failure)
    XCTAssertTrue(model.autoplayNextVideo)
    XCTAssertEqual(loads, 2)
  }

  func testFailedSaveKeepsTheAuthoritativeValueAndRetryRepeatsOnlyTheWrite() async {
    var loads = 0
    var writes: [Bool] = []
    let model = model(
      load: {
        loads += 1
        return PutioAppConfig()
      },
      save: { enabled in
        writes.append(enabled)
        if writes.count == 1 { throw PutioRuntimeError.unknown }
      })
    await model.loadIfNeeded()

    await model.setAutoplayNextVideo(true)
    XCTAssertFalse(model.autoplayNextVideo)
    XCTAssertEqual(model.failure, "Could not save playback settings. Try again.")
    XCTAssertEqual(model.failedAutoplayNextVideo, true)

    await model.retry()
    XCTAssertTrue(model.autoplayNextVideo)
    XCTAssertNil(model.failure)
    XCTAssertNil(model.failedAutoplayNextVideo)
    XCTAssertEqual(writes, [true, true])
    XCTAssertEqual(loads, 1)
  }

  func testUnchangedValueAndSessionFailuresProduceNoWriteOrMessage() async {
    var writes: [Bool] = []
    let model = model(
      load: { PutioAppConfig(autoplayNextVideo: false) },
      save: { enabled in
        writes.append(enabled)
        throw PutioRuntimeError.sessionExpired
      })
    await model.loadIfNeeded()

    await model.setAutoplayNextVideo(false)
    XCTAssertEqual(writes, [])

    await model.setAutoplayNextVideo(true)
    XCTAssertEqual(writes, [true])
    XCTAssertNil(model.failure, "the session root owns expiry")
    XCTAssertNil(model.failedAutoplayNextVideo)
    XCTAssertFalse(model.autoplayNextVideo)
  }

  func testAutoplayDecisionAwaitsTheLoadInFlight() async {
    var loads = 0
    var release: CheckedContinuation<PutioAppConfig, Never>?
    let model = model(load: {
      loads += 1
      return await withCheckedContinuation { release = $0 }
    })

    let load = Task { await model.loadIfNeeded() }
    while release == nil { await Task.yield() }
    XCTAssertTrue(model.isLoading)
    XCTAssertFalse(model.autoplayNextVideo, "an unloaded document reads as off")

    let decision = Task { await model.resolveAutoplayNextVideo() }
    await Task.yield()
    release?.resume(returning: PutioAppConfig(autoplayNextVideo: true))

    let autoplay = await decision.value
    await load.value
    XCTAssertTrue(autoplay)
    XCTAssertEqual(loads, 1, "the decision joins the load in flight instead of starting another")
    XCTAssertFalse(model.isLoading)
  }

  func testAutoplayDecisionLoadsAnUnloadedDocumentAndReadsItsValue() async {
    var loads = 0
    let model = model(load: {
      loads += 1
      return PutioAppConfig(autoplayNextVideo: false)
    })

    let autoplay = await model.resolveAutoplayNextVideo()

    XCTAssertFalse(autoplay)
    XCTAssertEqual(loads, 1)
    XCTAssertTrue(model.canSave)

    _ = await model.resolveAutoplayNextVideo()
    XCTAssertEqual(loads, 1, "a loaded document is read, not reloaded")
  }

  func testAutoplayDecisionIsOffWhenTheDocumentCannotLoad() async {
    let model = model(load: { throw PutioRuntimeError.transient })

    let autoplay = await model.resolveAutoplayNextVideo()

    XCTAssertFalse(autoplay)
    XCTAssertEqual(model.failure, "Check your connection and try again.")
  }

  private func model(
    load: @escaping @MainActor @Sendable () async throws -> PutioAppConfig,
    save: @escaping @MainActor @Sendable (Bool) async throws -> Void = { _ in }
  ) -> PutioAppConfigModel {
    PutioAppConfigModel(actions: .init(load: load, saveAutoplayNextVideo: save))
  }
}
