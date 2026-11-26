import XCTest

@testable import PutioDomain

final class PutioVideoAudioTracksTests: XCTestCase {
  func testMasterPlaylistGivesEachAudioRenditionItsCodecAndLayout() throws {
    let master = try XCTUnwrap(URL(string: "http://127.0.0.1:9/multi-audio/master.m3u8"))
    let renditions = PutioAudioRendition.parse(
      masterPlaylist: """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac",NAME="English",DEFAULT=YES,LANGUAGE="eng",CHANNELS="2",URI="en.m3u8"
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="eac3",NAME="Kommentar, Regie",LANGUAGE="de",CHANNELS="6/JOC",URI="de.m3u8"
        #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",LANGUAGE="en",URI="sub.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=2030,CODECS="avc1.64000c,mp4a.40.2",AUDIO="aac"
        video.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=4030,CODECS="avc1.64000c,ec-3",AUDIO="eac3"
        video.m3u8
        """, relativeTo: master)

    XCTAssertEqual(
      renditions,
      [
        PutioAudioRendition(
          name: "English", languageTag: "eng", channels: 2, codec: "aac",
          uri: URL(string: "http://127.0.0.1:9/multi-audio/en.m3u8")),
        PutioAudioRendition(
          name: "Kommentar, Regie", languageTag: "de", channels: 6, codec: "eac3",
          uri: URL(string: "http://127.0.0.1:9/multi-audio/de.m3u8")),
      ])
    XCTAssertEqual(
      renditions.map {
        PutioTrackLabel.audioDetail(codec: $0.codec, profile: nil, channels: $0.channels)
      },
      ["AAC · stereo", "E-AC3 · 5.1"])
  }

  func testOnlyAnErrorOnTheNewPlaylistRightAfterTheSwitchFailsIt() throws {
    let playlist = try XCTUnwrap(URL(string: "http://127.0.0.1:9/multi-audio/tr.m3u8"))
    let start = Date(timeIntervalSince1970: 1_000)
    let audioSwitch = PutioVideoAudioSwitch(previous: 0, playlist: playlist, startedAt: start)
    let soon = start.addingTimeInterval(2)

    XCTAssertTrue(
      audioSwitch.failed(
        by: PutioVideoErrorEvent(uri: playlist, date: soon)))
    XCTAssertFalse(
      audioSwitch.failed(
        by: PutioVideoErrorEvent(uri: nil, date: soon)),
      "an error with no request blamed the switch")
    XCTAssertFalse(
      audioSwitch.failed(
        by: PutioVideoErrorEvent(
          uri: playlist, date: start.addingTimeInterval(60))),
      "a later error on a working track reverted it")
    XCTAssertFalse(
      audioSwitch.failed(
        by: PutioVideoErrorEvent(
          uri: URL(string: "http://127.0.0.1:9/multi-audio/video-000.ts"),
          date: soon)),
      "a video segment error blamed the switch")
    XCTAssertFalse(audioSwitch.isOver(at: soon))
    XCTAssertTrue(audioSwitch.isOver(at: start.addingTimeInterval(10)))
  }
}
