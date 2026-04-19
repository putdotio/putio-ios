import XCTest
@testable import Putio
import SwiftyJSON

final class UserConfigTests: XCTestCase {
    func testMissingChromecastPlaybackTypeFallsBackToHLS() {
        let config = UserConfig(json: JSON([:]))

        XCTAssertEqual(config?.chromecastPlaybackType, "hls")
    }

    func testEmptyChromecastPlaybackTypeFallsBackToHLS() {
        let config = UserConfig(json: JSON(["chromecast_playback_type": ""]))

        XCTAssertEqual(config?.chromecastPlaybackType, "hls")
    }

    func testInvalidChromecastPlaybackTypeFallsBackToHLS() {
        let config = UserConfig(json: JSON(["chromecast_playback_type": "bogus"]))

        XCTAssertEqual(config?.chromecastPlaybackType, "hls")
    }

    func testValidChromecastPlaybackTypeIsPreserved() {
        let config = UserConfig(json: JSON(["chromecast_playback_type": "mp4"]))

        XCTAssertEqual(config?.chromecastPlaybackType, "mp4")
    }
}
