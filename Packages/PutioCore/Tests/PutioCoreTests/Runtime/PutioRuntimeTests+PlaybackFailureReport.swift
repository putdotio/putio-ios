import AVFoundation
import Foundation
import XCTest

@testable import PutioCore

/// Expected tags come from the "Playback failure reports" contract, schema 2.
extension PutioRuntimeTests {
  private static let reportRoute = "GET /v2/files/411"
  private static let reportFileID = PutioFileID(rawValue: 411)

  private static let contractTags: Set<String> = [
    "telemetry_event", "schema_version", "platform", "player", "playback_outcome",
    "playback_terminal", "playback_started", "failure_mode", "streaming_method", "source_kind",
    "device_check", "rescue_reason", "rescue_to", "engine_error_domain", "engine_error_category",
    "engine_error_code", "source_request_status", "file_id", "container_family", "video_codec",
    "video_profile", "video_level", "video_bit_depth", "video_resolution", "video_hdr",
    "audio_codec", "audio_channels",
  ]

  private static func reportFile(mp4Available: Bool) -> String {
    """
    {"file": {"id": 411, "name": "Movie.mkv", "file_type": "VIDEO", "parent_id": 0,
    "need_convert": false, "is_mp4_available": \(mp4Available), "start_from": 0,
    "media_info": {"mime_type": "video/x-matroska", "format": {"name": "matroska,webm"},
    "streams": [
    {"codec_type": "audio", "codec_name": "eac3", "channels": 6},
    {"codec_type": "video", "codec_name": "hevc", "profile": "Main 10", "level": 153,
     "width": 3840, "height": 2160},
    {"codec_type": "audio", "codec_name": "dts", "channels": 8}],
    "playback_issues": []}}}
    """
  }

  private func directPlayModel(_ runtime: PutioRuntime) -> PutioVideoPlaybackModel {
    PutioVideoPlaybackModel(
      fileID: Self.reportFileID,
      resolveConverted: {
        try await runtime.resolveVideoPlayback(
          fileID: $0, method: .directPlay, playsConverted: true,
          isPlayableInAVPlayer: { _ in false })
      },
      resolve: {
        try await runtime.resolveVideoPlayback(
          fileID: $0, method: .directPlay, isPlayableInAVPlayer: { _ in false })
      })
  }

  func testAnOriginalTheEngineCannotDecodeIsReportedAsARescueToTheConvertedCopy() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(Self.reportFile(mp4Available: true), for: Self.reportRoute)
    fixtures.setFixture(#"{"default":"en","subtitles":[]}"#, for: "GET /v2/files/411/subtitles")
    let model = directPlayModel(runtime)
    await model.loadIfNeeded()
    let decode = PutioPlayerError(aetherKind: "softwarePipelineFailed", domain: nil, code: nil)

    let report = try XCTUnwrap(
      model.failureReport(decode, beforeFirstFrame: true, platform: .ios))

    XCTAssertEqual(Set(report.tags.keys), Self.contractTags)
    XCTAssertEqual(
      report.tags,
      [
        "telemetry_event": "playback_failure", "schema_version": "2", "platform": "ios",
        "player": "aether", "playback_outcome": "rescued", "playback_terminal": "false",
        "playback_started": "false", "failure_mode": "decode", "streaming_method": "file",
        "source_kind": "original", "device_check": "pass", "rescue_reason": "decoder_error",
        "rescue_to": "converted", "engine_error_domain": "none",
        "engine_error_category": "softwarePipelineFailed", "engine_error_code": "none",
        "source_request_status": "none", "file_id": "411", "container_family": "matroska",
        "video_codec": "hevc", "video_profile": "main 10", "video_level": "153",
        "video_bit_depth": "unknown", "video_resolution": "3840x2160", "video_hdr": "unknown",
        "audio_codec": "eac3", "audio_channels": "6",
      ])
    XCTAssertEqual(report.message, "playback rescued: decoder_error")
    XCTAssertEqual(report.fingerprint, ["ios", "rescued", "decoder_error", "none"])

    await model.playerFailed(decode.fault, heldSeconds: nil, beforeFirstFrame: true)
    let converted = try XCTUnwrap(
      model.failureReport(
        PutioPlayerError(
          avPlayerError: NSError(
            domain: AVFoundationErrorDomain, code: AVError.Code.decodeFailed.rawValue)),
        beforeFirstFrame: false, platform: .ios))

    XCTAssertEqual(converted.tags["playback_outcome"], "failed")
    XCTAssertEqual(converted.tags["playback_terminal"], "true")
    XCTAssertEqual(converted.tags["playback_started"], "true")
    XCTAssertEqual(converted.tags["player"], "avplayer")
    XCTAssertEqual(converted.tags["source_kind"], "converted")
    XCTAssertEqual(converted.tags["device_check"], "skipped")
    XCTAssertEqual(converted.tags["streaming_method"], "file")
    XCTAssertEqual(converted.tags["rescue_reason"], "none")
    XCTAssertEqual(converted.tags["engine_error_domain"], AVFoundationErrorDomain)
    XCTAssertEqual(converted.tags["engine_error_code"], "-11821")
    XCTAssertEqual(converted.tags["video_codec"], "hevc", "media facts describe the original")
    XCTAssertEqual(converted.message, "playback failed: decode")
  }

  func testAStandardStreamReportsHLSWithNoDeviceCheckOrMediaFacts() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(
      #"{"file": {"id": 411, "file_type": "VIDEO", "need_convert": false, "start_from": 0}}"#,
      for: Self.reportRoute)
    let model = PutioVideoPlaybackModel(fileID: Self.reportFileID) {
      try await runtime.resolveVideoPlayback(
        fileID: $0, method: .standard, isPlayableInAVPlayer: { _ in true })
    }
    await model.loadIfNeeded()

    let report = try XCTUnwrap(
      model.failureReport(
        PutioPlayerError(
          avPlayerError: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)),
        beforeFirstFrame: true, platform: .ios))

    XCTAssertEqual(report.tags["streaming_method"], "hls")
    XCTAssertEqual(report.tags["source_kind"], "hls")
    XCTAssertEqual(report.tags["device_check"], "skipped")
    XCTAssertEqual(report.tags["failure_mode"], "network")
    XCTAssertEqual(report.tags["container_family"], "unknown")
    XCTAssertEqual(report.tags["video_codec"], "unknown")
  }

  func testAnExpiredStreamThatRetriesSilentlyIsNoReportUntilTheRetryFails() async throws {
    let source = PutioPlaybackSource(
      url: URL(string: "https://api.example.test/v2/files/411/hls/media.m3u8")!,
      startFromSeconds: 0)
    let model = PutioVideoPlaybackModel(fileID: Self.reportFileID) { _ in .ready(source) }
    await model.loadIfNeeded()
    let forbidden = PutioPlayerError(
      avPlayerError: NSError(
        domain: AVFoundationErrorDomain, code: AVError.Code.unknown.rawValue,
        userInfo: [
          NSUnderlyingErrorKey: NSError(domain: "CoreMediaErrorDomain", code: -12660)
        ]))

    XCTAssertNil(model.failureReport(forbidden, beforeFirstFrame: true, platform: .ios))
    let refreshed = await model.playerFailed(
      forbidden.fault, heldSeconds: nil, beforeFirstFrame: true)
    XCTAssertNil(refreshed, "the refresh played again")
    let report = try XCTUnwrap(
      model.failureReport(forbidden, beforeFirstFrame: true, platform: .ios))

    XCTAssertEqual(report.tags["playback_outcome"], "failed")
    XCTAssertEqual(report.tags["engine_error_domain"], "CoreMediaErrorDomain")
    XCTAssertEqual(report.tags["engine_error_code"], "-12660")
    XCTAssertEqual(report.tags["source_request_status"], "403")
    XCTAssertEqual(report.tags["source_kind"], "unknown")
  }

  func testAnExpiredStreamWhoseRefreshCannotResolveIsReportedWhenPlaybackEnds() async throws {
    let source = PutioPlaybackSource(
      url: URL(string: "https://api.example.test/v2/files/411/hls/media.m3u8")!,
      startFromSeconds: 0)
    var resolutions = 0
    let model = PutioVideoPlaybackModel(fileID: Self.reportFileID) { _ in
      resolutions += 1
      guard resolutions == 1 else { throw PutioRuntimeError.notFound }
      return .ready(source)
    }
    await model.loadIfNeeded()
    let forbidden = PutioPlayerError(
      avPlayerError: NSError(domain: "CoreMediaErrorDomain", code: -12660))

    XCTAssertNil(model.failureReport(forbidden, beforeFirstFrame: true, platform: .ios))
    let report = await model.playerFailed(
      forbidden.fault, heldSeconds: nil, beforeFirstFrame: true)

    XCTAssertEqual(model.state, .failed(.resolving(PutioRuntimeError.notFound)!))
    XCTAssertEqual(report?.tags["playback_outcome"], "failed")
    XCTAssertEqual(report?.tags["source_request_status"], "403")
  }

  func testADefinitiveSourceStatusOutranksTheEngineCode() {
    let modes: [Int: String] = [
      404: "source_gone", 410: "source_gone", 402: "entitlement", 429: "throttled",
      408: "server_transient", 500: "server_transient", 503: "server_transient",
    ]
    for (status, mode) in modes {
      let error = PutioPlayerError(
        aetherKind: "sourceRefused", domain: nil, code: status)
      XCTAssertEqual(error.mode.rawValue, mode, "HTTP \(status)")
      XCTAssertEqual(error.requestStatus, status)
    }
  }

  func testAVFoundationErrorsMapOntoTheContractsFailureModes() {
    let modes: [(AVError.Code, PutioPlaybackFailureMode)] = [
      (.decodeFailed, .decode), (.decoderNotFound, .decode),
      (.decoderTemporarilyUnavailable, .decode), (.undecodableMediaData, .decode),
      (.fileFormatNotRecognized, .unsupportedSource), (.fileFailedToParse, .unsupportedSource),
      (.invalidSourceMedia, .unsupportedSource), (.failedToParse, .unsupportedSource),
      (.incompatibleAsset, .unsupportedSource),
      (.operationNotSupportedForAsset, .unsupportedSource),
      (.contentIsProtected, .drm), (.contentIsNotAuthorized, .drm),
      (.applicationIsNotAuthorized, .drm), (.failedToLoadMediaData, .load),
      (.serverIncorrectlyConfigured, .load), (.unknown, .unknown),
    ]
    for (code, mode) in modes {
      let error = PutioPlayerError(
        avPlayerError: NSError(domain: AVFoundationErrorDomain, code: code.rawValue))
      XCTAssertEqual(error.mode, mode, "AVError \(code.rawValue)")
    }
    XCTAssertEqual(
      PutioPlayerError(
        avPlayerError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
      ).mode, .aborted)
    XCTAssertEqual(PutioPlayerError(avPlayerError: nil).mode, .unknown)
  }

  func testContainerFamiliesFollowTheOriginalsFormat() {
    let families: [(String?, String?, String)] = [
      ("matroska,webm", "video/x-matroska", "matroska"),
      ("matroska,webm", "video/webm", "webm"),
      ("mov,mp4,m4a,3gp,3g2,mj2", "video/mp4", "mp4"),
      ("avi", nil, "avi"),
      ("mpegts", nil, "mpeg-ts"),
      ("ogg", nil, "ogg"),
      ("flv", nil, "other"),
      (nil, nil, "unknown"),
    ]
    for (format, mime, family) in families {
      XCTAssertEqual(
        PutioPlaybackMedia.containerFamily(format: format, mimeType: mime), family,
        format ?? "nil")
    }
  }
}
