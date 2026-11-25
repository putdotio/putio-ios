import Foundation

#if !os(watchOS)
  import AVFoundation
#endif

public struct PutioVideoAudioTrack: Identifiable, Equatable, Sendable {
  public let id: Int
  public let title: String
  public var detail: String?
  public var languageTag: String?

  public init(id: Int, title: String, detail: String? = nil, languageTag: String? = nil) {
    self.id = id
    self.title = title
    self.detail = detail
    self.languageTag = languageTag
  }
}

public struct PutioVideoTrackSelection: Equatable, Sendable {
  public let audio: Int?
  public let subtitle: Int?

  public init(audio: Int?, subtitle: Int?) {
    self.audio = audio
    self.subtitle = subtitle
  }
}

#if !os(watchOS)
  public enum PutioVideoTracks {
    public static func subtitleTracks(
      _ options: [AVMediaSelectionOption], defaultOption: AVMediaSelectionOption?,
      names: [AVMediaSelectionOption: String] = [:]
    ) -> [PutioSubtitleTrack] {
      options.enumerated().map { index, option in
        PutioSubtitleTrack(
          id: index, title: names[option] ?? option.displayName(with: PutioTrackLabel.english),
          languageTag: option.extendedLanguageTag ?? option.locale?.identifier,
          isDefault: option == defaultOption)
      }
    }

    public static func audioTracks(
      _ options: [AVMediaSelectionOption], details: [AVMediaSelectionOption: String],
      renditions: [PutioAudioRendition]
    ) -> [PutioVideoAudioTrack] {
      let renditions = options.enumerated().map { index, option in
        rendition(of: option, at: index, count: options.count, in: renditions)
      }
      let languages = options.enumerated().map { index, option in
        option.extendedLanguageTag ?? option.locale?.identifier ?? renditions[index]?.languageTag
      }
      let titles = PutioTrackLabel.distinct(
        languages.enumerated().map { index, language in
          PutioTrackLabel.audioTitle(language: language, name: nil, index: index)
        })
      return options.enumerated().map { index, option in
        PutioVideoAudioTrack(
          id: index, title: titles[index],
          detail: details[option]
            ?? renditions[index].flatMap {
              PutioTrackLabel.audioDetail(codec: $0.codec, profile: nil, channels: $0.channels)
            },
          languageTag: languages[index])
      }
    }

    public static func rendition(
      of option: AVMediaSelectionOption, at index: Int, count: Int,
      in renditions: [PutioAudioRendition]
    ) -> PutioAudioRendition? {
      let named = renditions.filter { $0.name == option.displayName }
      if named.count == 1 { return named[0] }
      return renditions.count == count ? renditions[index] : nil
    }

    public static func details(
      for options: [AVMediaSelectionOption], streams: [PutioOriginalAudioStream]
    ) -> [AVMediaSelectionOption: String] {
      guard !streams.isEmpty, options.count == streams.count else { return [:] }
      var details: [AVMediaSelectionOption: String] = [:]
      for (option, stream) in zip(options, streams) {
        details[option] = PutioTrackLabel.audioDetail(
          codec: stream.codec, profile: stream.profile, channels: stream.channels)
      }
      return details
    }

    private static let masterPlaylistLimit = 256 * 1024

    @MainActor
    public static func audioRenditions(
      of item: AVPlayerItem, session: URLSession = .shared
    ) async -> [PutioAudioRendition] {
      guard let master = (item.asset as? AVURLAsset)?.url else { return [] }
      return await audioRenditions(master: master, session: session)
    }

    static func audioRenditions(
      master: URL, session: URLSession
    ) async -> [PutioAudioRendition] {
      guard master.scheme == "http" || master.scheme == "https",
        master.pathExtension.lowercased() == "m3u8",
        let (bytes, _) = try? await session.bytes(
          for: URLRequest(url: master, timeoutInterval: 10))
      else { return [] }
      var data = Data()
      do {
        for try await byte in bytes {
          data.append(byte)
          guard data.count <= masterPlaylistLimit else { return [] }
        }
      } catch {
        return []
      }
      guard let text = String(data: data, encoding: .utf8) else { return [] }
      return PutioAudioRendition.parse(masterPlaylist: text, relativeTo: master)
    }

    /// put.io marks the first subtitle `DEFAULT` unless the account disables
    /// auto-selection, and omits subtitles when they are hidden. AVPlayer's
    /// automatic media selection leaves that default off under the system's
    /// automatic caption setting, so the player applies the start pick
    /// itself: the remembered language, then the account default.
    @MainActor
    @discardableResult
    public static func selectStartSubtitle(
      in item: AVPlayerItem, policy: PutioSubtitleStartupPolicy,
      remembered: PutioRememberedSubtitle?,
      beforeSelecting: (AVMediaSelectionOption) -> Void = { _ in }
    ) async -> AVMediaSelectionOption? {
      guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) else {
        return nil
      }
      let options = PutioMediaSelection.subtitleOptions(of: group)
      let tracks = subtitleTracks(options, defaultOption: group.defaultOption)
      if let start = policy.startingTrack(in: tracks, remembered: remembered) {
        beforeSelecting(options[start.id])
        item.select(options[start.id], in: group)
        return options[start.id]
      } else if item.currentMediaSelection.selectedMediaOption(in: group)
        .map({ !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) }) ?? false
      {
        item.select(nil, in: group)
      }
      return nil
    }

    @MainActor
    public static func restore(_ tracks: PutioVideoTrackSelection, in item: AVPlayerItem) async {
      if let index = tracks.audio,
        let audible = try? await item.asset.loadMediaSelectionGroup(for: .audible),
        audible.options.indices.contains(index)
      {
        item.select(audible.options[index], in: audible)
      }
      guard let legible = try? await item.asset.loadMediaSelectionGroup(for: .legible) else {
        return
      }
      let options = PutioMediaSelection.subtitleOptions(of: legible)
      if let index = tracks.subtitle {
        guard options.indices.contains(index) else { return }
        item.select(options[index], in: legible)
      } else {
        item.select(nil, in: legible)
      }
    }
  }

  public enum PutioVideoLength {
    public static func seconds(of url: URL) async -> Double? {
      guard let duration = try? await AVURLAsset(url: url).load(.duration), duration.isNumeric
      else { return nil }
      return CMTimeGetSeconds(duration)
    }
  }
#endif
