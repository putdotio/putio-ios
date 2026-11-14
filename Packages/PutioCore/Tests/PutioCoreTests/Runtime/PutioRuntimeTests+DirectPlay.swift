import Foundation
import XCTest

@testable import PutioCore

extension PutioRuntimeTests {
  private static let directPlayRoute = "GET /v2/files/411"
  private static let directPlaySubtitlesRoute = "GET /v2/files/411/subtitles"

  private static func directPlayFile(
    mediaInfo: String?, needConvert: Bool = false, mp4Available: Bool = false
  ) -> String {
    """
    {"file": {"id": 411, "name": "Movie.mkv", "file_type": "VIDEO", "parent_id": 0,
    "need_convert": \(needConvert), "is_mp4_available": \(mp4Available), "start_from": 42
    \(mediaInfo.map { #", "media_info": \#($0)"# } ?? "")}}
    """
  }

  private static let matroska = """
    {"mime_type": "video/x-matroska", "format": {"name": "matroska,webm"},
    "streams": [
    {"codec_type": "video", "codec_name": "hevc"},
    {"codec_type": "audio", "codec_name": "eac3", "channels": 6},
    {"codec_type": "audio", "codec_name": "dts", "profile": "DTS-HD MA", "channels": 8}],
    "playback_issues": []}
    """

  private func resolveDirectPlay(
    _ runtime: PutioRuntime, playable: @escaping @Sendable (String) -> Bool = { _ in true }
  ) async throws -> PutioPlaybackResolution {
    try await runtime.resolveVideoPlayback(
      fileID: PutioFileID(rawValue: 411), method: .directPlay, isPlayableInAVPlayer: playable)
  }

  private func query(_ url: URL?) -> [String: String] {
    let items = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems
    return Dictionary(
      (items ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
  }

  func testDirectPlayStreamsAMatroskaOriginalInTheEngineWithTokenedSubtitleFiles() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(Self.directPlayFile(mediaInfo: Self.matroska), for: Self.directPlayRoute)
    fixtures.setFixture(
      """
      {"default":"tr","subtitles":[
        {"key":"en","language":"English","language_code":"eng","name":"English.srt","source":"opensubtitles","url":"https://api.put.io/v2/files/411/subtitles/en"},
        {"key":"tr","language":"Turkish","language_code":"tur","name":"Turkish.srt","source":"opensubtitles","url":"https://api.put.io/v2/files/411/subtitles/tr"},
        {"key":"x","language":"Elsewhere","language_code":"und","name":"x.srt","source":"opensubtitles","url":"https://example.com/x.srt"}
      ]}
      """,
      for: Self.directPlaySubtitlesRoute)

    guard case .ready(let source) = try await resolveDirectPlay(runtime) else {
      return XCTFail("expected the original")
    }

    XCTAssertEqual(source.url.path, "/v2/files/411/stream")
    XCTAssertEqual(query(source.url), ["oauth_token": "account-download-secret"])
    XCTAssertEqual(source.startFromSeconds, 42)
    let original = try XCTUnwrap(source.original)
    XCTAssertEqual(original.player, .engine)
    XCTAssertEqual(
      original.audioStreams,
      [
        PutioOriginalAudioStream(codec: "eac3", channels: 6),
        PutioOriginalAudioStream(codec: "dts", profile: "DTS-HD MA", channels: 8),
      ])
    XCTAssertEqual(original.subtitles.map(\.key), ["en", "tr"])
    XCTAssertEqual(
      original.subtitles.map { query($0.url) },
      Array(repeating: ["oauth_token": "account-download-secret", "format": "webvtt"], count: 2))
    XCTAssertEqual(original.defaultSubtitleKey, "tr")
    let fileRequest = try XCTUnwrap(
      fixtures.capturedRequests().first { $0.url?.path == "/v2/files/411" })
    XCTAssertEqual(query(fileRequest.url)["media_info"], "1")
    XCTAssertFalse(
      fixtures.capturedRequests().contains { query($0.url)["original"] != nil },
      "a client never sends original=1")
    XCTAssertFalse(String(reflecting: source).contains("account-download-secret"))
  }

  func testDirectPlayHandsAnMP4OriginalAVPlayerDecodesToAVPlayer() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(
      Self.directPlayFile(
        mediaInfo: """
          {"mime_type": "video/mp4", "format": {"name": "mov,mp4,m4a,3gp,3g2,mj2"},
          "streams": [
          {"codec_type": "video", "codec_name": "h264", "rfc6381_codec": "avc1.64001f"},
          {"codec_type": "audio", "codec_name": "aac", "rfc6381_codec": "mp4a.40.2", "channels": 2}],
          "playback_issues": []}
          """),
      for: Self.directPlayRoute)
    let asked = LockedValues()

    let resolution = try await resolveDirectPlay(runtime) { type in
      asked.append(type)
      return true
    }

    guard case .ready(let source) = resolution else { return XCTFail("expected the original") }
    XCTAssertEqual(source.url.path, "/v2/files/411/stream")
    XCTAssertEqual(source.original?.player, .avPlayer)
    XCTAssertEqual(source.original?.subtitles, [])
    XCTAssertEqual(asked.values, [#"video/mp4; codecs="avc1.64001f,mp4a.40.2""#])
    XCTAssertFalse(fixtures.capturedRequests().contains { $0.url?.path.hasSuffix("/subtitles") == true })
  }

  func testDirectPlayPlaysTheConvertedCopyWhenTheEngineCannotDecodeTheVideo() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(
      Self.directPlayFile(
        mediaInfo: """
          {"format": {"name": "mov,mp4,m4a,3gp,3g2,mj2"},
          "streams": [{"codec_type": "video", "codec_name": "prores"}], "playback_issues": []}
          """,
        mp4Available: true),
      for: Self.directPlayRoute)

    guard case .ready(let source) = try await resolveDirectPlay(runtime) else {
      return XCTFail("expected the converted copy")
    }

    XCTAssertEqual(source.url.path, "/v2/files/411/mp4/stream")
    XCTAssertNil(source.original)
  }

  func testDirectPlayConvertsAnOriginalWithoutMediaInfoAndNoConvertedCopy() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(
      Self.directPlayFile(mediaInfo: nil, needConvert: true), for: Self.directPlayRoute)

    let resolution = try await resolveDirectPlay(runtime)

    XCTAssertEqual(resolution, .conversionRequired)
  }

  func testDirectPlayReportsAFlaggedOriginalWithNothingElseToPlay() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(
      Self.directPlayFile(
        mediaInfo: """
          {"format": {"name": "matroska,webm"},
          "streams": [{"codec_type": "video", "codec_name": "h264"}],
          "playback_issues": ["open_gop"]}
          """),
      for: Self.directPlayRoute)

    do {
      _ = try await resolveDirectPlay(runtime)
      XCTFail("expected the original to be unplayable")
    } catch let error as PutioPlaybackUnplayable {
      XCTAssertEqual(error.reason, "playback_issue")
    }
  }

  func testStandardStaysOnHLSWithoutAskingForMediaInfo() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(Self.directPlayFile(mediaInfo: Self.matroska), for: Self.directPlayRoute)

    let resolution = try await runtime.resolveVideoPlayback(
      fileID: PutioFileID(rawValue: 411), method: .standard, isPlayableInAVPlayer: { _ in true })

    guard case .ready(let source) = resolution else { return XCTFail("expected HLS") }
    XCTAssertEqual(source.url.path, "/v2/files/411/hls/media.m3u8")
    XCTAssertNil(source.original)
    XCTAssertFalse(fixtures.capturedRequests().contains { query($0.url)["media_info"] != nil })
  }
}

private final class LockedValues: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [String] = []

  var values: [String] { lock.withLock { stored } }

  func append(_ value: String) {
    lock.withLock { stored.append(value) }
  }
}
