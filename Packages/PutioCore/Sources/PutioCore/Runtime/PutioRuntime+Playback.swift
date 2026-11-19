import Foundation
import PutioSDK
import UniformTypeIdentifiers

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

  /// A download keeps every subtitle rendition; playback applies the
  /// account's subtitle settings, so only streams ask for a manifest without them.
  public func resolveVideoPlaybackSource(fileID: PutioFileID, forDownload: Bool = false)
    async throws -> PutioPlaybackResolution
  {
    let resolution = try await performAuthenticatedOperation {
      () -> PutioVideoPlaybackResolution? in
      guard let token = try? requireDownloadToken(session.downloadToken) else { return nil }
      return try await sdk.resolveVideoPlaybackSource(fileID: fileID.rawValue, downloadToken: token)
    }
    guard let resolution else { throw PutioRuntimeError.invalidResponse }

    switch resolution {
    case .ready(let source):
      return .ready(
        PutioPlaybackSource(
          url: forDownload ? source.url : try hlsURL(source.url),
          startFromSeconds: source.startFrom, facts: .standard))
    case .conversionRequired:
      return .conversionRequired
    }
  }

  func hlsURL(_ url: URL) throws -> URL {
    guard try signedInAccount().hideSubtitles,
      var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { return url }
    components.queryItems =
      (components.queryItems ?? []).filter { $0.name != "max_subtitle_count" }
      + [URLQueryItem(name: "max_subtitle_count", value: "0")]
    return components.url ?? url
  }

  /// Resolves a video under a Playback method. Standard is the HLS source
  /// above. Direct play asks the SDK's resolver for the original. AVPlayer
  /// keeps an MP4 or MOV original it decodes that has no put.io subtitle
  /// files; every other original plays in the engine with those files.
  /// `isPlayableInAVPlayer` answers for an extended MP4 MIME type.
  public func resolveVideoPlayback(
    fileID: PutioFileID, method: PutioPlaybackMethod, playsConverted: Bool = false,
    isPlayableInAVPlayer: @escaping @Sendable (String) -> Bool
  ) async throws -> PutioPlaybackResolution {
    guard method == .directPlay else { return try await resolveVideoPlaybackSource(fileID: fileID) }
    let resolved = try await performAuthenticatedOperation {
      () -> (plan: PutioPlaybackPlan, token: String)? in
      guard let token = try? requireDownloadToken(session.downloadToken) else { return nil }
      let plan = try await sdk.resolvePlayback(
        fileID: fileID.rawValue, downloadToken: token, method: .directPlay,
        canPlayOriginal: {
          playsConverted ? .unsupported(.decoderError) : PutioDirectPlayDecoders.support(of: $0)
        })
      return (plan, token)
    }
    guard let resolved else { throw PutioRuntimeError.invalidResponse }

    switch resolved.plan {
    case .ready(let stream):
      guard stream.kind == .original else {
        return .ready(
          PutioPlaybackSource(
            url: stream.url, startFromSeconds: stream.startFrom, facts: .directPlay(stream)))
      }
      let sidecars = try? await sidecarSubtitles(fileID: fileID, token: resolved.token)
      let subtitles = sidecars?.subtitles ?? []
      let player =
        subtitles.isEmpty
        ? stream.mediaInfo.map {
          PutioDirectPlayDecoders.player(for: $0, isPlayableInAVPlayer: isPlayableInAVPlayer)
        } ?? .engine : .engine
      let original = PutioOriginalPlayback(
        player: player, audioStreams: PutioDirectPlayDecoders.audioStreams(of: stream.mediaInfo),
        subtitles: subtitles, defaultSubtitleKey: sidecars?.defaultKey)
      return .ready(
        PutioPlaybackSource(
          url: stream.url, startFromSeconds: stream.startFrom, original: original,
          facts: .directPlay(stream)))
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
    let stored = try await performAuthenticatedOperation {
      do {
        _ = try await sdk.setStartFrom(fileID: fileID.rawValue, time: seconds)
        return true
      } catch let error as PutioSDKError
        where error.matches(statusCode: 400, errorType: "FEATURE_DISABLED")
      {
        return false
      }
    }
    if stored { publishWatched(fileID: fileID, isWatched: seconds > 0) }
  }

  /// The app's config document; unknown or missing values are its defaults.
  public func appConfig() async throws -> PutioAppConfig {
    try await performAuthenticatedOperation { try await sdk.getConfig(as: PutioAppConfig.self) }
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

  /// Resolves a video into the HLS stream a Cast receiver plays, behind the
  /// local player's gate: put.io serves HLS for any file that needs no
  /// conversion or already has its MP4. The receiver plays the manifest's
  /// own subtitle renditions, named and defaulted by the master playlist.
  /// URLs carry the download token, never the session token.
  public func resolveCastMedia(fileID: PutioFileID) async throws -> PutioCastResolution {
    guard fileID.rawValue > 0 else { throw PutioRuntimeError.invalidResponse }
    let (file, downloadToken) = try await performAuthenticatedOperation {
      (
        try await sdk.getFile(
          fileID: fileID.rawValue,
          query: PutioFileDetailsQuery(
            mp4Size: false, startFrom: true, streamURL: false, mp4StreamURL: false,
            mp4Status: true)),
        session.downloadToken
      )
    }
    guard file.id == fileID.rawValue, file.type == .video else {
      throw PutioRuntimeError.invalidResponse
    }
    let token = try requireDownloadToken(downloadToken)
    guard !file.needConvert || file.hasMp4 else { return .conversionRequired }
    let duration = file.metaData?.duration ?? 0
    let stream = try hlsURL(file.getHlsStreamURL(downloadToken: token))
    let renditions = await subtitleRenditions(inMasterPlaylist: stream)
    return .ready(
      PutioCastMedia(
        id: fileID, parentID: PutioFileID(rawValue: file.parentID), title: file.name,
        url: stream,
        artworkURL: Self.screenshotURL(file.screenshot),
        durationSeconds: duration,
        startFromSeconds: PutioPlaybackProgress.startSeconds(
          savedSeconds: file.startFrom, durationSeconds: duration),
        subtitleRenditions: renditions))
  }

  private nonisolated func subtitleRenditions(inMasterPlaylist url: URL) async
    -> [PutioSubtitleRendition]
  {
    guard let (data, response) = try? await urlSession.data(from: url),
      (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false,
      let text = String(data: data, encoding: .utf8)
    else { return [] }
    return PutioSubtitleRenditions.renditions(inMasterPlaylist: text)
  }

  public func resolveCastAudio(fileID: PutioFileID) async throws -> PutioCastMedia {
    guard fileID.rawValue > 0 else { throw PutioRuntimeError.invalidResponse }
    let (file, downloadToken) = try await performAuthenticatedOperation {
      (
        try await sdk.getFile(fileID: fileID.rawValue, query: Self.fileMetadataQuery),
        session.downloadToken
      )
    }
    guard file.id == fileID.rawValue, file.type == .audio else {
      throw PutioRuntimeError.invalidResponse
    }
    let token = try requireDownloadToken(downloadToken)
    let duration = file.metaData?.duration ?? 0
    return PutioCastMedia(
      id: fileID, parentID: PutioFileID(rawValue: file.parentID), title: file.name,
      url: file.getAudioStreamURL(downloadToken: token), artworkURL: nil,
      durationSeconds: duration,
      startFromSeconds: PutioPlaybackProgress.startSeconds(
        savedSeconds: file.startFrom, durationSeconds: duration),
      kind: .audio(contentType: Self.audioContentType(fileName: file.name)))
  }

  static func audioContentType(fileName: String) -> String {
    let fileExtension = (fileName as NSString).pathExtension
    return UTType(filenameExtension: fileExtension, conformingTo: .audio)?.preferredMIMEType
      ?? "audio/mpeg"
  }

  /// put.io's subtitle files for a video as WebVTT, under the account's
  /// subtitle settings. The Direct play engine fetches them
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
        name: subtitle.name, source: PutioSubtitleSource(apiSource: subtitle.source), url: url)
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
    case .error:
      return .failed
    case .notAvailable:
      return .unavailable
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
