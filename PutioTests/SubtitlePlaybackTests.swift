import XCTest
import PutioSDK
@testable import Putio

final class SubtitlePlaybackTests: XCTestCase {
    private let stream = URL(string: "https://api.put.io/v2/files/1/hls/media.m3u8?subtitle_key=all&oauth_token=t")!

    func testHiddenSubtitlesAskTheManifestForNoSubtitleTracks() {
        let url = stream.applyingSubtitlePreference(hideSubtitles: true)

        XCTAssertEqual(queryValue("max_subtitle_count", in: url), "0")
        XCTAssertEqual(queryValue("subtitle_key", in: url), "all")
    }

    func testShownSubtitlesKeepTheStreamURL() {
        XCTAssertEqual(stream.applyingSubtitlePreference(hideSubtitles: false), stream)
    }

    func testCastTrackLabelIsLanguageAndFileNameWithoutExtension() throws {
        let json = #"""
        {"key":"k","language":"English","language_code":"eng","name":"Sample.Show.S01E01.en.srt","source":"opensubtitles","url":"https://api.put.io/v2/files/1/subtitles/k?oauth_token=t"}
        """#
        let subtitle = try JSONDecoder().decode(PutioSubtitle.self, from: Data(json.utf8))

        XCTAssertEqual(subtitle.trackLabel, "English - Sample.Show.S01E01.en")
        XCTAssertEqual(subtitle.webVTTURL.flatMap { queryValue("format", in: $0) }, "webvtt")
    }

    private func queryValue(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }
}
