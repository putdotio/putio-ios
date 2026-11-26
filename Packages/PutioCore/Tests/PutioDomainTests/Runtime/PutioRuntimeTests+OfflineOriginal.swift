import Foundation
import XCTest

@testable import PutioDomain

extension PutioRuntimeTests {
  func testOfflineOriginalIsTheFileWithEverySubtitleFileEvenWhenSubtitlesAreHidden() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(
      #"{"file":{"id":412,"parent_id":0,"name":"Movie.mkv","file_type":"VIDEO","size":10,"start_from":734,"created_at":"2026-08-28T10:00:00Z","updated_at":"2026-08-29T10:00:00Z"}}"#,
      for: "GET /v2/files/412")
    fixtures.setFixture(
      """
      {"default":"tr","subtitles":[
        {"key":"en","language":"English","language_code":"eng","name":"English.srt","source":"mkv","url":"https://api.put.io/v2/files/412/subtitles/en"},
        {"key":"tr","language":"Turkish","language_code":"tur","name":"Turkish.srt","source":"opensubtitles","url":"https://api.put.io/v2/files/412/subtitles/tr?oauth_token=stored-token"},
        {"key":"x","language":"Elsewhere","language_code":"und","name":"x.srt","source":"folder","url":"https://example.com/x.srt"}
      ]}
      """, for: "GET /v2/files/412/subtitles")
    fixtures.setFixture(
      Self.accountInfo.replacingOccurrences(
        of: #""hide_subtitles": false"#, with: #""hide_subtitles": true"#),
      for: "GET /v2/account/info")
    let refreshed = await runtime.refreshAccount()
    XCTAssertTrue(refreshed)
    guard case .signedIn(let account) = runtime.session.state else { return XCTFail("signed out") }
    XCTAssertTrue(account.hideSubtitles)

    let original = try await runtime.resolveOfflineOriginal(fileID: PutioFileID(rawValue: 412))

    XCTAssertEqual(original.file.url.path, "/v2/files/412/download")
    XCTAssertEqual(original.startFromSeconds, 734)
    XCTAssertEqual(original.subtitles.map(\.key), ["en", "tr"])
    XCTAssertEqual(original.defaultSubtitleKey, "tr")
    XCTAssertTrue(original.enginePlays)
    XCTAssertEqual(original.subtitles.map(\.languageCode), ["eng", "tur"])
    for subtitle in original.subtitles {
      let query = URLComponents(url: subtitle.url, resolvingAgainstBaseURL: false)?.queryItems
      XCTAssertEqual(
        query?.filter { $0.name == "oauth_token" }.map(\.value), ["account-download-secret"])
      XCTAssertEqual(query?.first { $0.name == "format" }?.value, "webvtt")
    }
    XCTAssertFalse(String(describing: original).contains("secret"))
    XCTAssertFalse(String(reflecting: original).contains("secret"))
  }

  func testOfflineOriginalKnowsWhenTheEngineCannotDecodeIt() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(
      #"{"file":{"id":412,"parent_id":0,"name":"Movie.mov","file_type":"VIDEO","size":10,"created_at":"2026-08-28T10:00:00Z","updated_at":"2026-08-29T10:00:00Z","media_info":{"format":{"name":"mov,mp4,m4a,3gp,3g2,mj2"},"streams":[{"codec_type":"video","codec_name":"prores"}],"playback_issues":[]}}}"#,
      for: "GET /v2/files/412")
    fixtures.setFixture(#"{"subtitles":[]}"#, for: "GET /v2/files/412/subtitles")

    let original = try await runtime.resolveOfflineOriginal(fileID: PutioFileID(rawValue: 412))

    XCTAssertFalse(original.enginePlays)
  }

  func testOfflineOriginalRejectsAnythingButAVideo() async {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(
      #"{"file":{"id":440,"parent_id":7,"name":"Poster.png","file_type":"IMAGE","size":10,"created_at":"2026-08-28T10:00:00Z","updated_at":"2026-08-29T10:00:00Z"}}"#,
      for: "GET /v2/files/440")

    await assertRuntimeError(.invalidResponse) {
      _ = try await runtime.resolveOfflineOriginal(fileID: PutioFileID(rawValue: 440))
    }
  }
}
