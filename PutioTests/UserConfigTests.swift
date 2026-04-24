import XCTest
@testable import Putio
import PutioSDK

final class UserConfigTests: XCTestCase {
    func testMissingChromecastPlaybackTypeFallsBackToHLS() {
        let config = UserConfig(config: PutioConfig())

        XCTAssertEqual(config?.chromecastPlaybackType, "hls")
    }

    func testValidChromecastPlaybackTypeIsPreserved() {
        let config = UserConfig(config: PutioConfig(chromecastPlaybackType: .mp4))

        XCTAssertEqual(config?.chromecastPlaybackType, "mp4")
    }
}
