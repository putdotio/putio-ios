import GoogleCast
import PutioSDK
import RealmSwift
import XCTest
@testable import Putio

final class PutioCastReceiverTests: XCTestCase {
    private var originalConfiguration: Realm.Configuration!
    private var realm: Realm?

    override func setUp() {
        super.setUp()
        originalConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(inMemoryIdentifier: "\(type(of: self)).\(name)")
    }

    override func tearDown() {
        realm = nil
        Realm.Configuration.defaultConfiguration = originalConfiguration
        super.tearDown()
    }

    func testTheAppKnowsBothReceiversAndCanDiscoverEach() throws {
        XCTAssertEqual(PUTIO_CAST_RECEIVER_APP_ID, "E3A4ADFA")
        XCTAssertEqual(CHROMECAST_RECEIVER_APP_ID, kGCKDefaultMediaReceiverApplicationID)
        let services = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "NSBonjourServices") as? [String])
        XCTAssertTrue(services.contains("_googlecast._tcp"))
        XCTAssertTrue(services.contains("_E3A4ADFA._googlecast._tcp"))
        XCTAssertTrue(services.contains("_CC1AD845._googlecast._tcp"))
    }

    func testTheSwitchPicksTheReceiverAndTheSessionPicksTheLoad() {
        XCTAssertEqual(CastReceiver(usesPutioReceiver: false).applicationID, "CC1AD845")
        XCTAssertEqual(CastReceiver(usesPutioReceiver: true).applicationID, "E3A4ADFA")
        XCTAssertEqual(CastReceiver(applicationID: "E3A4ADFA"), .putio)
        XCTAssertEqual(CastReceiver(applicationID: "CC1AD845"), .defaultMedia)
        XCTAssertNil(CastReceiver(applicationID: "ABCDEF12"))
        XCTAssertNil(CastReceiver(applicationID: nil))
        XCTAssertEqual(ChromecastManager().sessionReceiver(nil), .defaultMedia)
    }

    func testOnlyAReadableTrueOptsIntoThePutioReceiver() throws {
        let cases: [(json: String, opted: Bool)] = [
            (#"{}"#, false),
            (#"{"beta.putio_cast_receiver":false}"#, false),
            (#"{"beta.putio_cast_receiver":true}"#, true),
            (#"{"beta.putio_cast_receiver":"true","chromecast_playback_type":"mp4"}"#, false)
        ]
        for (json, opted) in cases {
            let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
            XCTAssertEqual(UserConfig(config: config)?.usesPutioCastReceiver, opted, json)
        }
    }

    func testTheCustomDataMatchesTheReceiverContract() throws {
        let cases: [(load: PutioCastLoad, json: String)] = [
            (
                PutioCastLoad(fileID: 42, method: .hls, position: 90, token: "download-token", hidesSubtitles: false),
                #"{"fileId":42,"method":"hls","position":90,"token":"download-token"}"#
            ),
            (
                PutioCastLoad(fileID: 42, method: .file, position: -5, token: "download-token", hidesSubtitles: true),
                #"{"fileId":42,"maxSubtitleCount":0,"method":"file","position":0,"token":"download-token"}"#
            )
        ]
        for (load, json) in cases {
            let data = try JSONSerialization.data(withJSONObject: load.customData, options: .sortedKeys)
            XCTAssertEqual(String(decoding: data, as: UTF8.self), json)
        }
    }

    func testCustomDataMatchesSharedGoldenFixtures() throws {
        let cases: [(name: String, load: PutioCastLoad)] = [
            ("minimal", PutioCastLoad(fileID: 42, method: .hls, position: 0, token: "download-token", hidesSubtitles: false)),
            ("hls-with-position", PutioCastLoad(fileID: 42, method: .hls, position: 90, token: "download-token", hidesSubtitles: false)),
            ("file-method", PutioCastLoad(fileID: 42, method: .file, position: 0, token: "download-token", hidesSubtitles: false)),
            ("subtitle-max-count-zero", PutioCastLoad(fileID: 42, method: .hls, position: 0, token: "download-token", hidesSubtitles: true)),
            ("public-share-token", PutioCastLoad(fileID: 42, method: .hls, position: 0, token: "public-share-token", hidesSubtitles: false))
        ]
        let bundle = Bundle(for: Self.self)
        for (name, load) in cases {
            let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "json", subdirectory: "CastLoad"))
            let fixtureData = try Data(contentsOf: url)
            let fixtureObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: fixtureData) as? NSDictionary)
            let canonicalFixture = try JSONSerialization.data(withJSONObject: fixtureObject, options: .sortedKeys)
            let actualData = try JSONSerialization.data(withJSONObject: load.customData, options: .sortedKeys)
            XCTAssertEqual(
                try XCTUnwrap(String(data: actualData, encoding: .utf8)),
                try XCTUnwrap(String(data: canonicalFixture, encoding: .utf8)),
                name
            )
            XCTAssertEqual(load.customData as NSDictionary, fixtureObject, name)
        }
    }

    func testThePutioReceiverGetsTheFileAndTokenOnlyInCustomData() throws {
        try loadSession(playbackType: "hls", hidesSubtitles: true)
        let (media, options) = try build(for: .putio)

        XCTAssertEqual(media.contentID, "42")
        XCTAssertEqual(media.contentType, "application/x-mpegurl")
        XCTAssertEqual(media.streamType, .buffered)
        XCTAssertEqual(media.streamDuration, 600)
        XCTAssertNil(media.mediaTracks)
        XCTAssertEqual(options.playPosition, 90)
        let data = try JSONSerialization.data(withJSONObject: try XCTUnwrap(options.customData), options: .sortedKeys)
        XCTAssertEqual(
            String(decoding: data, as: UTF8.self),
            #"{"fileId":42,"maxSubtitleCount":0,"method":"hls","position":90,"token":"download-token"}"#
        )
    }

    func testTheDefaultReceiverKeepsTodaysPlainLoad() throws {
        try loadSession(playbackType: "hls", hidesSubtitles: true)
        let (media, options) = try build(for: .defaultMedia)

        let file = try makeFile()
        let expected = file.getHlsStreamURL(downloadToken: "download-token").applyingSubtitlePreference(hideSubtitles: true)
        XCTAssertEqual(media.contentID, expected.absoluteString)
        XCTAssertEqual(media.contentType, "video/m3u")
        XCTAssertEqual(media.streamType, .none)
        XCTAssertNil(options.customData)
        XCTAssertEqual(options.playPosition, 90)
    }

    func testReceiverStatusParsesTheContractMessages() {
        let cases: [(message: String, status: PutioReceiverStatus?)] = [
            (#"{"type":"STATUS","state":{"status":"idle"}}"#, .idle),
            (#"{"type":"STATUS","state":{"status":"loading","fileId":42}}"#, .loading(fileID: 42)),
            (#"{"type":"STATUS","state":{"status":"loaded","fileId":null}}"#, .loaded(fileID: nil)),
            (
                #"{"type":"STATUS","state":{"status":"failed","fileId":42,"reason":"invalid_token","detailedErrorCode":null}}"#,
                .failed(fileID: 42, reason: .invalidToken)
            ),
            (
                #"{"type":"STATUS","state":{"status":"failed","fileId":null,"reason":"missing_token","detailedErrorCode":null}}"#,
                .failed(fileID: nil, reason: .missingToken)
            ),
            (#"{"type":"STATUS","state":{"status":"failed","fileId":42,"reason":"gone"}}"#, nil),
            (#"{"type":"GET_STATUS"}"#, nil),
            (#"{"type":"STATUS","state":{"status":"paused"}}"#, nil),
            ("not json", nil)
        ]
        for (message, status) in cases {
            XCTAssertEqual(PutioReceiverStatus(message: message), status, message)
        }
    }

    func testAReceiverFailureAfterTheLoadResolvesCountsOnce() {
        let cast = AnalyticsEvent.Playback(media: .video, streamMethod: .hls, player: .chromecast)
        var events: [AnalyticsEvent] = []
        var reports: [(started: Bool, error: Error?)] = []
        let tracker = CastPlaybackTracker(
            capture: { event, _ in events.append(event) },
            report: { failure, error, _ in reports.append((failure.started, error)) }
        )

        let load = NSObject()
        tracker.loadStarted(load, playback: cast, fileID: 42, session: 1)
        XCTAssertTrue(tracker.loadCompleted(load, status: .init(playerState: .loading, mediaSessionID: 3)))
        tracker.update(.init(playerState: .idle, idleReason: .error, mediaSessionID: 3))
        tracker.receiverFailed(fileID: 7, reason: .streamFailed)
        tracker.receiverFailed(fileID: 42, reason: .invalidToken)
        tracker.receiverFailed(fileID: 42, reason: .streamFailed)

        XCTAssertEqual(events, [.playbackStarted(cast), .playbackFailed(cast, .source)])
        XCTAssertEqual(reports.map(\.started), [false])
        XCTAssertEqual(reports.first?.error as? PutioReceiverStatus.Reason, .invalidToken)
    }

    func testAPlayedCastThatFailsReportsItStarted() {
        let cast = AnalyticsEvent.Playback(media: .video, streamMethod: .hls, player: .chromecast)
        var events: [AnalyticsEvent] = []
        var started: [Bool] = []
        let tracker = CastPlaybackTracker(capture: { event, _ in events.append(event) }, report: { failure, _, _ in started.append(failure.started) })

        let load = NSObject()
        tracker.loadStarted(load, playback: cast, fileID: 42, session: 1)
        XCTAssertTrue(tracker.loadCompleted(load, status: .init(playerState: .playing, mediaSessionID: 3)))
        tracker.update(.init(playerState: .playing, mediaSessionID: 3))
        tracker.receiverFailed(fileID: 42, reason: .streamFailed)

        XCTAssertEqual(events, [.playbackStarted(cast), .playbackFailed(cast, .media)])
        XCTAssertEqual(started, [true])
    }

    func testARejectedLoadCountsOnlyItsLoadFailure() {
        let cast = AnalyticsEvent.Playback(media: .video, streamMethod: .hls, player: .chromecast)
        var events: [AnalyticsEvent] = []
        let tracker = CastPlaybackTracker(capture: { event, _ in events.append(event) }, report: { _, _, _ in })

        let load = NSObject()
        tracker.loadStarted(load, playback: cast, fileID: 42, session: 1)
        tracker.loadFailed(load, error: GCKError(code: .mediaLoadFailed))
        tracker.receiverFailed(fileID: 42, reason: .missingToken)

        XCTAssertEqual(events, [.playbackFailed(cast, .media)])
    }

    private func build(for receiver: CastReceiver) throws -> (GCKMediaInformation, GCKMediaLoadOptions) {
        let file = try makeFile()
        let manager = ChromecastManager()
        let options = manager.createGCKMediaLoadOptions(for: file)
        var built: GCKMediaInformation?
        manager.createGCKMediaInformation(
            for: file,
            receiver: receiver,
            metadata: manager.createGCKMediaMetadata(for: file),
            mediaLoadOptions: options
        ) { media, _ in built = media }
        return (try XCTUnwrap(built), options)
    }

    private func loadSession(playbackType: String, hidesSubtitles: Bool) throws {
        let account = try JSONDecoder().decode(PutioAccount.self, from: Data("""
        {
          "user_id": 1, "username": "tester", "mail": "test@put.io",
          "account_active": true, "account_status": "active", "is_sub_account": false,
          "disk": { "avail": 0, "size": 0, "used": 0 },
          "settings": { "hide_subtitles": \(hidesSubtitles) }
        }
        """.utf8))
        let user = try XCTUnwrap(User(account: account))
        user.downloadToken = "download-token"
        let configJSON = #"{"chromecast_playback_type":"\#(playbackType)"}"#
        let config = try XCTUnwrap(UserConfig(config: try JSONDecoder().decode(AppConfig.self, from: Data(configJSON.utf8))))
        let realm = try Realm()
        self.realm = realm
        XCTAssertTrue(PutioRealm.replaceUserSession(realm, user: user, config: config, context: "PutioCastReceiverTests"))
    }

    private func makeFile() throws -> PutioFile {
        let payload: [String: Any] = [
            "id": 42,
            "name": "Episode",
            "icon": "video",
            "parent_id": 0,
            "file_type": "VIDEO",
            "size": 1024,
            "created_at": "2026-04-20T00:00:00Z",
            "updated_at": "2026-04-20T00:00:00Z",
            "is_shared": false,
            "screenshot": "https://put.io/screenshot.jpg",
            "start_from": 90,
            "video_metadata": ["duration": 600, "codec": "h264", "height": 720, "width": 1280]
        ]
        return try JSONDecoder().decode(PutioFile.self, from: JSONSerialization.data(withJSONObject: payload))
    }
}
