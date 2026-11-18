import Foundation

public enum PutioSubtitleSource: Equatable, Sendable {
  case embedded
  case folder
  case openSubtitles

  public init(apiSource: String) {
    switch apiSource {
    case "mkv": self = .embedded
    case "folder": self = .folder
    default: self = .openSubtitles
    }
  }

  public var isInFile: Bool { self == .embedded }
}

public struct PutioSubtitleTrack: Equatable, Sendable {
  public let id: Int
  public let title: String
  public let languageTag: String?
  public let isDefault: Bool

  public init(id: Int, title: String, languageTag: String?, isDefault: Bool = false) {
    self.id = id
    self.title = title
    self.languageTag = languageTag
    self.isDefault = isDefault
  }
}

public enum PutioSubtitleLanguage {
  public static func key(_ tag: String?) -> String {
    let base =
      tag?.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { $0.lowercased() } ?? ""
    guard !base.isEmpty, !undetermined.contains(base) else { return "und" }
    let code = bibliographic[base] ?? base
    return Locale.Language(identifier: code).languageCode?.identifier(.alpha2) ?? code
  }

  public static func matches(_ lhs: String?, _ rhs: String?) -> Bool {
    key(lhs) == key(rhs)
  }

  private static let undetermined: Set<String> = ["und", "unknown", "xx", "zxx", "mul"]

  private static let bibliographic: [String: String] = [
    "alb": "sqi", "arm": "hye", "baq": "eus", "bur": "mya", "chi": "zho", "cze": "ces",
    "dut": "nld", "fre": "fra", "geo": "kat", "ger": "deu", "gre": "ell", "ice": "isl",
    "mac": "mkd", "mao": "mri", "may": "msa", "per": "fas", "pob": "por", "rum": "ron",
    "scc": "srp", "scr": "hrv", "slo": "slk", "tib": "bod", "wel": "cym",
  ]
}

public struct PutioSubtitleMenu: Equatable, Sendable {
  public struct Row: Equatable, Sendable {
    public let track: PutioSubtitleTrack
    public let title: String
  }

  public let rows: [Row]

  public init(tracks: [PutioSubtitleTrack]) {
    rows = tracks.map { Row(track: $0, title: $0.title) }
  }

  public var isEmpty: Bool { rows.isEmpty }
}

public enum PutioRememberedSubtitle: Equatable, Sendable {
  case off
  case language(String)
}

public struct PutioSubtitleStartupPolicy: Equatable, Sendable {
  public let showsSubtitles: Bool
  public let autoSelects: Bool

  public init(showsSubtitles: Bool, autoSelects: Bool) {
    self.showsSubtitles = showsSubtitles
    self.autoSelects = autoSelects
  }

  public init(hideSubtitles: Bool, dontAutoSelectSubtitles: Bool) {
    self.init(showsSubtitles: !hideSubtitles, autoSelects: !dontAutoSelectSubtitles)
  }

  public static let accountDefault = PutioSubtitleStartupPolicy(
    showsSubtitles: true, autoSelects: true)

  public func startingTrack(
    in tracks: [PutioSubtitleTrack], remembered: PutioRememberedSubtitle?
  ) -> PutioSubtitleTrack? {
    guard showsSubtitles else { return nil }
    switch remembered {
    case .off:
      return nil
    case .language(let tag):
      let sameLanguage = tracks.filter { PutioSubtitleLanguage.matches($0.languageTag, tag) }
      if let pick = sameLanguage.first(where: \.isDefault) ?? sameLanguage.first {
        return pick
      }
    case nil:
      break
    }
    guard autoSelects else { return nil }
    return tracks.first(where: \.isDefault)
  }
}

@MainActor
public final class PutioSubtitleMemory {
  private let defaults: UserDefaults
  private let key: String

  public init(defaults: UserDefaults = .standard, key: String = "putio.video.subtitle-language") {
    self.defaults = defaults
    self.key = key
  }

  public var remembered: PutioRememberedSubtitle? {
    guard let stored = defaults.string(forKey: key), !stored.isEmpty else { return nil }
    if stored == Self.offValue { return .off }
    guard PutioSubtitleLanguage.key(stored) != "und" else { return nil }
    return .language(stored)
  }

  public func remember(_ track: PutioSubtitleTrack?) {
    guard let track else {
      defaults.set(Self.offValue, forKey: key)
      return
    }
    guard let tag = track.languageTag, PutioSubtitleLanguage.key(tag) != "und" else { return }
    defaults.set(tag, forKey: key)
  }

  public func forget(_ track: PutioSubtitleTrack) {
    guard case .language(let tag) = remembered,
      PutioSubtitleLanguage.matches(tag, track.languageTag)
    else { return }
    defaults.removeObject(forKey: key)
  }

  private static let offValue = "off"
}

public struct PutioSubtitleRendition: Equatable, Sendable {
  public let name: String?
  public let languageTag: String?
  public let isDefault: Bool

  public init(name: String?, languageTag: String?, isDefault: Bool = false) {
    self.name = name
    self.languageTag = languageTag
    self.isDefault = isDefault
  }
}

public enum PutioSubtitleRenditions {
  public static func renditions(inMasterPlaylist text: String) -> [PutioSubtitleRendition] {
    text.split(whereSeparator: \.isNewline).map(String.init)
      .filter { $0.hasPrefix("#EXT-X-MEDIA:") }
      .compactMap { line in
        let attributes = PutioAudioRendition.attributes(of: line)
        guard attributes["TYPE"] == "SUBTITLES" else { return nil }
        return PutioSubtitleRendition(
          name: attributes["NAME"], languageTag: attributes["LANGUAGE"],
          isDefault: attributes["DEFAULT"] == "YES")
      }
  }

  public static func uris(inMasterPlaylist text: String, relativeTo base: URL) -> [URL] {
    var uris: [URL] = []
    for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("#EXT-X-MEDIA:") {
      let attributes = line.dropFirst("#EXT-X-MEDIA:".count)
      guard attributes.range(of: #"(^|,)TYPE=SUBTITLES(,|$)"#, options: .regularExpression) != nil,
        let match = attributes.range(of: #"URI="[^"]*""#, options: .regularExpression),
        let uri = URL(string: String(attributes[match].dropFirst(5).dropLast()), relativeTo: base)
      else { continue }
      uris.append(uri.absoluteURL)
    }
    return uris
  }
}
