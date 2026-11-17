import AetherEngine
import Foundation
import PutioCore

typealias PutioOfflineOriginalResolve =
  @MainActor @Sendable (PutioFileID) async throws -> PutioOfflineOriginal
typealias PutioOfflineSubtitleFetch = @Sendable (URL) async throws -> Data
typealias PutioOfflineOriginalTrackReader =
  @Sendable (URL, String) async -> (audio: [PutioOfflineTrack], subtitles: [PutioOfflineTrack])

enum PutioOfflineOriginalPackage {
  struct Subtitle: Codable, Equatable, Sendable {
    let languageCode: String
    let displayName: String
    let fileName: String
  }

  static let transferName = "original"
  static let manifestName = "subtitles.json"

  nonisolated static func directory(accountID: Int, fileID: PutioFileID) -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appending(
        path: "OfflineDownloads/originals/\(accountID)-\(fileID.rawValue)",
        directoryHint: .isDirectory)
  }

  nonisolated static func transferURL(in directory: URL) -> URL {
    directory.appending(path: transferName)
  }

  nonisolated static func mediaURL(in directory: URL, name: String) -> URL {
    let pathExtension = (name as NSString).pathExtension.lowercased()
    guard !pathExtension.isEmpty else { return transferURL(in: directory) }
    return directory.appending(path: "\(transferName).\(pathExtension)")
  }

  nonisolated static func adopt(
    _ location: URL, response: URLResponse?, in directory: URL,
    fileManager: FileManager = .default
  ) throws {
    guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status)
    else { return }
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let destination = transferURL(in: directory)
    try? fileManager.removeItem(at: destination)
    try fileManager.moveItem(at: location, to: destination)
  }

  nonisolated static func finish(directory: URL, name: String, fileManager: FileManager = .default)
    -> Bool
  {
    let media = mediaURL(in: directory, name: name)
    let transfer = transferURL(in: directory)
    if media != transfer, fileManager.fileExists(atPath: transfer.path) {
      try? fileManager.removeItem(at: media)
      try? fileManager.moveItem(at: transfer, to: media)
    }
    return fileManager.fileExists(atPath: media.path)
  }

  static func store(
    _ subtitles: [(subtitle: PutioCastSubtitle, data: Data)], in directory: URL,
    fileManager: FileManager = .default
  ) throws {
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    var manifest: [Subtitle] = []
    for (index, entry) in subtitles.enumerated() {
      let languageCode = PutioOfflineLanguage.normalize(entry.subtitle.languageCode)
      let fileName = "subtitle-\(index)-\(languageCode).vtt"
      try entry.data.write(to: directory.appending(path: fileName), options: .atomic)
      manifest.append(
        Subtitle(
          languageCode: languageCode, displayName: entry.subtitle.language, fileName: fileName))
    }
    try JSONEncoder().encode(manifest).write(
      to: directory.appending(path: manifestName), options: .atomic)
  }

  nonisolated static func subtitles(in directory: URL) -> [Subtitle] {
    guard let data = try? Data(contentsOf: directory.appending(path: manifestName)) else {
      return []
    }
    return (try? JSONDecoder().decode([Subtitle].self, from: data)) ?? []
  }

  nonisolated static func playbackSubtitles(in directory: URL) -> [PutioCastSubtitle] {
    subtitles(in: directory).map {
      PutioCastSubtitle(
        key: $0.fileName, language: $0.displayName, languageCode: $0.languageCode,
        name: $0.displayName, source: .openSubtitles, url: directory.appending(path: $0.fileName))
    }
  }

  @concurrent
  nonisolated static func storedTracks(in directory: URL, name: String) async
    -> (audio: [PutioOfflineTrack], subtitles: [PutioOfflineTrack])
  {
    var options = LoadOptions()
    options.skipsContainerAttachments = true
    let probe = try? AetherEngine.probe(url: mediaURL(in: directory, name: name), options: options)
    let audio = (probe?.audioTracks ?? []).compactMap { track -> PutioOfflineTrack? in
      guard let language = track.language, !language.isEmpty, language != "und" else { return nil }
      let code = PutioOfflineLanguage.normalize(language)
      return PutioOfflineTrack(
        languageCode: code,
        displayName: Locale.current.localizedString(forLanguageCode: code) ?? track.name)
    }
    let subtitles = subtitles(in: directory).map {
      PutioOfflineTrack(languageCode: $0.languageCode, displayName: $0.displayName)
    }
    return (audio, subtitles)
  }

  @concurrent
  nonisolated static func fetchSubtitle(_ url: URL) async throws -> Data {
    let (data, response) = try await URLSession.shared.data(from: url)
    guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status)
    else { throw URLError(.badServerResponse) }
    return data
  }
}
