import XCTest
@testable import Putio

final class UserConfigTests: XCTestCase {
    func testMissingOrUnknownChromecastPlaybackTypeFallsBackToHLS() throws {
        for json in [#"{}"#, #"{"chromecast_playback_type":"webm"}"#] {
            XCTAssertEqual(UserConfig(config: try decode(json))?.chromecastPlaybackType, "hls", json)
        }
    }

    func testValidChromecastPlaybackTypeIsPreserved() throws {
        let config = UserConfig(config: try decode(#"{"chromecast_playback_type":"mp4"}"#))

        XCTAssertEqual(config?.chromecastPlaybackType, "mp4")
    }

    private func decode(_ json: String) throws -> AppConfig {
        try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
    }
}
