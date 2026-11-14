import Foundation
import PutioSDK

/// What the Direct play engine decodes, and which player opens an original.
/// The engine's FFmpeg build decodes every codec but the ones listed here, as
/// its formats page states; AVPlayer keeps the MP4 and MOV files it plays.
public enum PutioDirectPlayDecoders {
  static let undecodableVideo: Set<String> = [
    "prores", "mjpeg", "cinepak", "rawvideo", "mpeg1video", "flashsv",
  ]
  static let undecodableAudio: Set<String> = ["ac4", "mpegh_3d_audio"]
  static let avPlayerContainers: Set<String> = ["mov", "mp4", "m4a", "m4v"]

  public static func canDecodeAudio(codec: String?) -> Bool {
    guard let codec = codec?.lowercased(), !codec.isEmpty, codec != "none" else { return false }
    return !undecodableAudio.contains(codec)
  }

  /// The SDK asks this only for an original with `media_info` and no playback
  /// issue: the first video stream and the first audio stream must decode.
  static func support(of media: PutioMediaInfo) -> PutioOriginalVideoSupport {
    if let video = media.streams.first(where: { $0.codecType == .video }),
      let codec = video.codecName?.lowercased(), undecodableVideo.contains(codec)
    {
      return .unsupported(.videoUnsupported)
    }
    if let audio = media.streams.first(where: { $0.codecType == .audio }),
      !canDecodeAudio(codec: audio.codecName)
    {
      return .unsupported(.audioUnsupported)
    }
    return .playable
  }

  /// AVPlayer opens an MP4 or MOV original when it plays every video and
  /// audio stream's codec; everything else goes through the engine.
  static func player(
    for media: PutioMediaInfo, isPlayableInAVPlayer: (String) -> Bool
  ) -> PutioOriginalPlayback.Player {
    let containers = Set(
      (media.format?.name ?? "").lowercased().split(separator: ",").map {
        $0.trimmingCharacters(in: .whitespaces)
      })
    guard !containers.isDisjoint(with: avPlayerContainers) else { return .engine }
    let streams = media.streams.filter { $0.codecType == .video || $0.codecType == .audio }
    let codecs = streams.compactMap { stream in
      stream.rfc6381Codec.flatMap { $0.isEmpty ? nil : $0 }
    }
    guard !streams.isEmpty, codecs.count == streams.count else { return .engine }
    let type = ["video/mp4", "codecs=\"\(codecs.joined(separator: ","))\""].joined(separator: "; ")
    return isPlayableInAVPlayer(type) ? .avPlayer : .engine
  }

  static func audioStreams(of media: PutioMediaInfo?) -> [PutioOriginalAudioStream] {
    (media?.streams ?? []).filter { $0.codecType == .audio }.map {
      PutioOriginalAudioStream(codec: $0.codecName, profile: $0.profile, channels: $0.channels)
    }
  }
}

/// A Direct play track's menu row: its language, and for audio its codec and
/// layout as Android writes them, such as "E-AC3 · 5.1".
public enum PutioTrackLabel {
  static let separator = " · "

  public static func audioTitle(language: String?, name: String?, index: Int) -> String {
    named(language: language, name: name)
      ?? String(localized: "Audio track \(index + 1)", bundle: .module)
  }

  public static func subtitleTitle(language: String?, name: String?, index: Int) -> String {
    named(language: language, name: name)
      ?? String(localized: "Subtitle \(index + 1)", bundle: .module)
  }

  private static func named(language: String?, name: String?) -> String? {
    if let language = languageName(language) { return language }
    guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty
    else { return nil }
    return name
  }

  public static func audioDetail(codec: String?, profile: String?, channels: Int?) -> String? {
    let parts = [codecName(codec, profile: profile), layout(channels)].compactMap { $0 }
    return parts.isEmpty ? nil : parts.joined(separator: separator)
  }

  static func codecName(_ codec: String?, profile: String?) -> String? {
    guard let codec = codec?.lowercased() else { return nil }
    if codec.hasPrefix("pcm_") { return "PCM" }
    if codec == "dts", profile?.uppercased().contains("HD") == true { return "DTS-HD" }
    if titleCasedCodecs.contains(codec) { return codec.capitalized }
    return codecNames[codec]
  }

  private static let titleCasedCodecs: Set = ["opus", "vorbis"]
  private static let codecNames = [
    "aac": "AAC", "ac3": "AC3", "eac3": "E-AC3", "ac4": "AC4", "mp3": "MP3", "mp2": "MP2",
    "flac": "FLAC", "alac": "ALAC", "dts": "DTS", "truehd": "TrueHD",
  ]

  static func layout(_ channels: Int?) -> String? {
    switch channels {
    case nil, 0?: nil
    case 1?: String(localized: "mono", bundle: .module)
    case 2?: String(localized: "stereo", bundle: .module)
    case 6?: "5.1"
    case 8?: "7.1"
    case let count?: String(localized: "\(count) channels", bundle: .module)
    }
  }

  static func languageName(_ code: String?) -> String? {
    guard let code = code?.trimmingCharacters(in: .whitespaces), !code.isEmpty,
      code.lowercased() != "und"
    else { return nil }
    let language = Locale.Language(identifier: code)
    let identifier = language.languageCode?.identifier(.alpha2) ?? code
    guard let name = Locale.current.localizedString(forLanguageCode: identifier),
      name.lowercased() != identifier.lowercased(), name.lowercased() != code.lowercased()
    else { return nil }
    return name
  }

  /// The two-letter code the harness probes report, or the code as given.
  public static func languageCode(_ code: String?) -> String? {
    guard let code, !code.isEmpty else { return nil }
    return Locale.Language(identifier: code).languageCode?.identifier(.alpha2) ?? code
  }
}
