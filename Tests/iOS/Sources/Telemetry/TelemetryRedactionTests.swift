import XCTest

@testable import Putio

/// Synthetic placeholders only; never paste real events, URLs, or filenames.
enum SyntheticTelemetry {
  static let token = "synthetic-token-5f1c9e"
  static let signature = "synthetic-sig-2b7d40"
  static let title = "Synthetic Feature Title"
  static let fileName = "Synthetic.Feature.Title.2001.mkv"
  static let signedURL =
    "https://media.example.invalid/hls/\(fileName)/master.m3u8?oauth_token=\(token)&signature=\(signature)"
  static let filePath = "/var/mobile/Containers/Data/Application/Documents/\(fileName)"

  /// Substrings no sent field may contain.
  static let leaks = [
    token, signature, title, fileName, "Synthetic.Feature", "/hls/", "://media.example.invalid",
    "Documents/",
  ]
}

final class TelemetryRedactionTests: XCTestCase {
  func testScrubKeepsOnlyTheHostOfURLs() {
    XCTAssertEqual(
      TelemetryRedaction.scrub("Playback failed for \(SyntheticTelemetry.signedURL) twice"),
      "Playback failed for [url:media.example.invalid] twice"
    )
    XCTAssertEqual(
      TelemetryRedaction.scrub("file://\(SyntheticTelemetry.filePath)"), TelemetryRedaction.path)
    XCTAssertEqual(
      TelemetryRedaction.scrub("https://user:pass@example.invalid"), "[url:example.invalid]")
  }

  func testScrubRemovesCredentialsPathsAndMediaFilenames() {
    let token = SyntheticTelemetry.token
    XCTAssertEqual(
      TelemetryRedaction.scrub("Authorization: Bearer \(token)"),
      "Authorization: [redacted] [redacted]")
    XCTAssertEqual(
      TelemetryRedaction.scrub("?oauth_token=\(token)&page=2"), "?oauth_token=[redacted]&page=2")
    XCTAssertEqual(
      TelemetryRedaction.scrub(#"{"password": "\#(token)"}"#), #"{"password": [redacted]}"#)
    XCTAssertEqual(
      TelemetryRedaction.scrub("Cannot delete \(SyntheticTelemetry.filePath)"),
      "Cannot delete [path]")
    XCTAssertEqual(
      TelemetryRedaction.scrub("Opened \(SyntheticTelemetry.fileName) twice"), "Opened [file] twice"
    )
    XCTAssertEqual(
      TelemetryRedaction.scrub("NSURLErrorDomain Code: -1001"), "NSURLErrorDomain Code: -1001")
  }

  func testScrubValueRedactsSensitiveKeysAtAnyDepth() throws {
    let scrubbed = TelemetryRedaction.scrub([
      "player": "avplayer",
      "status_code": 403,
      "nested": [
        "title": SyntheticTelemetry.title,
        "items": [["file_name": SyntheticTelemetry.fileName, "url": SyntheticTelemetry.signedURL]],
      ],
      "object": NSObject(),
    ])

    XCTAssertEqual(scrubbed["player"] as? String, "avplayer")
    XCTAssertEqual(scrubbed["status_code"] as? Int, 403)
    XCTAssertEqual(scrubbed["object"] as? String, TelemetryRedaction.redacted)
    let nested = try XCTUnwrap(scrubbed["nested"] as? [String: Any])
    XCTAssertEqual(nested["title"] as? String, TelemetryRedaction.redacted)
    let item = try XCTUnwrap((nested["items"] as? [[String: Any]])?.first)
    XCTAssertEqual(item["file_name"] as? String, TelemetryRedaction.redacted)
    XCTAssertEqual(item["url"] as? String, "[url:media.example.invalid]")
  }

  func testFailuresGroupByCategoryNotByErrorText() {
    func playbackFailure(url: String) -> TelemetryFailure {
      let error = NSError(
        domain: "AVFoundationErrorDomain", code: -11800,
        userInfo: [
          NSLocalizedDescriptionKey: "Could not open \(SyntheticTelemetry.title)",
          NSURLErrorFailingURLErrorKey: URL(string: url) as Any,
        ])
      return TelemetryFailure(
        .playback, error: error, context: [.player: "avplayer", .platform: "ios"])
    }

    let first = playbackFailure(url: SyntheticTelemetry.signedURL)
    let second = playbackFailure(
      url: SyntheticTelemetry.signedURL.replacingOccurrences(of: "master", with: "other"))

    XCTAssertEqual(first, second)
    XCTAssertEqual(first.fingerprint, ["playback", "AVFoundationErrorDomain", "-11800"])
    XCTAssertEqual(
      first.tags,
      [
        "category": "playback",
        "error_domain": "AVFoundationErrorDomain",
        "error_code": "-11800",
        "player": "avplayer",
        "platform": "ios",
      ])
  }
}
