import Foundation
import XCTest

@testable import PutioCore

final class PutioVideoSubtitlesTests: XCTestCase {
  private let english = PutioSubtitleTrack(id: 0, title: "English", languageTag: "en", isDefault: true)
  private let englishFolder = PutioSubtitleTrack(id: 1, title: "English", languageTag: "en")
  private let turkish = PutioSubtitleTrack(id: 2, title: "Turkish", languageTag: "tr")

  func testMenuGroupsManifestTracksByTheSourceTheSubtitlesListGives() {
    let menu = PutioSubtitleMenu(
      tracks: [english, englishFolder, turkish],
      listings: [
        PutioSubtitleListing(languageCode: "tur", source: PutioSubtitleSource(apiSource: "opensubtitles")),
        PutioSubtitleListing(languageCode: "eng", source: PutioSubtitleSource(apiSource: "mkv")),
        PutioSubtitleListing(languageCode: "eng", source: PutioSubtitleSource(apiSource: "folder")),
      ])

    XCTAssertEqual(menu.inFile.map(\.track), [english])
    XCTAssertEqual(menu.inFile.map(\.source), [.embedded])
    XCTAssertEqual(menu.found.map(\.track), [englishFolder, turkish])
    XCTAssertEqual(menu.found.map(\.source), [.folder, .openSubtitles])
    XCTAssertTrue(menu.unsourced.isEmpty)
  }

  func testBibliographicAndUnknownLanguageCodesKeyTheirManifestTracks() {
    let german = PutioSubtitleTrack(id: 0, title: "German", languageTag: "de")
    let unknown = PutioSubtitleTrack(id: 1, title: "Unknown", languageTag: "Unknown")
    let menu = PutioSubtitleMenu(
      tracks: [german, unknown],
      listings: [
        PutioSubtitleListing(languageCode: "und", source: .folder),
        PutioSubtitleListing(languageCode: "ger", source: .openSubtitles),
      ])

    XCTAssertEqual(menu.found.map(\.track), [german, unknown])
    XCTAssertEqual(menu.found.map(\.source), [.openSubtitles, .folder])
  }

  func testATrackTheListDoesNotCoverLeavesEveryTrackUnsourced() {
    let menu = PutioSubtitleMenu(
      tracks: [english, turkish],
      listings: [PutioSubtitleListing(languageCode: "eng", source: .embedded)])

    XCTAssertTrue(menu.inFile.isEmpty)
    XCTAssertTrue(menu.found.isEmpty)
    XCTAssertEqual(menu.unsourced.map(\.track), [english, turkish])
    XCTAssertEqual(menu.unsourced.map(\.source), [nil, nil])
  }

  func testNoTracksMakeAnEmptyMenu() {
    XCTAssertTrue(PutioSubtitleMenu(tracks: [], listings: []).isEmpty)
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
}
