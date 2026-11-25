import PutioCore
import XCTest

@testable import Putio

@MainActor
final class ExternalPlaybackTests: XCTestCase {
  func testRemovedVLCFixtureStaysListedUntilTheHandoff() async {
    let opener = HarnessExternalURLOpener(
      vlcInstalled: false, hidesVLCAtHandoff: true, refusesFirstHandoff: false)
    let model = PutioExternalPlaybackModel(opener: opener, returnsToFolder: false) { _ in
      XCTFail("resolved a file for a removed VLC")
      return PutioFileDownloadSource(
        id: PutioFileID(rawValue: 412), kind: .video, name: "Movie.mkv",
        url: URL(string: "https://api.put.io/v2/files/412/download")!)
    }
    for _ in 0..<3 {
      model.refreshInstallation()
      XCTAssertTrue(model.isVLCInstalled)
    }
    await model.open(
      PutioFileRoute(
        item: BrowserTestFixtures.item(id: 412, parentID: 410, name: "Movie.mkv", kind: .video)))
    XCTAssertEqual(model.missingVLCRoute?.id, PutioFileID(rawValue: 412))
    XCTAssertNil(model.toast)
  }
}
