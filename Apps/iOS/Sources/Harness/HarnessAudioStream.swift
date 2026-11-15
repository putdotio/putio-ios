#if DEBUG
  import Foundation

  enum HarnessAudioStream {
    enum Tracks: String {
      case one
      case failing
      case fastForward = "fast-forward"
    }

    static let argument = "--putio-harness-audio-tracks"

    static func path(arguments: [String] = ProcessInfo.processInfo.arguments) -> String? {
      guard let flag = arguments.firstIndex(of: argument), arguments.indices.contains(flag + 1)
      else { return nil }
      guard let tracks = Tracks(rawValue: arguments[flag + 1]) else {
        preconditionFailure("unknown \(argument) value \(arguments[flag + 1])")
      }
      return switch tracks {
      case .one: "multi-audio/multi-audio-one.m3u8"
      case .failing: "multi-audio/multi-audio-failing.m3u8"
      case .fastForward: "multi-audio/multi-audio-speed.m3u8"
      }
    }
  }
#endif
