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

    func testCastSidecarsUseWebVTT() throws {
        let subtitle = try sidecar(format: "srt", name: "Sample.Show.S01E01.en.srt")

        XCTAssertEqual(subtitle.castableURL.flatMap { queryValue("format", in: $0) }, "webvtt")
    }

    func testCastTrackLabelsMatchTheBackendManifestNames() throws {
        let subtitles = try [
            sidecar(format: "srt", name: "Sample.Show.S01E01.720p.srt"),
            sidecar(format: "srt", name: "Sample.Show.S01E01.720p"),
            sidecar(format: "srt", name: "Sample.Show.S01E01.720p.SRT"),
            sidecar(format: "srt", name: ".srt"),
            sidecar(format: "srt", name: #"Say "hi".srt"#),
            sidecar(format: "srt", name: ""),
            sidecar(format: "srt", name: "Sample.Show.S01E01.srt", languageCode: "und")
        ]

        XCTAssertEqual(PutioSubtitle.trackLabels(for: subtitles), [
            "English - Sample.Show.S01E01.720p",
            "English - Sample.Show.S01E01",
            "English - Sample.Show.S01E01.720p (2)",
            "English - .srt",
            "English - Say 'hi'",
            "English",
            "Unknown - Sample.Show.S01E01"
        ])
    }

    func testCastSkipsSidecarsTheReceiverCannotRender() throws {
        XCTAssertNil(try sidecar(format: "ass", name: "Sample.Show.S01E01.en.ass").castableURL)
    }

    private func sidecar(format: String, name: String, languageCode: String = "eng") throws -> PutioSubtitle {
        let fields: [String: String] = [
            "format": format, "key": "k", "language": "English", "language_code": languageCode, "name": name,
            "source": "mkv", "url": "https://api.put.io/v2/files/1/subtitles/k?oauth_token=t"
        ]
        return try JSONDecoder().decode(PutioSubtitle.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    private func queryValue(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }
}
