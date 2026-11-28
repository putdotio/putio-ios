import Foundation
import PutioSDK

/// What a Direct play download stores: the original file and every put.io
/// subtitle file for it, as WebVTT.
public struct PutioOfflineOriginal: Equatable, Sendable {
  public let file: PutioFileDownloadSource
  public let subtitles: [PutioCastSubtitle]
  public let startFromSeconds: Int
  public let defaultSubtitleKey: String?
  public let enginePlays: Bool
  public let durationSeconds: Double?

  public init(
    file: PutioFileDownloadSource, subtitles: [PutioCastSubtitle], startFromSeconds: Int = 0,
    defaultSubtitleKey: String? = nil, enginePlays: Bool = true, durationSeconds: Double? = nil
  ) {
    self.file = file
    self.subtitles = subtitles
    self.startFromSeconds = startFromSeconds
    self.enginePlays = enginePlays
    self.durationSeconds = durationSeconds
    self.defaultSubtitleKey =
      subtitles.contains { $0.key == defaultSubtitleKey }
      ? defaultSubtitleKey : nil
  }
}

extension PutioRuntime {
  /// The original file of a video and every subtitle file put.io lists for
  /// it, whatever the account's subtitle settings: playback applies those.
  /// Subtitle URLs carry the download token and only ever point at the API host.
  public func resolveOfflineOriginal(fileID: PutioFileID) async throws -> PutioOfflineOriginal {
    let file = try await resolveFileDownloadSource(fileID: fileID)
    guard file.kind == .video else { throw PutioRuntimeError.invalidResponse }
    let token = try requireDownloadToken(session.downloadToken)
    let details = try await performAuthenticatedOperation {
      try await sdk.getFile(
        fileID: fileID.rawValue,
        query: PutioFileDetailsQuery(mediaInfo: true, videoMetadata: true))
    }
    let enginePlays =
      details.mediaInfo.map {
        if case .playable = PutioDirectPlayDecoders.support(of: $0) { return true }
        return false
      } ?? true
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
    return PutioOfflineOriginal(
      file: file, subtitles: subtitles, startFromSeconds: details.startFrom,
      defaultSubtitleKey: response.defaultKey, enginePlays: enginePlays,
      durationSeconds: details.metaData?.duration)
  }
}
