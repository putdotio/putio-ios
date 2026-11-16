import Foundation

/// What a Direct play download stores: the original file and every put.io
/// subtitle file for it, as WebVTT.
public struct PutioOfflineOriginal: Equatable, Sendable {
  public let file: PutioFileDownloadSource
  public let subtitles: [PutioCastSubtitle]
  public let startFromSeconds: Int

  public init(
    file: PutioFileDownloadSource, subtitles: [PutioCastSubtitle], startFromSeconds: Int = 0
  ) {
    self.file = file
    self.subtitles = subtitles
    self.startFromSeconds = startFromSeconds
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
    let startFrom = try await performAuthenticatedOperation {
      try await sdk.getFile(
        fileID: fileID.rawValue,
        query: PutioFileDetailsQuery(
          mp4Size: false, startFrom: true, streamURL: false, mp4StreamURL: false))
    }.startFrom
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
    return PutioOfflineOriginal(file: file, subtitles: subtitles, startFromSeconds: startFrom)
  }
}
