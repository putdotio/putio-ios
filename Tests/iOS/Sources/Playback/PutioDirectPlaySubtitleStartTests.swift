import AetherEngine
import PutioCore
import XCTest

@testable import Putio

@MainActor
final class PutioDirectPlaySubtitleStartTests: XCTestCase {
  private let tracks = [
    TrackInfo(
      id: 2, name: "Turkish", codec: "subrip", language: "tur", isDefault: true, isForced: true),
    TrackInfo(id: 3, name: "Turkish", codec: "subrip", language: "tur", isDefault: false),
    TrackInfo(id: 4, name: "English", codec: "subrip", language: "eng", isDefault: true),
    TrackInfo(
      id: 100, name: "English", codec: "webvtt", language: "en", isDefault: true,
      isExternal: true),
  ]

  func testARememberedLanguageStartsItsFullTrackOverAForcedOne() {
    let start = PutioSubtitleStartupPolicy.accountDefault.startingTrack(
      in: PutioDirectPlayCoordinator.startCandidates(tracks), remembered: .language("tr"))

    XCTAssertEqual(start?.id, 3)
  }

  func testNothingRememberedStartsThePutioDefaultOverTheFileDefault() {
    let start = PutioSubtitleStartupPolicy.accountDefault.startingTrack(
      in: PutioDirectPlayCoordinator.startCandidates(tracks), remembered: nil)

    XCTAssertEqual(start?.id, 100)
  }
}
