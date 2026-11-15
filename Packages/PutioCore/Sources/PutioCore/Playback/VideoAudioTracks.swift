import Foundation

public struct PutioAudioRendition: Equatable, Sendable {
  public let name: String?
  public let languageTag: String?
  public let channels: Int?
  public let codec: String?
  public let uri: URL?

  public init(
    name: String?, languageTag: String?, channels: Int?, codec: String?, uri: URL? = nil
  ) {
    self.name = name
    self.languageTag = languageTag
    self.channels = channels
    self.codec = codec
    self.uri = uri
  }

  public static func parse(masterPlaylist text: String, relativeTo master: URL? = nil)
    -> [PutioAudioRendition]
  {
    let lines = text.split(whereSeparator: \.isNewline).map(String.init)
    var codecsByGroup: [String: String] = [:]
    for line in lines where line.hasPrefix("#EXT-X-STREAM-INF:") {
      let attributes = Self.attributes(of: line)
      guard let group = attributes["AUDIO"], codecsByGroup[group] == nil,
        let codec = attributes["CODECS"]?.split(separator: ",").lazy
          .map({ $0.trimmingCharacters(in: .whitespaces) }).compactMap(Self.codec).first
      else { continue }
      codecsByGroup[group] = codec
    }
    return lines.filter { $0.hasPrefix("#EXT-X-MEDIA:") }.compactMap { line in
      let attributes = Self.attributes(of: line)
      guard attributes["TYPE"] == "AUDIO" else { return nil }
      return PutioAudioRendition(
        name: attributes["NAME"],
        languageTag: attributes["LANGUAGE"],
        channels: attributes["CHANNELS"].flatMap { Int($0.prefix { $0.isNumber }) },
        codec: attributes["GROUP-ID"].flatMap { codecsByGroup[$0] },
        uri: attributes["URI"].flatMap { URL(string: $0, relativeTo: master)?.absoluteURL })
    }
  }

  static func codec(_ rfc6381: String) -> String? {
    let lowered = rfc6381.lowercased()
    switch lowered {
    case "mp4a.40.34", "mp4a.6b", "mp4a.69", ".mp3": return "mp3"
    case "ac-3": return "ac3"
    case "ec-3", "ec+3": return "eac3"
    case "ac-4": return "ac4"
    case "opus", "flac", "alac": return lowered
    case "dtsc", "dtse", "dtsh", "dtsl": return "dts"
    case "mlpa": return "truehd"
    default: return lowered.hasPrefix("mp4a.40") ? "aac" : nil
    }
  }

  private static func attributes(of line: String) -> [String: String] {
    guard let colon = line.firstIndex(of: ":") else { return [:] }
    var result: [String: String] = [:]
    var rest = line[line.index(after: colon)...]
    while !rest.isEmpty {
      guard let equals = rest.firstIndex(of: "=") else { break }
      let key = rest[..<equals].trimmingCharacters(in: .whitespaces)
      rest = rest[rest.index(after: equals)...]
      let value: Substring
      if rest.first == "\"" {
        let body = rest.dropFirst()
        let close = body.firstIndex(of: "\"") ?? body.endIndex
        value = body[..<close]
        rest = close == body.endIndex ? body[close...] : body[body.index(after: close)...]
      } else {
        let comma = rest.firstIndex(of: ",") ?? rest.endIndex
        value = rest[..<comma]
        rest = rest[comma...]
      }
      if rest.first == "," { rest = rest.dropFirst() }
      result[key] = String(value)
    }
    return result
  }
}
