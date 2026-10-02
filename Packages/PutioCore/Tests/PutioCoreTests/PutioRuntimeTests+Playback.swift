import Foundation
import XCTest

@testable import PutioCore

extension PutioRuntimeTests {
  private static let nextVideoRoute = "GET /v2/files/411/next-file"
  private static let playbackRoute = "GET /v2/files/411"
  private static let playbackPositionRoute = "POST /v2/files/411/start-from/set"
  private static let conversionStartRoute = "POST /v2/files/411/mp4"
  private static let conversionStatusRoute = "GET /v2/files/411/mp4"

  func testFindNextVideoMapsAppOwnedSuccessorAndVideoQuery() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(
      """
      {
        "next_file": {
          "id": 412,
          "name": "Episode 2.mkv",
          "parent_id": 7,
          "file_type": "VIDEO"
        }
      }
      """,
      for: Self.nextVideoRoute
    )

    let nextVideo = try await runtime.findNextVideo(
      after: PutioFileID(rawValue: 411)
    )

    XCTAssertEqual(
      nextVideo,
      PutioNextVideo(
        id: PutioFileID(rawValue: 412),
        parentID: PutioFileID(rawValue: 7),
        name: "Episode 2.mkv"
      )
    )
    let request = try XCTUnwrap(fixtures.capturedRequests().last)
    XCTAssertEqual(request.url?.path, "/v2/files/411/next-file")
    let components = try XCTUnwrap(
      request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
    )
    XCTAssertEqual(
      components.queryItems?.first(where: { $0.name == "file_type" })?.value,
      "VIDEO"
    )
  }

  func testFindNextVideoMapsNullSuccessorToNil() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(
      #"{"next_file":null}"#,
      for: Self.nextVideoRoute
    )

    let nextVideo = try await runtime.findNextVideo(
      after: PutioFileID(rawValue: 411)
    )

    XCTAssertNil(nextVideo)
  }

  func testFindNextVideoRejectsMissingSuccessorField() async {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture("{}", for: Self.nextVideoRoute)

    await assertRuntimeError(.invalidResponse) {
      _ = try await runtime.findNextVideo(after: PutioFileID(rawValue: 411))
    }
  }

  func testUnauthenticatedRuntimeRejectsNextVideoWithoutARequest() async {
    let (runtime, _) = makeRuntime(token: nil)

    await assertRuntimeError(.authenticationRequired) {
      _ = try await runtime.findNextVideo(after: PutioFileID(rawValue: 411))
    }

    XCTAssertTrue(fixtures.capturedRequests().isEmpty)
  }

  func testFindNextVideoCancellationPreservesSignedInSessionAndToken() async {
    let (runtime, tokenStore) = await makeSignedInRuntime()
    fixtures.suspend(Self.nextVideoRoute)

    let task = Task {
      try await runtime.findNextVideo(after: PutioFileID(rawValue: 411))
    }
    guard await waitForRequest(Self.nextVideoRoute) else {
      task.cancel()
      return XCTFail("next-video request did not start")
    }
    task.cancel()

    do {
      _ = try await task.value
      XCTFail("expected cancellation")
    } catch is CancellationError {
    } catch {
      XCTFail("expected CancellationError, got \(error)")
    }

    guard case .signedIn = runtime.session.state else {
      return XCTFail("cancellation must preserve the signed-in session")
    }
    XCTAssertEqual(try? tokenStore.read(), "stored-token")
  }

  func testUnauthenticatedRuntimeRejectsPlaybackResolutionWithoutARequest() async {
    let (runtime, _) = makeRuntime(token: nil)

    await assertRuntimeError(.authenticationRequired) {
      _ = try await runtime.resolveVideoPlaybackSource(fileID: PutioFileID(rawValue: 411))
    }

    XCTAssertTrue(fixtures.capturedRequests().isEmpty)
  }

  func testPlaybackResolutionMapsReadySourceWithoutReflectingItsToken() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(
      Self.playbackFile(needConvert: false, startFrom: 90),
      for: Self.playbackRoute
    )

    let resolution = try await runtime.resolveVideoPlaybackSource(
      fileID: PutioFileID(rawValue: 411)
    )

    guard case .ready(let source) = resolution else {
      return XCTFail("expected ready playback source")
    }
    XCTAssertEqual(source.startFromSeconds, 90)
    XCTAssertEqual(source.url.path, "/v2/files/411/hls/media.m3u8")
    XCTAssertEqual(
      URLComponents(url: source.url, resolvingAgainstBaseURL: false)?
        .queryItems?.first(where: { $0.name == "oauth_token" })?.value,
      "account-download-secret"
    )
    XCTAssertFalse(String(describing: source).contains("stored-token"))
    XCTAssertFalse(String(reflecting: source).contains("stored-token"))
  }

  func testPlaybackResolutionPreservesConversionRequired() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(
      Self.playbackFile(needConvert: true, startFrom: 0),
      for: Self.playbackRoute
    )

    let resolution = try await runtime.resolveVideoPlaybackSource(
      fileID: PutioFileID(rawValue: 411)
    )

    XCTAssertEqual(resolution, .conversionRequired)
  }

  func testVideoConversionStartSendsTheSDKOwnedRequest() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(#"{"status":"OK"}"#, for: Self.conversionStartRoute)

    try await runtime.startVideoConversion(fileID: PutioFileID(rawValue: 411))

    let request = try XCTUnwrap(fixtures.capturedRequests().last)
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.url?.path, "/v2/files/411/mp4")
  }

  func testAudioPlaybackSourceMapsStreamURLAndPositionThroughTheSDK() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(
      #"{"file":{"id":430,"file_type":"AUDIO","start_from":45}}"#, for: "GET /v2/files/430")

    let source = try await runtime.resolveAudioPlaybackSource(fileID: PutioFileID(rawValue: 430))

    XCTAssertEqual(source.url.path, "/v2/files/430/stream")
    XCTAssertEqual(
      URLComponents(url: source.url, resolvingAgainstBaseURL: false)?.queryItems?
        .filter { $0.name == "oauth_token" }.map(\.value),
      ["account-download-secret"])
    XCTAssertEqual(source.startFromSeconds, 45)
    XCTAssertFalse(String(describing: source).contains("stored-token"))
  }

  func testAudioPlaybackSourceRejectsNonAudioAsUnknown() async {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(
      Self.playbackFile(needConvert: false, startFrom: 0), for: Self.playbackRoute)

    await assertRuntimeError(.unknown) {
      _ = try await runtime.resolveAudioPlaybackSource(fileID: PutioFileID(rawValue: 411))
    }
  }

  func testNextAudioUsesTheAudioFileTypeAndMapsTheSuccessor() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(
      #"{"next_file":{"id":431,"name":"Track 2.m4a","parent_id":7}}"#,
      for: "GET /v2/files/430/next-file")

    let next = try await runtime.findNextAudio(after: PutioFileID(rawValue: 430))

    XCTAssertEqual(
      next,
      PutioNextAudio(
        id: PutioFileID(rawValue: 431), parentID: PutioFileID(rawValue: 7), name: "Track 2.m4a"))
    let request = try XCTUnwrap(fixtures.capturedRequests().last)
    XCTAssertEqual(request.url?.query?.contains("file_type=AUDIO"), true)
  }

  func testVideoConversionStatusMapsEveryKnownSDKState() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    let cases: [(String, Int, PutioVideoConversionStatus)] = [
      ("IN_QUEUE", 0, .queued),
      ("CONVERTING", 35, .converting(progress: 0.35)),
      ("COMPLETED", 100, .completed),
      ("ERROR", 0, .failed),
      ("NOT_AVAILABLE", 0, .failed),
    ]

    for (status, percentDone, expected) in cases {
      fixtures.setFixture(
        #"{"mp4":{"percent_done":\#(percentDone),"status":"\#(status)"}}"#,
        for: Self.conversionStatusRoute
      )

      let conversion = try await runtime.videoConversionStatus(
        fileID: PutioFileID(rawValue: 411)
      )
      if case .converting(let progress) = conversion,
        case .converting(let expectedProgress) = expected
      {
        XCTAssertEqual(progress, expectedProgress, accuracy: 0.001)
      } else {
        XCTAssertEqual(conversion, expected)
      }
    }
  }

  func testVideoConversionTreatsUnknownStatusAsStillConverting() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(
      #"{"mp4":{"percent_done":35,"status":"PAUSED"}}"#, for: Self.conversionStatusRoute)

    let conversion = try await runtime.videoConversionStatus(fileID: PutioFileID(rawValue: 411))

    guard case .converting(let progress) = conversion else {
      return XCTFail("expected an in-progress state, got \(conversion)")
    }
    XCTAssertEqual(progress, 0.35, accuracy: 0.001)
  }

  func testVideoConversionTerminalRowsIgnoreProgress() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    for (status, expected) in [
      ("ERROR", PutioVideoConversionStatus.failed), ("NOT_AVAILABLE", .failed),
      ("COMPLETED", .completed), ("IN_QUEUE", .queued),
    ] {
      fixtures.setFixture(
        #"{"mp4":{"percent_done":-1,"status":"\#(status)"}}"#, for: Self.conversionStatusRoute)
      let conversion = try await runtime.videoConversionStatus(
        fileID: PutioFileID(rawValue: 411))
      XCTAssertEqual(conversion, expected)
    }
  }

  func testVideoConversionRejectsInvalidProgressWhileConverting() async {
    let (runtime, _) = await makeSignedInRuntime()
    for body in [
      #"{"mp4":{"percent_done":101,"status":"CONVERTING"}}"#,
      #"{"mp4":{"percent_done":-1,"status":"CONVERTING"}}"#,
    ] {
      fixtures.setFixture(body, for: Self.conversionStatusRoute)
      await assertRuntimeError(.invalidResponse) {
        _ = try await runtime.videoConversionStatus(fileID: PutioFileID(rawValue: 411))
      }
    }
  }

  func testUnauthenticatedRuntimeRejectsVideoConversionWithoutARequest() async {
    let (runtime, _) = makeRuntime(token: nil)

    await assertRuntimeError(.authenticationRequired) {
      try await runtime.startVideoConversion(fileID: PutioFileID(rawValue: 411))
    }
    await assertRuntimeError(.authenticationRequired) {
      _ = try await runtime.videoConversionStatus(fileID: PutioFileID(rawValue: 411))
    }

    XCTAssertTrue(fixtures.capturedRequests().isEmpty)
  }

  func testMediaAgnosticPlaybackPositionReportSharesTheStartFromRoute() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(#"{"status":"OK"}"#, for: Self.playbackPositionRoute)

    try await runtime.reportPlaybackPosition(fileID: PutioFileID(rawValue: 411), seconds: 42)

    let request = try XCTUnwrap(fixtures.capturedRequests().last)
    XCTAssertEqual(request.url?.path, "/v2/files/411/start-from/set")
  }

  func testPlaybackPositionReportSendsExactPathAndBody() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(#"{"status":"OK"}"#, for: Self.playbackPositionRoute)

    try await runtime.reportPlaybackPosition(
      fileID: PutioFileID(rawValue: 411),
      seconds: 91
    )

    let request = try XCTUnwrap(fixtures.capturedRequests().last)
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.url?.path, "/v2/files/411/start-from/set")
    let body = try XCTUnwrap(requestBodyData(for: request))
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Int])
    XCTAssertEqual(json, ["time": 91])
  }

  func testPlaybackPositionReportSettlesWhenTheAccountTurnedPositionsOff() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(
      #"{"status":"ERROR","error_type":"FEATURE_DISABLED","status_code":400}"#,
      statusCode: 400, for: Self.playbackPositionRoute)

    try await runtime.reportPlaybackPosition(fileID: PutioFileID(rawValue: 411), seconds: 42)

    fixtures.setFixture(
      #"{"status":"ERROR","error_type":"BAD_REQUEST","status_code":400}"#,
      statusCode: 400, for: Self.playbackPositionRoute)
    await assertRuntimeError(.unknown) {
      try await runtime.reportPlaybackPosition(fileID: PutioFileID(rawValue: 411), seconds: 42)
    }
  }

  func testUnauthenticatedRuntimeRejectsPlaybackPositionReportWithoutARequest() async {
    let (runtime, _) = makeRuntime(token: nil)

    await assertRuntimeError(.authenticationRequired) {
      try await runtime.reportPlaybackPosition(
        fileID: PutioFileID(rawValue: 411),
        seconds: 91
      )
    }

    XCTAssertTrue(fixtures.capturedRequests().isEmpty)
  }

  func testPlaybackPositionAuthenticationFailureExpiresSessionAndClearsToken() async {
    let (runtime, tokenStore) = await makeSignedInRuntime()
    fixtures.setFixture(
      #"{"status":"ERROR","error_type":"invalid_grant"}"#,
      statusCode: 401,
      for: Self.playbackPositionRoute
    )

    await assertRuntimeError(.sessionExpired) {
      try await runtime.reportPlaybackPosition(
        fileID: PutioFileID(rawValue: 411),
        seconds: 91
      )
    }

    XCTAssertEqual(runtime.session.state, .signedOut(.sessionExpired))
    XCTAssertNil(try? tokenStore.read())
  }

  func testPlaybackPositionCancellationPreservesSignedInSessionAndToken() async {
    let (runtime, tokenStore) = await makeSignedInRuntime()
    fixtures.suspend(Self.playbackPositionRoute)

    let task = Task {
      try await runtime.reportPlaybackPosition(
        fileID: PutioFileID(rawValue: 411),
        seconds: 91
      )
    }
    guard await waitForRequest(Self.playbackPositionRoute) else {
      task.cancel()
      return XCTFail("playback-position request did not start")
    }
    task.cancel()

    do {
      try await task.value
      XCTFail("expected cancellation")
    } catch is CancellationError {
    } catch {
      XCTFail("expected CancellationError, got \(error)")
    }

    guard case .signedIn = runtime.session.state else {
      return XCTFail("cancellation must preserve the signed-in session")
    }
    XCTAssertEqual(try? tokenStore.read(), "stored-token")
  }

  func testPlaybackAuthenticationFailureExpiresSessionAndClearsToken() async {
    let (runtime, tokenStore) = await makeSignedInRuntime()
    fixtures.setFixture(
      #"{"status":"ERROR","error_type":"invalid_grant"}"#,
      statusCode: 401,
      for: Self.playbackRoute
    )

    await assertRuntimeError(.sessionExpired) {
      _ = try await runtime.resolveVideoPlaybackSource(fileID: PutioFileID(rawValue: 411))
    }

    XCTAssertEqual(runtime.session.state, .signedOut(.sessionExpired))
    XCTAssertNil(try? tokenStore.read())
  }

  func testCastPlaybackTypeRoundTripsThroughTheConfigEndpoints() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(
      #"{"config":{"chromecast_playback_type":"mp4"}}"#, for: "GET /v2/config")
    let type = try await runtime.castPlaybackType()
    XCTAssertEqual(type, .mp4)
    fixtures.setFixture(#"{"config":{}}"#, for: "GET /v2/config")
    let fallback = try await runtime.castPlaybackType()
    XCTAssertEqual(fallback, .hls)
    fixtures.setFixture(
      #"{"config":{"chromecast_playback_type":"bogus","autoplay_next_video":"yes","web_only":1}}"#,
      for: "GET /v2/config")
    let lenient = try await runtime.appConfig()
    XCTAssertEqual(lenient, PutioAppConfig(chromecastPlaybackType: .hls, autoplayNextVideo: false))
    fixtures.setFixture(
      #"{"config":{"chromecast_playback_type":"mp4","autoplay_next_video":true}}"#,
      for: "GET /v2/config")
    let full = try await runtime.appConfig()
    XCTAssertEqual(full, PutioAppConfig(chromecastPlaybackType: .mp4, autoplayNextVideo: true))
    fixtures.setFixture(
      #"{"status":"OK"}"#, for: "PUT /v2/config/autoplay_next_video")
    try await runtime.setAutoplayNextVideo(true)
    let autoplay = try XCTUnwrap(
      fixtures.capturedRequests().last {
        $0.url?.path == "/v2/config/autoplay_next_video"
      })
    XCTAssertEqual(
      String(data: try XCTUnwrap(requestBodyData(for: autoplay)), encoding: .utf8),
      #"{"value":true}"#)

    let route = "PUT /v2/config/chromecast_playback_type"
    fixtures.setFixture(#"{"status":"OK"}"#, for: route)
    try await runtime.setCastPlaybackType(.mp4)
    let request = try XCTUnwrap(
      fixtures.capturedRequests().last {
        $0.url?.path == "/v2/config/chromecast_playback_type"
      })
    let body = try XCTUnwrap(requestBodyData(for: request))
    XCTAssertEqual(
      try JSONSerialization.jsonObject(with: body) as? [String: String], ["value": "mp4"])
    fixtures.setFixture(#"{"status":"ERROR"}"#, for: route)
    await assertRuntimeError(.invalidResponse) { try await runtime.setCastPlaybackType(.hls) }
  }

  func testCastMediaUsesHLSWithMuxedSubtitlesAndRedactsTheToken() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(
      """
      {"file":{"id":412,"name":"Movie.mkv","file_type":"VIDEO","parent_id":0,
       "created_at":"2026-09-01T12:00:00","updated_at":"2026-09-01T12:00:00",
       "need_convert":false,"start_from":589,"screenshot":"https://img.put.io/412.jpg",
       "video_metadata":{"duration":5400.5,"codec":"h264","width":1920,"height":1080}}}
      """, for: "GET /v2/files/412")
    guard
      case .ready(let media) = try await runtime.resolveCastMedia(
        fileID: PutioFileID(rawValue: 412), playbackType: .hls)
    else { return XCTFail("expected ready media") }
    XCTAssertEqual(media.playbackType, .hls)
    XCTAssertEqual(media.title, "Movie.mkv")
    XCTAssertEqual(media.startFromSeconds, 589)
    XCTAssertEqual(media.durationSeconds, 5400.5)
    XCTAssertEqual(media.artworkURL, URL(string: "https://img.put.io/412.jpg"))
    XCTAssertTrue(media.subtitles.isEmpty)
    let components = try XCTUnwrap(URLComponents(url: media.url, resolvingAgainstBaseURL: false))
    XCTAssertEqual(components.path, "/v2/files/412/hls/media.m3u8")
    XCTAssertEqual(components.queryItems?.first { $0.name == "subtitle_key" }?.value, "all")
    XCTAssertEqual(
      components.queryItems?.first { $0.name == "oauth_token" }?.value, "account-download-secret")
    XCTAssertFalse(String(reflecting: media).contains("stored-token"))
    XCTAssertFalse(String(describing: media).contains("stored-token"))
    XCTAssertFalse(
      fixtures.capturedRequests().contains {
        $0.url?.path.hasSuffix("/subtitles") == true
      })
  }

  func testCastMediaUsesMP4WithWebVTTTracksAndGatesOnConversion() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    let file = { (needConvert: Bool, hasMP4: Bool) in
      """
      {"file":{"id":412,"name":"Movie.mkv","file_type":"VIDEO","parent_id":7,
       "created_at":"2026-09-01T12:00:00","updated_at":"2026-09-01T12:00:00",
       "need_convert":\(needConvert),"is_mp4_available":\(hasMP4),"start_from":10,
       "screenshot":"http://insecure.example/412.jpg"}}
      """
    }
    fixtures.setFixture(
      """
      {"default":"tr","subtitles":[
        {"key":"en","language":"English","language_code":"eng","name":"English.srt","source":"opensubtitles","url":"https://api.put.io/v2/files/412/subtitles/en?oauth_token=account-download-secret"},
        {"key":"tr","language":"Turkish","language_code":"tur","name":"Turkish.srt","source":"opensubtitles","url":"https://api.put.io/v2/files/412/subtitles/tr"},
        {"key":"tr","language":"Turkish","language_code":"tur","name":"Dup.srt","source":"x","url":"https://api.put.io/v2/files/412/subtitles/tr"},
        {"key":"de","language":"German","language_code":"ger","name":"Other.srt","source":"x","url":"https://evil.example/v2/files/412/subtitles/de"},
        {"key":"fr","language":"French","language_code":"fre","name":"Plain.srt","source":"x","url":"http://api.put.io/v2/files/412/subtitles/fr"},
        {"key":"","language":"","language_code":"","name":"","source":"","url":""}
      ]}
      """, for: "GET /v2/files/412/subtitles")

    fixtures.setFixture(file(true, true), for: "GET /v2/files/412")
    guard
      case .ready(let converted) = try await runtime.resolveCastMedia(
        fileID: PutioFileID(rawValue: 412), playbackType: .mp4)
    else { return XCTFail("expected ready media") }
    XCTAssertEqual(converted.playbackType, .mp4)
    XCTAssertEqual(converted.parentID, PutioFileID(rawValue: 7))
    XCTAssertNil(converted.artworkURL, "insecure artwork is dropped")
    XCTAssertEqual(converted.url.path, "/v2/files/412/mp4/download")
    XCTAssertEqual(
      converted.subtitles.map(\.key), ["en", "tr"],
      "duplicate, foreign-host, and plain-http tracks never carry the token")
    XCTAssertEqual(converted.defaultSubtitleKey, "tr")
    let subtitle = try XCTUnwrap(
      URLComponents(url: converted.subtitles[0].url, resolvingAgainstBaseURL: false))
    XCTAssertEqual(subtitle.queryItems?.map(\.name), ["oauth_token", "format"])
    XCTAssertEqual(subtitle.queryItems?.map(\.value), ["account-download-secret", "webvtt"])
    let untokened = try XCTUnwrap(
      URLComponents(url: converted.subtitles[1].url, resolvingAgainstBaseURL: false))
    XCTAssertEqual(
      untokened.queryItems?.map(\.value), ["account-download-secret", "webvtt"],
      "the receiver fetches tracks without the app's header")
    XCTAssertFalse(String(reflecting: converted).contains("stored-token"))

    fixtures.setFixture(file(false, false), for: "GET /v2/files/412")
    guard
      case .ready(let original) = try await runtime.resolveCastMedia(
        fileID: PutioFileID(rawValue: 412), playbackType: .mp4)
    else { return XCTFail("expected ready media") }
    XCTAssertEqual(original.url.path, "/v2/files/412/download")

    fixtures.setFixture(file(true, false), for: "GET /v2/files/412")
    let gated = try await runtime.resolveCastMedia(
      fileID: PutioFileID(rawValue: 412), playbackType: .mp4)
    XCTAssertEqual(gated, .conversionRequired)
    let hlsGated = try await runtime.resolveCastMedia(
      fileID: PutioFileID(rawValue: 412), playbackType: .hls)
    XCTAssertEqual(hlsGated, .conversionRequired)

    fixtures.setFixture(
      #"{"file":{"id":413,"name":"Other","file_type":"VIDEO","parent_id":0,"created_at":"2026-09-01T12:00:00","updated_at":"2026-09-01T12:00:00"}}"#,
      for: "GET /v2/files/412")
    await assertRuntimeError(.invalidResponse) {
      _ = try await runtime.resolveCastMedia(fileID: PutioFileID(rawValue: 412), playbackType: .hls)
    }
    await assertRuntimeError(.invalidResponse) {
      _ = try await runtime.resolveCastMedia(fileID: .root, playbackType: .hls)
    }
  }

  func testCastMediaAppliesTheAccountSubtitleSettingsToMP4Tracks() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(
      """
      {"file":{"id":412,"name":"Movie.mkv","file_type":"VIDEO","parent_id":7,
       "created_at":"2026-09-01T12:00:00","updated_at":"2026-09-01T12:00:00",
       "need_convert":false,"is_mp4_available":true,"start_from":10}}
      """, for: "GET /v2/files/412")
    fixtures.setFixture(
      """
      {"default":"tr","subtitles":[
        {"key":"en","language":"English","language_code":"eng","name":"English.srt","source":"x","url":"https://api.put.io/v2/files/412/subtitles/en"},
        {"key":"tr","language":"Turkish","language_code":"tur","name":"Turkish.srt","source":"x","url":"https://api.put.io/v2/files/412/subtitles/tr"}
      ]}
      """, for: "GET /v2/files/412/subtitles")
    let applySettings = { (setting: String, value: Bool) in
      let info = Self.accountInfo.replacingOccurrences(
        of: "\"\(setting)\": \(!value)", with: "\"\(setting)\": \(value)")
      self.fixtures.setFixture(info, for: "GET /v2/account/info")
      let refreshed = await runtime.refreshAccount()
      XCTAssertTrue(refreshed)
    }
    let resolve = { (playbackType: PutioCastPlaybackType) async throws -> PutioCastMedia in
      guard
        case .ready(let media) = try await runtime.resolveCastMedia(
          fileID: PutioFileID(rawValue: 412), playbackType: playbackType)
      else { throw PutioRuntimeError.invalidResponse }
      return media
    }

    await applySettings("dont_autoselect_subtitles", true)
    let unselected = try await resolve(.mp4)
    XCTAssertEqual(unselected.subtitles.map(\.key), ["en", "tr"])
    XCTAssertNil(unselected.defaultSubtitleKey, "tracks stay pickable but none starts on")

    await applySettings("hide_subtitles", true)
    let subtitleRequests = fixtures.capturedRequests().filter {
      $0.url?.path == "/v2/files/412/subtitles"
    }.count
    let hidden = try await resolve(.mp4)
    XCTAssertTrue(hidden.subtitles.isEmpty)
    XCTAssertNil(hidden.defaultSubtitleKey)
    XCTAssertEqual(
      fixtures.capturedRequests().filter { $0.url?.path == "/v2/files/412/subtitles" }.count,
      subtitleRequests, "hidden subtitles are never listed")
  }

  func testCastMediaAppliesSubtitleSettingsRefreshedWhileTracksLoad() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    let subtitlesRoute = "GET /v2/files/412/subtitles"
    fixtures.setFixture(
      """
      {"file":{"id":412,"name":"Movie.mkv","file_type":"VIDEO","parent_id":7,
       "created_at":"2026-09-01T12:00:00","updated_at":"2026-09-01T12:00:00",
       "need_convert":false,"is_mp4_available":true,"start_from":0}}
      """, for: "GET /v2/files/412")
    let subtitles = """
      {"default":"en","subtitles":[
        {"key":"en","language":"English","language_code":"eng","name":"English.srt","source":"x","url":"https://api.put.io/v2/files/412/subtitles/en"}
      ]}
      """
    for (setting, requests) in [("hide_subtitles", 1), ("dont_autoselect_subtitles", 2)] {
      fixtures.setFixture(Self.accountInfo, for: "GET /v2/account/info")
      let restored = await runtime.refreshAccount()
      XCTAssertTrue(restored)
      fixtures.gateFixture(subtitles, for: subtitlesRoute)
      let resolution = Task {
        try await runtime.resolveCastMedia(fileID: PutioFileID(rawValue: 412), playbackType: .mp4)
      }
      let started = await waitForRequest(subtitlesRoute, count: requests)
      XCTAssertTrue(started)
      fixtures.setFixture(
        Self.accountInfo.replacingOccurrences(
          of: "\"\(setting)\": false", with: "\"\(setting)\": true"),
        for: "GET /v2/account/info")
      let refreshed = await runtime.refreshAccount()
      XCTAssertTrue(refreshed)
      fixtures.releaseFixture(for: subtitlesRoute)
      guard case .ready(let media) = try await resolution.value else {
        return XCTFail("expected ready media")
      }
      XCTAssertNil(media.defaultSubtitleKey, setting)
      XCTAssertEqual(media.subtitles.isEmpty, setting == "hide_subtitles", setting)
    }
  }

  func testMediaURLsLeavingTheAppNeverCarryTheSessionToken() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(
      Self.playbackFile(needConvert: false, startFrom: 0), for: Self.playbackRoute)
    fixtures.setFixture(
      #"{"file":{"id":430,"file_type":"AUDIO","start_from":0}}"#, for: "GET /v2/files/430")
    fixtures.setFixture(
      """
      {"file":{"id":412,"name":"Movie.mkv","file_type":"VIDEO","parent_id":7,
       "created_at":"2026-09-01T12:00:00","updated_at":"2026-09-01T12:00:00",
       "need_convert":false,"is_mp4_available":true,"start_from":0}}
      """, for: "GET /v2/files/412")
    fixtures.setFixture(
      """
      {"default":"en","subtitles":[
        {"key":"en","language":"English","language_code":"eng","name":"English.srt","source":"x","url":"https://api.put.io/v2/files/412/subtitles/en?oauth_token=stored-token"}
      ]}
      """, for: "GET /v2/files/412/subtitles")

    var urls: [URL] = []
    for playbackType in [PutioCastPlaybackType.hls, .mp4] {
      guard
        case .ready(let media) = try await runtime.resolveCastMedia(
          fileID: PutioFileID(rawValue: 412), playbackType: playbackType)
      else { return XCTFail("expected ready \(playbackType) media") }
      urls.append(media.url)
      urls += media.subtitles.map(\.url)
    }
    urls.append(
      try await runtime.resolveFileDownloadSource(fileID: PutioFileID(rawValue: 412)).url)
    guard
      case .ready(let video) = try await runtime.resolveVideoPlaybackSource(
        fileID: PutioFileID(rawValue: 411))
    else { return XCTFail("expected ready playback") }
    urls.append(video.url)
    urls.append(
      try await runtime.resolveAudioPlaybackSource(fileID: PutioFileID(rawValue: 430)).url)

    XCTAssertEqual(urls.count, 6)
    for url in urls {
      XCTAssertFalse(url.absoluteString.contains("stored-token"), url.path)
      XCTAssertEqual(
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
          .filter { $0.name == "oauth_token" }.map(\.value),
        ["account-download-secret"], url.path)
    }
    let accountRequest = try XCTUnwrap(
      fixtures.capturedRequests().first { $0.url?.path == "/v2/account/info" }?.url)
    XCTAssertEqual(
      URLComponents(url: accountRequest, resolvingAgainstBaseURL: false)?.queryItems,
      [URLQueryItem(name: "download_token", value: "1")],
      "put.io returns the download token only when asked")
  }

  func testMediaURLsFailWithoutADownloadTokenInsteadOfUsingTheSessionToken() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(
      Self.accountInfo.replacingOccurrences(
        of: #""download_token": "account-download-secret","#, with: ""),
      for: "GET /v2/account/info")
    let refreshed = await runtime.refreshAccount()
    XCTAssertTrue(refreshed)
    fixtures.setFixture(
      #"{"file":{"id":411,"name":"Movie.mkv","file_type":"VIDEO","parent_id":0,"need_convert":false,"is_mp4_available":true,"created_at":"2026-09-01T12:00:00","updated_at":"2026-09-01T12:00:00"}}"#,
      for: Self.playbackRoute)

    for playbackType in [PutioCastPlaybackType.hls, .mp4] {
      await assertRuntimeError(.invalidResponse) {
        _ = try await runtime.resolveCastMedia(
          fileID: PutioFileID(rawValue: 411), playbackType: playbackType)
      }
    }
    await assertRuntimeError(.invalidResponse) {
      _ = try await runtime.resolveFileDownloadSource(fileID: PutioFileID(rawValue: 411))
    }
    await assertRuntimeError(.invalidResponse) {
      _ = try await runtime.resolveVideoPlaybackSource(fileID: PutioFileID(rawValue: 411))
    }
    guard case .signedIn = runtime.session.state else {
      return XCTFail("a missing download token must not end the session")
    }
  }

  private static func playbackFile(needConvert: Bool, startFrom: Int) -> String {
    return """
      {
        "file": {
          "id": 411,
          "file_type": "VIDEO",
          "need_convert": \(needConvert),
          "start_from": \(startFrom)
        }
      }
      """
  }
}
