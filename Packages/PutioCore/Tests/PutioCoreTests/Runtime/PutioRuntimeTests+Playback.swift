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

  func testVideoConversionStartKeepsAResponseThatArrivesBeforeCancellation() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.gateFixture(#"{"status":"OK"}"#, for: Self.conversionStartRoute)

    let start = Task { try await runtime.startVideoConversion(fileID: PutioFileID(rawValue: 411)) }
    guard await waitForRequest(Self.conversionStartRoute) else {
      start.cancel()
      fixtures.releaseFixture(for: Self.conversionStartRoute)
      return XCTFail("conversion request did not start")
    }
    // Holding the main actor lets the response finish loading before the
    // cancellation, so the caller polls instead of posting a second start.
    fixtures.releaseFixture(for: Self.conversionStartRoute)
    blockCurrentThread(seconds: 0.3)
    start.cancel()

    try await start.value
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

  private static func audioRow(
    _ id: Int, _ name: String, type: String = "AUDIO", parent: Int = 7, duration: Double? = nil
  ) -> String {
    let metadata = duration.map { #","video_metadata":{"duration":\#($0)}"# } ?? ""
    return
      #"{"id":\#(id),"name":"\#(name)","file_type":"\#(type)","parent_id":\#(parent),"size":1,"created_at":"2026-08-28T10:00:00Z","updated_at":"2026-08-29T10:00:00Z"\#(metadata)}"#
  }

  private static func queued(_ id: Int, _ name: String, duration: Int? = nil) -> PutioQueuedAudio {
    PutioQueuedAudio(
      id: PutioFileID(rawValue: id), parentID: PutioFileID(rawValue: 7), name: name,
      durationSeconds: duration)
  }

  func testAudioNeighboursListTheFolderInItsOwnOrderWithLengthsAcrossPages() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    let folder = Self.audioRow(7, "Music", type: "FOLDER", parent: 0)
    fixtures.setFixture(
      #"{"parent":\#(folder),"cursor":"audio-2","files":[\#(Self.audioRow(432, "D.mp3", duration: 3254.4)),\#(Self.audioRow(430, "B.mp3", duration: 0))]}"#,
      for: "GET /v2/files/list")
    fixtures.setFixture(
      #"{"cursor":"","files":[\#(Self.audioRow(500, "Elsewhere.mp3", parent: 8)),\#(Self.audioRow(431, "C.mp3", duration: 61.6)),\#(Self.audioRow(429, "A.mp3"))]}"#,
      for: "POST /v2/files/list/continue")

    let neighbours = try await runtime.audioNeighbours(
      of: PutioFileID(rawValue: 430), in: PutioFileID(rawValue: 7))

    let queue = [
      Self.queued(432, "D.mp3", duration: 3254), Self.queued(430, "B.mp3"),
      Self.queued(431, "C.mp3", duration: 62), Self.queued(429, "A.mp3"),
    ]
    XCTAssertEqual(
      neighbours,
      PutioAudioNeighbours(
        previous: queue[0], next: queue[2], folderName: "Music", queue: queue))
    let list = try XCTUnwrap(
      fixtures.capturedRequests().first { $0.url?.path == "/v2/files/list" })
    let items =
      URLComponents(url: try XCTUnwrap(list.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
    let query = Set(items.map { "\($0.name)=\($0.value ?? "")" })
    XCTAssertTrue(query.isSuperset(of: ["parent_id=7", "file_type=AUDIO", "video_metadata=1"]))
    XCTAssertFalse(items.contains { $0.name == "sort_by" }, "the folder's own sort applies")
  }

  func testAudioNeighboursOfTheOnlyFileInAFolderAreEmpty() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    let folder = Self.audioRow(7, "Music", type: "FOLDER", parent: 0)
    fixtures.setFixture(
      #"{"parent":\#(folder),"cursor":"","files":[\#(Self.audioRow(430, "B.mp3"))]}"#,
      for: "GET /v2/files/list")

    let neighbours = try await runtime.audioNeighbours(
      of: PutioFileID(rawValue: 430), in: PutioFileID(rawValue: 7))

    XCTAssertEqual(
      neighbours, PutioAudioNeighbours(folderName: "Music", queue: [Self.queued(430, "B.mp3")]))
  }

  func testAudioNeighboursOfAFileTheFolderNoLongerHoldsAreEmpty() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(
      #"{"cursor":"","files":[\#(Self.audioRow(429, "A.mp3")),\#(Self.audioRow(431, "C.mp3"))]}"#,
      for: "GET /v2/files/list")

    let neighbours = try await runtime.audioNeighbours(
      of: PutioFileID(rawValue: 430), in: PutioFileID(rawValue: 7))

    XCTAssertNil(neighbours.previous)
    XCTAssertNil(neighbours.next)
    XCTAssertEqual(neighbours.queue.map(\.id.rawValue), [429, 431])
  }

  func testAudioNeighboursRejectARepeatedCursor() async {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(
      #"{"cursor":"loop","files":[\#(Self.audioRow(429, "A.mp3"))]}"#, for: "GET /v2/files/list")
    fixtures.setFixture(
      #"{"cursor":"loop","files":[]}"#, for: "POST /v2/files/list/continue")

    await assertRuntimeError(.invalidResponse) {
      _ = try await runtime.audioNeighbours(
        of: PutioFileID(rawValue: 430), in: PutioFileID(rawValue: 7))
    }
  }

  func testVideoConversionStatusMapsEveryKnownSDKState() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    let cases: [(String, Int, PutioVideoConversionStatus)] = [
      ("IN_QUEUE", 0, .queued),
      ("CONVERTING", 35, .converting(progress: 0.35)),
      ("COMPLETED", 100, .completed),
      ("ERROR", 0, .failed),
      ("NOT_AVAILABLE", 0, .unavailable),
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
      ("ERROR", PutioVideoConversionStatus.failed), ("NOT_AVAILABLE", .unavailable),
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

  func testAppConfigDecodesLenientlyAndWritesAutoplay() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(
      #"{"config":{"autoplay_next_video":"yes","web_only":1}}"#, for: "GET /v2/config")
    let lenient = try await runtime.appConfig()
    XCTAssertEqual(lenient, PutioAppConfig(autoplayNextVideo: false))
    fixtures.setFixture(#"{"config":{"autoplay_next_video":true}}"#, for: "GET /v2/config")
    let full = try await runtime.appConfig()
    XCTAssertEqual(full, PutioAppConfig(autoplayNextVideo: true))
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
  }

  func testPlaybackMethodRoundTripsThroughTheStreamingMethodConfigKey() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(#"{"config":{}}"#, for: "GET /v2/config")
    let fresh = try await runtime.appConfig()
    XCTAssertEqual(fresh.playbackMethod, .standard)

    let route = "PUT /v2/config/streaming_method"
    fixtures.setFixture(#"{"status":"OK"}"#, for: route)
    try await runtime.setPlaybackMethod(.directPlay)
    let request = try XCTUnwrap(
      fixtures.capturedRequests().last { $0.url?.path == "/v2/config/streaming_method" })
    XCTAssertEqual(
      String(data: try XCTUnwrap(requestBodyData(for: request)), encoding: .utf8),
      #"{"value":"file"}"#)

    fixtures.setFixture(#"{"config":{"streaming_method":"file"}}"#, for: "GET /v2/config")
    let stored = try await runtime.appConfig()
    XCTAssertEqual(stored.playbackMethod, .directPlay)

    fixtures.setFixture(#"{"status":"ERROR"}"#, for: route)
    await assertRuntimeError(.invalidResponse) { try await runtime.setPlaybackMethod(.standard) }
  }

  func testProductAnalyticsPromptAnswerWritesItsFlatConfigKey() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    let route = "PUT /v2/config/dismissed.product_analytics_prompt"
    fixtures.setFixture(#"{"status":"OK"}"#, for: route)
    try await runtime.markProductAnalyticsPromptAnswered()
    let request = try XCTUnwrap(
      fixtures.capturedRequests().last {
        $0.url?.path == "/v2/config/dismissed.product_analytics_prompt"
      })
    XCTAssertEqual(
      String(data: try XCTUnwrap(requestBodyData(for: request)), encoding: .utf8),
      #"{"value":true}"#)
    fixtures.setFixture(#"{"status":"ERROR"}"#, for: route)
    await assertRuntimeError(.invalidResponse) {
      try await runtime.markProductAnalyticsPromptAnswered()
    }
  }

  func testCastMediaIsHLSWithSideLoadedSubtitlesAndRedactsTheToken() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(
      #"{"config":{"chromecast_playback_type":"mp4"}}"#, for: "GET /v2/config")
    fixtures.setFixture(
      """
      {"file":{"id":412,"name":"Movie.mkv","file_type":"VIDEO","parent_id":0,
       "created_at":"2026-09-01T12:00:00","updated_at":"2026-09-01T12:00:00",
       "need_convert":false,"start_from":589,"screenshot":"https://img.put.io/412.jpg",
       "video_metadata":{"duration":5400.5,"codec":"h264","width":1920,"height":1080}}}
      """, for: "GET /v2/files/412")
    fixtures.setFixture(
      """
      {"default":"tr","subtitles":[
        {"key":"en","language":"English","language_code":"eng","name":"English.srt","source":"mkv","url":"https://api.put.io/v2/files/412/subtitles/en"},
        {"key":"tr","language":"Turkish","language_code":"tur","name":"Turkish.srt","source":"opensubtitles","url":"https://api.put.io/v2/files/412/subtitles/tr?oauth_token=stored-token"},
        {"key":"x","language":"Elsewhere","language_code":"und","name":"x.srt","source":"folder","url":"https://example.com/x.srt"}
      ]}
      """, for: "GET /v2/files/412/subtitles")
    guard
      case .ready(let media) = try await runtime.resolveCastMedia(
        fileID: PutioFileID(rawValue: 412))
    else { return XCTFail("expected ready media") }
    XCTAssertEqual(media.title, "Movie.mkv")
    XCTAssertEqual(media.startFromSeconds, 589)
    XCTAssertEqual(media.durationSeconds, 5400.5)
    XCTAssertEqual(media.artworkURL, URL(string: "https://img.put.io/412.jpg"))
    let components = try XCTUnwrap(URLComponents(url: media.url, resolvingAgainstBaseURL: false))
    XCTAssertEqual(components.path, "/v2/files/412/hls/media.m3u8")
    XCTAssertNil(
      components.queryItems?.first { $0.name == "subtitle_key" },
      "the stream muxes subtitles the load request already side-loads")
    XCTAssertEqual(
      components.queryItems?.first { $0.name == "oauth_token" }?.value, "account-download-secret")
    XCTAssertEqual(media.subtitles.map(\.key), ["en", "tr"])
    XCTAssertEqual(media.subtitles.map(\.source), [.embedded, .openSubtitles])
    XCTAssertEqual(media.defaultSubtitleKey, "tr")
    for subtitle in media.subtitles {
      let query = URLComponents(url: subtitle.url, resolvingAgainstBaseURL: false)?.queryItems
      XCTAssertEqual(
        query?.filter { $0.name == "oauth_token" }.map(\.value), ["account-download-secret"])
      XCTAssertEqual(query?.first { $0.name == "format" }?.value, "webvtt")
    }
    XCTAssertFalse(String(reflecting: media).contains("secret"))
    XCTAssertFalse(String(describing: media).contains("secret"))
    XCTAssertFalse(
      fixtures.capturedRequests().contains { $0.url?.path.hasPrefix("/v2/config") == true },
      "casting reads no Chromecast setting")
  }

  func testCastMediaStillLoadsWhenSubtitlesFailOrAreHidden() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(
      """
      {"file":{"id":412,"name":"Movie.mkv","file_type":"VIDEO","parent_id":0,
       "created_at":"2026-09-01T12:00:00","updated_at":"2026-09-01T12:00:00",
       "need_convert":false,"start_from":0}}
      """, for: "GET /v2/files/412")
    fixtures.setFixture(
      #"{"status":"ERROR"}"#, statusCode: 500, for: "GET /v2/files/412/subtitles")
    guard
      case .ready(let failed) = try await runtime.resolveCastMedia(
        fileID: PutioFileID(rawValue: 412))
    else { return XCTFail("expected ready media") }
    XCTAssertEqual(failed.subtitles, [])
    XCTAssertNil(failed.defaultSubtitleKey)
    XCTAssertEqual(
      URLComponents(url: failed.url, resolvingAgainstBaseURL: false)?.queryItems?
        .first { $0.name == "subtitle_key" }?.value, "all",
      "without subtitle files the stream keeps its own subtitles")
  }

  func testCastAudioSendsTheOriginalStreamWithItsTypeAndRejectsVideo() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(
      """
      {"file":{"id":430,"name":"Session.mp3","file_type":"AUDIO","parent_id":7,
       "created_at":"2026-09-01T12:00:00","updated_at":"2026-09-01T12:00:00",
       "start_from":45,"video_metadata":{"duration":2977}}}
      """, for: "GET /v2/files/430")

    let media = try await runtime.resolveCastAudio(fileID: PutioFileID(rawValue: 430))

    XCTAssertEqual(media.title, "Session.mp3")
    XCTAssertEqual(media.parentID, PutioFileID(rawValue: 7))
    XCTAssertEqual(media.startFromSeconds, 45)
    XCTAssertEqual(media.durationSeconds, 2977)
    XCTAssertEqual(media.contentType, "audio/mpeg")
    let components = try XCTUnwrap(URLComponents(url: media.url, resolvingAgainstBaseURL: false))
    XCTAssertEqual(components.path, "/v2/files/430/stream")
    XCTAssertEqual(
      components.queryItems?.filter { $0.name == "oauth_token" }.map(\.value),
      ["account-download-secret"])
    XCTAssertFalse(String(reflecting: media).contains("account-download-secret"))

    fixtures.setFixture(
      Self.playbackFile(needConvert: false, startFrom: 0), for: Self.playbackRoute)
    await assertRuntimeError(.invalidResponse) {
      _ = try await runtime.resolveCastAudio(fileID: PutioFileID(rawValue: 411))
    }
  }

  func testCastingAWatchedVideoStartsFromTheBeginning() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    let file = { (startFrom: Int) in
      """
      {"file":{"id":412,"name":"Movie.mkv","file_type":"VIDEO","parent_id":0,
       "created_at":"2026-09-01T12:00:00","updated_at":"2026-09-01T12:00:00",
       "need_convert":false,"start_from":\(startFrom),"screenshot":"",
       "video_metadata":{"duration":600,"codec":"h264","width":1920,"height":1080}}}
      """
    }
    var starts: [Int] = []
    for startFrom in [569, 570] {
      fixtures.setFixture(file(startFrom), for: "GET /v2/files/412")
      guard
        case .ready(let media) = try await runtime.resolveCastMedia(
          fileID: PutioFileID(rawValue: 412))
      else { return XCTFail("expected ready media") }
      starts.append(media.startFromSeconds)
    }
    XCTAssertEqual(starts, [569, 0])
  }

  func testCastMediaGatesOnConversionLikeTheLocalPlayer() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    let file = { (needConvert: Bool, hasMP4: Bool) in
      """
      {"file":{"id":412,"name":"Movie.mkv","file_type":"VIDEO","parent_id":7,
       "created_at":"2026-09-01T12:00:00","updated_at":"2026-09-01T12:00:00",
       "need_convert":\(needConvert),"is_mp4_available":\(hasMP4),"start_from":10,
       "screenshot":"http://insecure.example/412.jpg"}}
      """
    }
    fixtures.setFixture(file(true, true), for: "GET /v2/files/412")
    guard
      case .ready(let converted) = try await runtime.resolveCastMedia(
        fileID: PutioFileID(rawValue: 412))
    else { return XCTFail("expected ready media") }
    XCTAssertEqual(converted.parentID, PutioFileID(rawValue: 7))
    XCTAssertNil(converted.artworkURL, "insecure artwork is dropped")
    XCTAssertEqual(converted.url.path, "/v2/files/412/hls/media.m3u8")

    fixtures.setFixture(file(true, false), for: "GET /v2/files/412")
    let gated = try await runtime.resolveCastMedia(fileID: PutioFileID(rawValue: 412))
    XCTAssertEqual(gated, .conversionRequired)

    fixtures.setFixture(
      #"{"file":{"id":413,"name":"Other","file_type":"VIDEO","parent_id":0,"created_at":"2026-09-01T12:00:00","updated_at":"2026-09-01T12:00:00"}}"#,
      for: "GET /v2/files/412")
    await assertRuntimeError(.invalidResponse) {
      _ = try await runtime.resolveCastMedia(fileID: PutioFileID(rawValue: 412))
    }
    await assertRuntimeError(.invalidResponse) {
      _ = try await runtime.resolveCastMedia(fileID: .root)
    }
  }

  func testCastMediaRequestsTheConversionFlagTheFilesAPIOmitsByDefault() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(
      """
      {"file":{"id":412,"name":"Movie.mkv","file_type":"VIDEO","parent_id":0,
       "created_at":"2026-09-01T12:00:00","updated_at":"2026-09-01T12:00:00",
       "need_convert":true,"is_mp4_available":false,"start_from":0}}
      """, for: "GET /v2/files/412")

    _ = try await runtime.resolveCastMedia(fileID: PutioFileID(rawValue: 412))

    let request = try XCTUnwrap(
      fixtures.capturedRequests().last { $0.url?.path == "/v2/files/412" })
    let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
      .queryItems ?? []
    XCTAssertTrue(
      query.contains { ["mp4_status", "mp4_stream_url"].contains($0.name) && $0.value == "1" },
      "GET /files/{id} returns need_convert only with mp4_status or mp4_stream_url")
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

    var urls: [URL] = []
    guard
      case .ready(let media) = try await runtime.resolveCastMedia(
        fileID: PutioFileID(rawValue: 412))
    else { return XCTFail("expected ready cast media") }
    urls.append(media.url)
    urls.append(
      try await runtime.resolveFileDownloadSource(fileID: PutioFileID(rawValue: 412)).url)
    guard
      case .ready(let video) = try await runtime.resolveVideoPlaybackSource(
        fileID: PutioFileID(rawValue: 411))
    else { return XCTFail("expected ready playback") }
    urls.append(video.url)
    urls.append(
      try await runtime.resolveAudioPlaybackSource(fileID: PutioFileID(rawValue: 430)).url)

    XCTAssertEqual(urls.count, 4)
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

    await assertRuntimeError(.invalidResponse) {
      _ = try await runtime.resolveCastMedia(fileID: PutioFileID(rawValue: 411))
    }
    do {
      _ = try await runtime.resolveFileDownloadSource(fileID: PutioFileID(rawValue: 411))
      XCTFail("resolved a download source without a download token")
    } catch {
      XCTAssertTrue(error is PutioDownloadTokenUnavailable, "\(error)")
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
