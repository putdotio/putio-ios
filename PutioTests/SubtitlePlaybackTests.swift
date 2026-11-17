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

    func testHiddenSubtitlesStartOffOnlyForOfflinePlayback() {
        let offline = MediaPlayerItem(id: 1, name: "Sample.Show.S01E01.mkv", url: stream, fileType: .video, consumptionType: .offline)
        let online = MediaPlayerItem(id: 1, name: "Sample.Show.S01E01.mkv", url: stream, fileType: .video, consumptionType: .online)

        XCTAssertTrue(offline.startsWithSubtitlesOff(hideSubtitles: true))
        XCTAssertFalse(offline.startsWithSubtitlesOff(hideSubtitles: false))
        XCTAssertFalse(online.startsWithSubtitlesOff(hideSubtitles: true))
    }

    func testCastTrackLabelIsLanguageAndFileNameWithoutExtension() throws {
        let subtitle = try sidecar(format: "srt", name: "Sample.Show.S01E01.en.srt")

        XCTAssertEqual(subtitle.trackLabel, "English - Sample.Show.S01E01.en")
        XCTAssertEqual(subtitle.castableURL.flatMap { queryValue("format", in: $0) }, "webvtt")
    }

    func testCastTrackLabelDropsOnlyASubtitleExtension() throws {
        XCTAssertEqual(try sidecar(format: "srt", name: "Sample.Show.S01E01.EN.SRT").trackLabel, "English - Sample.Show.S01E01.EN")
        XCTAssertEqual(try sidecar(format: "srt", name: "Sample.Show.S01E01.720p").trackLabel, "English - Sample.Show.S01E01.720p")
    }

    func testCastSkipsSidecarsTheReceiverCannotRender() throws {
        XCTAssertNil(try sidecar(format: "ass", name: "Sample.Show.S01E01.en.ass").castableURL)
    }

    private func sidecar(format: String, name: String) throws -> PutioSubtitle {
        let json = """
        {"format":"\(format)","key":"k","language":"English","language_code":"eng","name":"\(name)","source":"mkv","url":"https://api.put.io/v2/files/1/subtitles/k?oauth_token=t"}
        """
        return try JSONDecoder().decode(PutioSubtitle.self, from: Data(json.utf8))
    }

    private func queryValue(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }
}
