import PutioCore
import XCTest

@testable import Putio

@MainActor
final class PutioCastReceiverTests: XCTestCase {
  func testCustomDataMatchesSharedGoldenFixtures() throws {
    let cases:
      [(
        name: String,
        url: String,
        startSeconds: Int,
        token: String,
        method: PutioGoogleCastController.PutioCastLoad.Method
      )] = [
        (
          "minimal", "https://api.put.io/v2/files/42/hls/media.m3u8?oauth_token=download-token", 0,
          "download-token", .hls
        ),
        (
          "hls-with-position",
          "https://api.put.io/v2/files/42/hls/media.m3u8?oauth_token=download-token", 90,
          "download-token", .hls
        ),
        (
          "file-method", "https://api.put.io/v2/files/42/hls/media.m3u8?oauth_token=download-token",
          0, "download-token", .file
        ),
        (
          "subtitle-languages",
          "https://api.put.io/v2/files/42/hls/media.m3u8?oauth_token=download-token&subtitle_languages=eng,tur",
          0, "download-token", .hls
        ),
        (
          "subtitle-max-count-zero",
          "https://api.put.io/v2/files/42/hls/media.m3u8?oauth_token=download-token&max_subtitle_count=0",
          0, "download-token", .hls
        ),
        (
          "public-share-token",
          "https://api.put.io/v2/files/42/hls/media.m3u8?oauth_token=public-share-token", 0,
          "public-share-token", .hls
        ),
      ]

    for testCase in cases {
      let media = PutioCastMedia(
        id: PutioFileID(rawValue: 42),
        parentID: PutioFileID(rawValue: 0),
        title: "Episode",
        url: URL(string: testCase.url)!,
        artworkURL: nil,
        durationSeconds: 600,
        startFromSeconds: testCase.startSeconds,
        downloadToken: testCase.token)
      let load = try XCTUnwrap(
        PutioGoogleCastController.putioReceiverLoad(
          for: media,
          startSeconds: testCase.startSeconds,
          onPutioReceiver: true,
          method: testCase.method))
      let fixtureURL = try fixtureURL(named: testCase.name)
      let fixtureData = try Data(contentsOf: fixtureURL)
      let fixtureObject = try XCTUnwrap(
        try JSONSerialization.jsonObject(with: fixtureData) as? NSDictionary)
      let canonicalFixture = try JSONSerialization.data(
        withJSONObject: fixtureObject, options: .sortedKeys)
      let actualData = try JSONSerialization.data(withJSONObject: load, options: .sortedKeys)
      XCTAssertEqual(
        String(decoding: actualData, as: UTF8.self),
        String(decoding: canonicalFixture, as: UTF8.self),
        testCase.name)
      XCTAssertEqual(load as NSDictionary, fixtureObject, testCase.name)
    }
  }

  func testInvalidSubtitleFiltersAndNonPositiveFileIDsAreOmittedOrRejected() throws {
    let invalidFilterMedia = PutioCastMedia(
      id: PutioFileID(rawValue: 42),
      parentID: PutioFileID(rawValue: 0),
      title: "Episode",
      url: URL(
        string:
          "https://api.put.io/v2/files/42/hls/media.m3u8?max_subtitle_count=-1&subtitle_languages=en"
      )!,
      artworkURL: nil,
      durationSeconds: 600,
      startFromSeconds: 0,
      downloadToken: "download-token")
    let load = try XCTUnwrap(
      PutioGoogleCastController.putioReceiverLoad(
        for: invalidFilterMedia, startSeconds: 0, onPutioReceiver: true))
    XCTAssertNil(load["maxSubtitleCount"])
    XCTAssertNil(load["subtitleLanguages"])

    let invalidFileMedia = PutioCastMedia(
      id: PutioFileID(rawValue: 0),
      parentID: PutioFileID(rawValue: 0),
      title: "Episode",
      url: URL(string: "https://api.put.io/v2/files/0/hls/media.m3u8")!,
      artworkURL: nil,
      durationSeconds: 600,
      startFromSeconds: 0,
      downloadToken: "download-token")
    XCTAssertNil(
      PutioGoogleCastController.putioReceiverLoad(
        for: invalidFileMedia, startSeconds: 0, onPutioReceiver: true))
  }

  private func fixtureURL(named name: String) throws -> URL {
    let bundle = Bundle(for: Self.self)
    if let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") {
      return url
    }
    return try XCTUnwrap(bundle.url(forResource: name, withExtension: "json"))
  }
}
