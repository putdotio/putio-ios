#if DEBUG
  import Foundation

  enum HarnessHeldStream {
    static func path(
      environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
      guard let value = environment["PUTIO_HARNESS_HELD_STREAM"] else { return nil }
      let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
      guard parts.count == 2, ["start", "middle"].contains(parts[0]),
        !parts[1].isEmpty, parts[1].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" })
      else { return nil }
      return "held/\(parts[1])/\(parts[0])/held.m3u8"
    }
  }
#endif
