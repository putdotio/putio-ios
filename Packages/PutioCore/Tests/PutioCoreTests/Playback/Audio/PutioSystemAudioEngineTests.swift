import AVFoundation
import Foundation
import XCTest

@testable import PutioCore

@MainActor
final class PutioSystemAudioEngineTests: XCTestCase {
  func testSystemEngineIgnoresQueuedEndFromReplacedItem() async throws {
    let engine = PutioSystemAudioEngine()
    defer { engine.stop() }
    let ended = expectation(description: "retired item must not end its replacement")
    ended.isInverted = true
    engine.onEnded = { ended.fulfill() }
    let url = FileManager.default.temporaryDirectory.appending(path: "putio-retired-audio.m4a")
    engine.load(url: url, startFromSeconds: 0)
    let retiredItem = try XCTUnwrap(engine.player.currentItem)
    NotificationCenter.default.post(
      name: AVPlayerItem.didPlayToEndTimeNotification, object: retiredItem)
    engine.load(url: url, startFromSeconds: 0)
    await fulfillment(of: [ended], timeout: 0.2)
  }

  func testSystemEngineIgnoresQueuedFailureAfterStop() async throws {
    let engine = PutioSystemAudioEngine()
    let failed = expectation(description: "stopped item must not report failure")
    failed.isInverted = true
    engine.onFailed = { failed.fulfill() }
    let url = FileManager.default.temporaryDirectory.appending(path: "putio-stopped-audio.m4a")
    engine.load(url: url, startFromSeconds: 0)
    let retiredItem = try XCTUnwrap(engine.player.currentItem)
    NotificationCenter.default.post(
      name: AVPlayerItem.failedToPlayToEndTimeNotification, object: retiredItem)
    engine.stop()
    await fulfillment(of: [failed], timeout: 0.2)
  }
}
