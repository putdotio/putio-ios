import AetherEngine
import PutioCore
import XCTest

@testable import Putio

@MainActor
private final class AudioSelections {
  var languages: [String] = []
}

@MainActor
final class PutioDirectPlayAudioStartTests: XCTestCase {
  func testATurkishDeviceStartsTheTurkishTrackOverTheEnglishFileDefault() async throws {
    let started = try await startingAudio(preferring: ["tr-TR", "en-US"])

    XCTAssertEqual(started, "tr")
  }

  func testADeviceLanguageTheFileLacksKeepsTheFileDefault() async throws {
    let started = try await startingAudio(preferring: ["de-DE"])

    XCTAssertEqual(started, "en")
  }

  private func startingAudio(preferring languages: [String]) async throws -> String? {
    let file = try XCTUnwrap(
      Bundle.main.url(
        forResource: "runtime-proof-direct", withExtension: "mkv", subdirectory: "HarnessMedia"))
    let coordinator = PutioDirectPlayCoordinator(positionPipeline: PutioPlaybackPositionPipeline())
    defer { coordinator.stop() }
    let selections = AudioSelections()
    let ready = expectation(description: "Direct play is ready")
    var callbacks = PutioVideoPlayerCallbacks()
    callbacks.observesPlaybackState = true
    callbacks.onAudioSelected = { selections.languages.append($0) }
    callbacks.onReady = { ready.fulfill() }
    callbacks.onFailure = { XCTFail("Direct play failed: \($0)") }

    coordinator.start(
      fileID: PutioFileID(rawValue: 412),
      source: PutioPlaybackSource(
        url: file, startFromSeconds: 0, original: PutioOriginalPlayback(player: .engine)),
      transport: PutioVideoTransport(), preferredAudioLanguages: languages,
      remembersPlaybackPosition: false,
      subtitles: PutioDirectPlayCoordinator.SubtitleStart(
        policy: .accountDefault, remembered: { nil }),
      reportPosition: { _, _ in }, in: AetherPlayerView(), callbacks: callbacks)

    await fulfillment(of: [ready], timeout: 30)
    return selections.languages.last
  }
}
