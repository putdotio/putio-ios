import XCTest

@testable import PutioCore

final class DirectPlayTests: XCTestCase {
  func testAudioDetailsNameTheCodecAndLayoutAsAndroidDoes() {
    XCTAssertEqual(
      PutioTrackLabel.audioDetail(codec: "eac3", profile: nil, channels: 6), "E-AC3 · 5.1")
    XCTAssertEqual(
      PutioTrackLabel.audioDetail(codec: "aac", profile: "LC", channels: 2), "AAC · stereo")
    XCTAssertEqual(
      PutioTrackLabel.audioDetail(codec: "dts", profile: "DTS-HD MA", channels: 8), "DTS-HD · 7.1")
    XCTAssertEqual(PutioTrackLabel.audioDetail(codec: "ac3", profile: nil, channels: 1), "AC3 · mono")
    XCTAssertEqual(
      PutioTrackLabel.audioDetail(codec: "pcm_s24le", profile: nil, channels: 4),
      "PCM · 4 channels")
    XCTAssertEqual(PutioTrackLabel.audioDetail(codec: "truehd", profile: nil, channels: nil), "TrueHD")
    XCTAssertNil(PutioTrackLabel.audioDetail(codec: "weird", profile: nil, channels: 0))
  }

  func testTracksWithoutALanguageOrNameAreNumbered() {
    XCTAssertEqual(PutioTrackLabel.audioTitle(language: "und", name: " ", index: 1), "Audio track 2")
    XCTAssertEqual(PutioTrackLabel.subtitleTitle(language: nil, name: nil, index: 0), "Subtitle 1")
    XCTAssertEqual(
      PutioTrackLabel.audioTitle(language: nil, name: "Director's commentary", index: 0),
      "Director's commentary")
  }

  func testTheEngineDecodesEveryAudioCodecButTheOnesItsBuildLacks() {
    for codec in ["aac", "ac3", "eac3", "dts", "truehd", "flac", "opus", "pcm_s16le"] {
      XCTAssertTrue(PutioDirectPlayDecoders.canDecodeAudio(codec: codec), codec)
    }
    for codec in ["ac4", "mpegh_3d_audio", "", nil] {
      XCTAssertFalse(PutioDirectPlayDecoders.canDecodeAudio(codec: codec), codec ?? "nil")
    }
  }

  func testTheHarnessReportsTwoLetterLanguageCodes() {
    XCTAssertEqual(PutioTrackLabel.languageCode("tur"), "tr")
    XCTAssertEqual(PutioTrackLabel.languageCode("eng"), "en")
    XCTAssertNil(PutioTrackLabel.languageCode(nil))
  }
}
