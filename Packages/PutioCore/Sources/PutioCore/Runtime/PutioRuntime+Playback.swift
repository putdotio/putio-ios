import Foundation
import PutioSDK

extension PutioRuntime {
  public func findNextVideo(after fileID: PutioFileID) async throws -> PutioNextVideo? {
    let nextFile = try await performAuthenticatedOperation {
      try await sdk.findNextFileIfAvailable(fileID: fileID.rawValue, fileType: .video)
    }
    guard let nextFile else { return nil }

    return PutioNextVideo(
      id: PutioFileID(rawValue: nextFile.id),
      parentID: PutioFileID(rawValue: nextFile.parentID),
      name: nextFile.name
    )
  }

  public func resolveVideoPlaybackSource(fileID: PutioFileID) async throws
    -> PutioPlaybackResolution
  {
    let resolution = try await performAuthenticatedOperation {
      () -> PutioVideoPlaybackResolution? in
      guard let token = try? requireDownloadToken(session.downloadToken) else { return nil }
      return try await sdk.resolveVideoPlaybackSource(fileID: fileID.rawValue, downloadToken: token)
    }
    guard let resolution else { throw PutioRuntimeError.invalidResponse }

    switch resolution {
    case .ready(let source):
      return .ready(PutioPlaybackSource(url: source.url, startFromSeconds: source.startFrom))
    case .conversionRequired:
      return .conversionRequired
    }
  }

  /// Resolves a video under a Playback method. Standard is the HLS source
  /// above. Direct play asks the SDK's resolver for the original; an original
  /// AVPlayer cannot open plays in the engine with put.io's subtitle files.
  /// `isPlayableInAVPlayer` answers for an extended MP4 MIME type.
  public func resolveVideoPlayback(
    fileID: PutioFileID, method: PutioPlaybackMethod,
    isPlayableInAVPlayer: @escaping @Sendable (String) -> Bool
  ) async throws -> PutioPlaybackResolution {
    guard method == .directPlay else { return try await resolveVideoPlaybackSource(fileID: fileID) }
    let resolved = try await performAuthenticatedOperation {
      () -> (plan: PutioPlaybackPlan, token: String)? in
      guard let token = try? requireDownloadToken(session.downloadToken) else { return nil }
      let plan = try await sdk.resolvePlayback(
        fileID: fileID.rawValue, downloadToken: token, method: .directPlay,
        canPlayOriginal: { PutioDirectPlayDecoders.support(of: $0) })
      return (plan, token)
    }
    guard let resolved else { throw PutioRuntimeError.invalidResponse }

    switch resolved.plan {
    case .ready(let stream):
      guard stream.kind == .original else {
        return .ready(PutioPlaybackSource(url: stream.url, startFromSeconds: stream.startFrom))
      }
      let player =
        stream.mediaInfo.map {
          PutioDirectPlayDecoders.player(for: $0, isPlayableInAVPlayer: isPlayableInAVPlayer)
        } ?? .engine
      var original = PutioOriginalPlayback(
        player: player, audioStreams: PutioDirectPlayDecoders.audioStreams(of: stream.mediaInfo))
      if player == .engine,
        let sidecars = try? await sidecarSubtitles(fileID: fileID, token: resolved.token)
      {
        original = original.subtitles(sidecars.subtitles, defaultKey: sidecars.defaultKey)
      }
      return .ready(
        PutioPlaybackSource(url: stream.url, startFromSeconds: stream.startFrom, original: original))
    case .conversionRequired:
      return .conversionRequired
    case .unplayable(let reason):
      throw PutioPlaybackUnplayable(reason: reason.rawValue)
    }
  }

  public func resolveAudioPlaybackSource(fileID: PutioFileID) async throws -> PutioPlaybackSource {
    let source = try await performAuthenticatedOperation { () -> PutioAudioPlaybackSource? in
      guard let token = try? requireDownloadToken(session.downloadToken) else { return nil }
      return try await sdk.resolveAudioPlaybackSource(fileID: fileID.rawValue, downloadToken: token)
    }
    guard let source else { throw PutioRuntimeError.invalidResponse }
    return PutioPlaybackSource(url: source.url, startFromSeconds: source.startFrom)
  }

  /// Every audio file in `parentID`, in the folder's own sort as the Files
  /// browser shows it, around `fileID`. The next-file endpoint can leave the
  /// folder, so this lists it.
  public func audioNeighbours(of fileID: PutioFileID, in parentID: PutioFileID) async throws
    -> PutioAudioNeighbours
  {
    var page = try await performAuthenticatedOperation {
      try await sdk.getFiles(
        parentID: parentID.rawValue,
        query: PutioFilesListQuery(
          perPage: Self.audioQueuePageSize, fileType: .audio, videoMetadata: true))
    }
    let folderName = page.parent.flatMap { $0.id == parentID.rawValue ? $0.name : nil }
    var queue: [PutioQueuedAudio] = []
    var seen = Set<Int>()
    var cursors = Set<String>()
    while true {
      for file in page.children
      where file.type == .audio && file.parentID == parentID.rawValue
        && seen.insert(file.id).inserted
      {
        let duration = file.metaData.map { Int($0.duration.rounded()) }
        queue.append(
          PutioQueuedAudio(
            id: PutioFileID(rawValue: file.id), parentID: parentID, name: file.name,
            durationSeconds: duration.flatMap { $0 > 0 ? $0 : nil }))
      }
      guard let cursor = page.cursor, !cursor.isEmpty else { break }
      guard cursors.insert(cursor).inserted else { throw PutioRuntimeError.invalidResponse }
      page = try await performAuthenticatedOperation { try await sdk.continueFiles(cursor: cursor) }
    }
    return PutioAudioNeighbours(of: fileID, in: queue, folderName: folderName)
  }

  static let audioQueuePageSize = 100

  /// Saves the resume position for any media file; put.io keeps one
  /// `start_from` per file regardless of type. An account that turned
  /// positions off rejects every save as `FEATURE_DISABLED`; that position
  /// has nowhere to go, so it counts as settled rather than as a failure.
  public func reportPlaybackPosition(fileID: PutioFileID, seconds: Int) async throws {
    try await performAuthenticatedOperation {
      do {
        _ = try await sdk.setStartFrom(fileID: fileID.rawValue, time: seconds)
      } catch let error as PutioSDKError
        where error.matches(statusCode: 400, errorType: "FEATURE_DISABLED")
      {}
    }
  }

  /// The app's config document; unknown or missing values are its defaults.
  public func appConfig() async throws -> PutioAppConfig {
    try await performAuthenticatedOperation { try await sdk.getConfig(as: PutioAppConfig.self) }
  }

  public func castPlaybackType() async throws -> PutioCastPlaybackType {
    try await appConfig().chromecastPlaybackType
  }

  public func setCastPlaybackType(_ playbackType: PutioCastPlaybackType) async throws {
    try await setAppConfigValue(.chromecastPlaybackType, playbackType.rawValue)
  }

  public func setAutoplayNextVideo(_ enabled: Bool) async throws {
    try await setAppConfigValue(.autoplayNextVideo, enabled)
  }

  public func setAutoRotateVideo(_ enabled: Bool) async throws {
    try await setAppConfigValue(.autoRotateVideo, enabled)
  }

  public func setPlaybackMethod(_ method: PutioPlaybackMethod) async throws {
    try await setAppConfigValue(.streamingMethod, method.rawValue)
  }

  public func markProductAnalyticsPromptAnswered() async throws {
    try await setAppConfigValue(.productAnalyticsPromptAnswered, true)
  }

  func setAppConfigValue<Value: Encodable & Sendable>(
    _ key: PutioAppConfigKey, _ value: Value
  ) async throws {
    let response = try await performAuthenticatedOperation(commits: true) {
      try await sdk.setConfigValue(key: key.rawValue, value)
    }
    guard response.status == "OK" else { throw PutioRuntimeError.invalidResponse }
  }

  /// Resolves a video into what a Cast receiver plays. Every URL carries the
  /// download token, never the session token. HLS uses the tokened playlist
  /// with server-muxed subtitles; MP4 uses the converted file when
  /// available (or the original when it needs no conversion) and lists the
  /// file's subtitles as WebVTT tracks. Files that still need conversion for
  /// MP4 playback resolve as `conversionRequired`. MP4 tracks follow the
  /// account's subtitle settings; HLS gets them applied by the server.
  public func resolveCastMedia(fileID: PutioFileID, playbackType: PutioCastPlaybackType)
    async throws -> PutioCastResolution
  {
    guard fileID.rawValue > 0 else { throw PutioRuntimeError.invalidResponse }
    let (file, downloadToken) = try await performAuthenticatedOperation {
      (
        try await sdk.getFile(
          fileID: fileID.rawValue,
          query: PutioFileDetailsQuery(
            mp4Size: false, startFrom: true, streamURL: false, mp4StreamURL: false)),
        session.downloadToken
      )
    }
    guard file.id == fileID.rawValue, file.type == .video else {
      throw PutioRuntimeError.invalidResponse
    }
    let token = try requireDownloadToken(downloadToken)
    let artworkURL = URL(string: file.screenshot).flatMap { $0.scheme == "https" ? $0 : nil }
    let duration = file.metaData?.duration ?? 0
    let startFrom = PutioPlaybackProgress.startSeconds(
      savedSeconds: file.startFrom, durationSeconds: duration)
    switch playbackType {
    case .hls:
      // Same gate as the local player: put.io serves HLS for any file that
      // needs no conversion or already has its MP4, so the receiver keeps
      // the muxed-subtitle playlist after the gate instead of the MP4.
      guard !file.needConvert || file.hasMp4 else { return .conversionRequired }
      return .ready(
        PutioCastMedia(
          id: fileID, parentID: PutioFileID(rawValue: file.parentID), title: file.name,
          playbackType: .hls, url: file.getHlsStreamURL(downloadToken: token),
          artworkURL: artworkURL,
          durationSeconds: duration, startFromSeconds: startFrom, subtitles: [],
          defaultSubtitleKey: nil))
    case .mp4:
      let url: URL
      if file.hasMp4 {
        url = file.getMp4DownloadURL(downloadToken: token)
      } else if !file.needConvert {
        url = file.getDownloadURL(downloadToken: token)
      } else {
        return .conversionRequired
      }
      let media = { (subtitles: [PutioCastSubtitle], defaultKey: String?) in
        PutioCastResolution.ready(
          PutioCastMedia(
            id: fileID, parentID: PutioFileID(rawValue: file.parentID), title: file.name,
            playbackType: .mp4, url: url, artworkURL: artworkURL, durationSeconds: duration,
            startFromSeconds: startFrom, subtitles: subtitles, defaultSubtitleKey: defaultKey))
      }
      let sidecars = try await sidecarSubtitles(fileID: fileID, token: token)
      return media(sidecars.subtitles, sidecars.defaultKey)
    }
  }

  /// put.io's subtitle files for a video as WebVTT, under the account's
  /// subtitle settings. The receiver and the Direct play engine fetch them
  /// without the app's header, so the download token rides on the URL; only
  /// the API host may receive it.
  private func sidecarSubtitles(fileID: PutioFileID, token: String) async throws
    -> (subtitles: [PutioCastSubtitle], defaultKey: String?)
  {
    guard try !signedInAccount().hideSubtitles else { return ([], nil) }
    let response = try await performAuthenticatedOperation {
      try await sdk.getSubtitles(fileID: fileID.rawValue)
    }
    let apiHost = URL(string: sdk.config.baseURL)?.host
    var keys = Set<String>()
    let subtitles = response.subtitles.compactMap { subtitle -> PutioCastSubtitle? in
      guard !subtitle.key.isEmpty, keys.insert(subtitle.key).inserted,
        var components = URLComponents(string: subtitle.url), components.scheme == "https",
        let apiHost, components.host == apiHost
      else { return nil }
      var items = (components.queryItems ?? []).filter {
        $0.name != "oauth_token" && $0.name != "format"
      }
      items.append(URLQueryItem(name: "oauth_token", value: token))
      items.append(URLQueryItem(name: "format", value: "webvtt"))
      components.queryItems = items
      guard let url = components.url else { return nil }
      return PutioCastSubtitle(
        key: subtitle.key, language: subtitle.language, languageCode: subtitle.languageCode,
        name: subtitle.name, url: url)
    }
    // The account may have refreshed while the tracks loaded.
    let account = try signedInAccount()
    guard !account.hideSubtitles else { return ([], nil) }
    let defaultKey = response.defaultKey.flatMap { key in
      subtitles.contains { $0.key == key } ? key : nil
    }
    return (subtitles, account.dontAutoSelectSubtitles ? nil : defaultKey ?? subtitles.first?.key)
  }

  private func signedInAccount() throws -> PutioAccountSnapshot {
    guard case .signedIn(let account) = session.state else { throw currentSessionError }
    return account
  }

  public func startVideoConversion(fileID: PutioFileID) async throws {
    _ = try await performAuthenticatedOperation(commits: true) {
      try await sdk.startMp4Conversion(fileID: fileID.rawValue)
    }
  }

  public func videoConversionStatus(fileID: PutioFileID) async throws
    -> PutioVideoConversionStatus
  {
    let conversion = try await performAuthenticatedOperation {
      try await sdk.getMp4ConversionStatus(fileID: fileID.rawValue)
    }
    switch conversion.status {
    case .error, .notAvailable:
      return .failed
    case .completed:
      return .completed
    case .queued:
      return .queued
    default:
      // Unknown non-terminal statuses are still in progress. Only progress
      // rows must carry a valid fraction.
      let progress = Double(conversion.percentDone)
      guard progress.isFinite, (0...1).contains(progress) else {
        throw PutioRuntimeError.invalidResponse
      }
      return .converting(progress: progress)
    }
  }
}
