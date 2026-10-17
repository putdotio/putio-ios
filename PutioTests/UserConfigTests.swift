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

    func testOnlyAReadableFalseLeavesTheProductAnalyticsPromptUnanswered() throws {
        let cases: [(json: String, answered: Bool)] = [
            (#"{}"#, false),
            (#"{"dismissed.product_analytics_prompt":false}"#, false),
            (#"{"dismissed.product_analytics_prompt":true}"#, true),
            // A value the app can't read must not fail /config, and must not ask.
            (#"{"dismissed.product_analytics_prompt":"yes","chromecast_playback_type":"mp4"}"#, true)
        ]

        for (json, answered) in cases {
            let config = try decode(json)
            XCTAssertEqual(config.productAnalyticsPromptAnswered, answered, json)
        }
        XCTAssertEqual(try decode(cases[3].json).chromecastPlaybackType, .mp4)
    }

    private func decode(_ json: String) throws -> AppConfig {
        try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
    }
}
