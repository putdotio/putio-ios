import Foundation
import XCTest

@testable import PutioCore

final class PutioVideoSubtitlesTests: XCTestCase {
  private let english = PutioSubtitleTrack(
    id: 0, title: "English", languageTag: "en", isDefault: true)
  private let turkish = PutioSubtitleTrack(id: 2, title: "Turkish", languageTag: "tr")

  func testRowsKeepEachTrackNameInOrder() {
    let menu = PutioSubtitleMenu(tracks: [turkish, english])

    XCTAssertEqual(menu.rows.map(\.title), ["Turkish", "English"])
  }

  func testNoTracksMakeAnEmptyMenu() {
    XCTAssertTrue(PutioSubtitleMenu(tracks: []).isEmpty)
  }

  func testHiddenSubtitlesStartOffWhateverWasRemembered() {
    let policy = PutioSubtitleStartupPolicy(hideSubtitles: true, dontAutoSelectSubtitles: false)

    XCTAssertNil(policy.startingTrack(in: [english, turkish], remembered: .language("tr")))
  }

  func testTheRememberedLanguageOutranksTheAccountDefault() {
    let policy = PutioSubtitleStartupPolicy(hideSubtitles: false, dontAutoSelectSubtitles: true)

    XCTAssertEqual(
      policy.startingTrack(in: [english, turkish], remembered: .language("tur")), turkish)
    XCTAssertNil(
      PutioSubtitleStartupPolicy.accountDefault.startingTrack(
        in: [english, turkish], remembered: .off))
  }

  func testARememberedLanguageTheFileLacksFallsBackToTheAccountChoice() {
    XCTAssertEqual(
      PutioSubtitleStartupPolicy.accountDefault.startingTrack(
        in: [english, turkish], remembered: .language("de")), english)
    XCTAssertNil(
      PutioSubtitleStartupPolicy(hideSubtitles: false, dontAutoSelectSubtitles: true)
        .startingTrack(in: [english, turkish], remembered: .language("de")))
  }

  @MainActor
  func testMemoryKeepsTheLastLanguageOrOff() throws {
    let suite = "PutioVideoSubtitlesTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let memory = PutioSubtitleMemory(defaults: defaults)

    XCTAssertNil(memory.remembered)
    memory.remember(turkish)
    XCTAssertEqual(PutioSubtitleMemory(defaults: defaults).remembered, .language("tr"))
    memory.remember(PutioSubtitleTrack(id: 3, title: "Unknown", languageTag: "Unknown"))
    XCTAssertEqual(memory.remembered, .language("tr"))
    memory.forget(english)
    XCTAssertEqual(memory.remembered, .language("tr"))
    memory.forget(turkish)
    XCTAssertNil(memory.remembered)
    memory.remember(nil)
    XCTAssertEqual(PutioSubtitleMemory(defaults: defaults).remembered, .off)
  }

  func testRenditionURIsComeFromTheMasterPlaylistSubtitlesOnly() throws {
    let master = """
      #EXTM3U
      #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="group_aud",NAME="English",URI="multi-English.m3u8"
      #EXT-X-STREAM-INF:BANDWIDTH=2030,AUDIO="group_aud",SUBTITLES="subs0"
      multi-video.m3u8
      #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs0",LANGUAGE="en",NAME="English",AUTOSELECT=YES,DEFAULT=YES,URI="multi-subtitle-English.m3u8"
      #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs0",LANGUAGE="tr",NAME="Turkish",AUTOSELECT=NO,DEFAULT=NO,URI="https://api.put.io/hls/playlist/k/index.m3u8?oauth_token=t"
      """
    let base = try XCTUnwrap(URL(string: "http://127.0.0.1:8080/multi-audio/multi-subtitles.m3u8"))

    XCTAssertEqual(
      PutioSubtitleRenditions.uris(inMasterPlaylist: master, relativeTo: base),
      [
        try XCTUnwrap(URL(string: "http://127.0.0.1:8080/multi-audio/multi-subtitle-English.m3u8")),
        try XCTUnwrap(URL(string: "https://api.put.io/hls/playlist/k/index.m3u8?oauth_token=t")),
      ])
  }

  func testSegmentsComeFromTheMediaPlaylistURIs() throws {
    let playlist = """
      #EXTM3U
      #EXT-X-TARGETDURATION:20
      #EXTINF:20.000000,
      multi-subtitle-English.vtt
      #EXTINF:20.000000,
      https://cdn.put.io/s/2.vtt?t=1
      #EXT-X-ENDLIST
      """
    let base = try XCTUnwrap(URL(string: "http://127.0.0.1:8080/multi-audio/multi-subtitle-English.m3u8"))

    XCTAssertEqual(
      PutioSubtitleRenditions.segments(inMediaPlaylist: playlist, relativeTo: base),
      [
        try XCTUnwrap(URL(string: "http://127.0.0.1:8080/multi-audio/multi-subtitle-English.vtt")),
        try XCTUnwrap(URL(string: "https://cdn.put.io/s/2.vtt?t=1")),
      ])
  }

  func testRenditionsKeepTheirManifestNameLanguageAndDefault() {
    let master = """
      #EXTM3U
      #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="group_aud",NAME="English",DEFAULT=YES,URI="a.m3u8"
      #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs0",LANGUAGE="tr",NAME="Turkish 1",AUTOSELECT=YES,DEFAULT=YES,URI="t1.m3u8"
      #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs0",LANGUAGE="tr",NAME="Turkish 2",AUTOSELECT=NO,DEFAULT=NO,URI="t2.m3u8"
      """

    XCTAssertEqual(
      PutioSubtitleRenditions.renditions(inMasterPlaylist: master),
      [
        PutioSubtitleRendition(name: "Turkish 1", languageTag: "tr", isDefault: true),
        PutioSubtitleRendition(name: "Turkish 2", languageTag: "tr", isDefault: false),
      ])
  }
}
