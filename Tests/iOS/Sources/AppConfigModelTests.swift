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

  private func model(
    load: @escaping @MainActor @Sendable () async throws -> PutioAppConfig,
    save: @escaping @MainActor @Sendable (Bool) async throws -> Void = { _ in }
  ) -> PutioAppConfigModel {
    PutioAppConfigModel(actions: .init(load: load, saveAutoplayNextVideo: save))
  }
}
