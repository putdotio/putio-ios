import PutioSDK
import RealmSwift
import XCTest
@testable import Putio

final class UserConfigTests: XCTestCase {
    func testMissingUnknownOrUnreadableChromecastPlaybackTypeFallsBackToHLS() throws {
        for json in [#"{}"#, #"{"chromecast_playback_type":"webm"}"#, #"{"chromecast_playback_type":1}"#] {
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

    func testAutoRotateVideoIsOnUnlessReadablyOff() throws {
        let cases: [(json: String, enabled: Bool)] = [
            (#"{}"#, true),
            (#"{"auto_rotate_video":true}"#, true),
            (#"{"auto_rotate_video":false}"#, false),
            (#"{"auto_rotate_video":"no","chromecast_playback_type":"mp4"}"#, true)
        ]

        for (json, enabled) in cases {
            XCTAssertEqual(UserConfig(config: try decode(json))?.autoRotateVideo, enabled, json)
        }
    }

    func testChromecastReadsTheConfigOfTheSessionThatLoadedLast() throws {
        let originalConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(inMemoryIdentifier: #function)
        defer { Realm.Configuration.defaultConfiguration = originalConfiguration }
        let realm = try Realm()
        try loadSession(in: realm, chromecastPlaybackType: "hls")
        // Built by the first main screen, then kept for the life of the process.
        let manager = ChromecastManager()
        XCTAssertEqual(manager.userConfig?.chromecastPlaybackType, "hls")

        // Signing out and in again replaces the session's UserConfig.
        try loadSession(in: realm, chromecastPlaybackType: "mp4")

        let castConfig = try XCTUnwrap(manager.userConfig)
        XCTAssertFalse(castConfig.isInvalidated, "the next cast reads a deleted UserConfig and throws RLMException")
        if !castConfig.isInvalidated { XCTAssertEqual(castConfig.chromecastPlaybackType, "mp4") }
    }

    private func loadSession(in realm: Realm, chromecastPlaybackType: String) throws {
        let user = try XCTUnwrap(User(account: try account()))
        let config = try XCTUnwrap(UserConfig(config: try decode(#"{"chromecast_playback_type":"\#(chromecastPlaybackType)"}"#)))
        XCTAssertTrue(PutioRealm.replaceUserSession(realm, user: user, config: config, context: "UserConfigTests"))
    }

    private func account() throws -> PutioAccount {
        let json = """
        {
          "user_id": 1, "username": "tester", "mail": "test@put.io",
          "account_active": true, "account_status": "active", "is_sub_account": false,
          "disk": { "avail": 0, "size": 0, "used": 0 },
          "settings": {}
        }
        """
        return try JSONDecoder().decode(PutioAccount.self, from: Data(json.utf8))
    }

    private func decode(_ json: String) throws -> AppConfig {
        try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
    }
}
