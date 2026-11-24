import XCTest

@testable import PutioCore

final class PutioMediaSelectionTests: XCTestCase {
  func testLanguageCodesFromHLSFilesAndTheOSCompareEqual() {
    XCTAssertEqual(
      ["eng", "en-US", "EN", "tur", "ger", "chi", "zh-Hans", "und"].map(
        PutioMediaSelection.languageCode),
      ["en", "en", "en", "tr", "de", "zh", "zh", "und"])
  }

  func testAudioFollowsTheFirstPreferredLanguagePresent() {
    let tracks = ["eng", "tur", "deu"]
    XCTAssertEqual(
      PutioMediaSelection.match(in: tracks, preferredLanguages: ["fr-FR", "tr-TR", "en"]), 1)
    XCTAssertNil(PutioMediaSelection.match(in: tracks, preferredLanguages: ["fr", "ja"]))
    XCTAssertNil(PutioMediaSelection.match(in: tracks, preferredLanguages: []))
  }

  @MainActor
  func testTheLastSpeedIsWhereTheNextPlaybackStarts() throws {
    let suite = "io.put.tests.speed-store"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    let video = PutioAudioSpeedStore(defaults: defaults, key: PutioAudioSpeedStore.videoKey)
    let audio = PutioAudioSpeedStore(defaults: defaults)
    XCTAssertEqual(video.load(), .normal)

    video.save(.fast)

    XCTAssertEqual(
      PutioAudioSpeedStore(defaults: defaults, key: PutioAudioSpeedStore.videoKey).load(), .fast)
    XCTAssertEqual(audio.load(), .normal, "the video speed changed the audio speed")
    defaults.set(Float(0.6), forKey: PutioAudioSpeedStore.videoKey)
    XCTAssertEqual(video.load(), .normal, "an unknown stored rate must fall back to 1×")
  }
}
