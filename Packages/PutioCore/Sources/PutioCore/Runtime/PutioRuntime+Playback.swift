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
      try await sdk.resolveVideoPlaybackSource(fileID: fileID.rawValue)
    }

    switch resolution {
    case .ready(let source):
      return .ready(
        PutioPlaybackSource(url: source.url, startFromSeconds: source.startFrom)
      )
    case .conversionRequired:
      return .conversionRequired
    }
  }

  public func resolveAudioPlaybackSource(fileID: PutioFileID) async throws -> PutioPlaybackSource {
    let source = try await performAuthenticatedOperation {
      try await sdk.resolveAudioPlaybackSource(fileID: fileID.rawValue)
    }
    return PutioPlaybackSource(url: source.url, startFromSeconds: source.startFrom)
  }

  public func findNextAudio(after fileID: PutioFileID) async throws -> PutioNextAudio? {
    let nextFile = try await performAuthenticatedOperation {
      try await sdk.findNextFileIfAvailable(fileID: fileID.rawValue, fileType: .audio)
    }
    guard let nextFile else { return nil }
    return PutioNextAudio(
      id: PutioFileID(rawValue: nextFile.id),
      parentID: PutioFileID(rawValue: nextFile.parentID),
      name: nextFile.name
    )
  }

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

  private func setAppConfigValue<Value: Encodable & Sendable>(
    _ key: PutioAppConfigKey, _ value: Value
  ) async throws {
    let response = try await performAuthenticatedOperation(commits: true) {
      try await sdk.setConfigValue(key: key.rawValue, value)
    }
    guard response.status == "OK" else { throw PutioRuntimeError.invalidResponse }
  }

  /// Resolves a video into what a Cast receiver plays. HLS uses the tokened
  /// playlist with server-muxed subtitles; MP4 uses the converted file when
  /// available (or the original when it needs no conversion) and lists the
  /// file's subtitles as WebVTT tracks. Files that still need conversion for
  /// MP4 playback resolve as `conversionRequired`. MP4 tracks follow the
  /// account's subtitle settings; HLS gets them applied by the server.
  public func resolveCastMedia(fileID: PutioFileID, playbackType: PutioCastPlaybackType)
    async throws -> PutioCastResolution
  {
    guard fileID.rawValue > 0 else { throw PutioRuntimeError.invalidResponse }
    let (file, token) = try await performAuthenticatedOperation {
      (
        try await sdk.getFile(
          fileID: fileID.rawValue,
          query: PutioFileDetailsQuery(
            mp4Size: false, startFrom: true, streamURL: false, mp4StreamURL: false)),
        sdk.config.token
      )
    }
    guard file.id == fileID.rawValue, file.type == .video else {
      throw PutioRuntimeError.invalidResponse
    }
    let artworkURL = URL(string: file.screenshot).flatMap { $0.scheme == "https" ? $0 : nil }
    let duration = file.metaData?.duration ?? 0
    switch playbackType {
    case .hls:
      // Same gate as the local player: put.io serves HLS for any file that
      // needs no conversion or already has its MP4, so the receiver keeps
      // the muxed-subtitle playlist after the gate instead of the MP4.
      guard !file.needConvert || file.hasMp4 else { return .conversionRequired }
      return .ready(
        PutioCastMedia(
          id: fileID, parentID: PutioFileID(rawValue: file.parentID), title: file.name,
          playbackType: .hls, url: file.getHlsStreamURL(token: token), artworkURL: artworkURL,
          durationSeconds: duration, startFromSeconds: file.startFrom, subtitles: [],
          defaultSubtitleKey: nil))
    case .mp4:
      let url: URL
      if file.hasMp4 {
        url = file.getMp4DownloadURL(token: token)
      } else if !file.needConvert {
        url = file.getDownloadURL(token: token)
      } else {
        return .conversionRequired
      }
      let media = { (subtitles: [PutioCastSubtitle], defaultKey: String?) in
        PutioCastResolution.ready(
          PutioCastMedia(
            id: fileID, parentID: PutioFileID(rawValue: file.parentID), title: file.name,
            playbackType: .mp4, url: url, artworkURL: artworkURL, durationSeconds: duration,
            startFromSeconds: file.startFrom, subtitles: subtitles, defaultSubtitleKey: defaultKey))
      }
      guard try !signedInAccount().hideSubtitles else { return media([], nil) }
      let response = try await performAuthenticatedOperation {
        try await sdk.getSubtitles(fileID: fileID.rawValue)
      }
      // The receiver fetches tracks itself, without the app's header, so the
      // token rides on the URL; only the API host may receive it.
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
      guard !account.hideSubtitles else { return media([], nil) }
      let defaultKey = response.defaultKey.flatMap { key in
        subtitles.contains { $0.key == key } ? key : nil
      }
      return media(
        subtitles, account.dontAutoSelectSubtitles ? nil : defaultKey ?? subtitles.first?.key)
    }
  }

  private func signedInAccount() throws -> PutioAccountSnapshot {
    guard case .signedIn(let account) = session.state else { throw currentSessionError }
    return account
  }

  public func startVideoConversion(fileID: PutioFileID) async throws {
    _ = try await performAuthenticatedOperation {
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
