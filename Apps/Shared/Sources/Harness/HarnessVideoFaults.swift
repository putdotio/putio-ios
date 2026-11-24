#if DEBUG
  import Foundation

  @MainActor
  enum HarnessVideoFaults {
    enum Fault: String {
      case none
      case forbidden
      case refused
    }

    static let argument = "--putio-harness-video-faults"
    private static var remaining: [Fault]? = {
      let arguments = ProcessInfo.processInfo.arguments
      guard let flag = arguments.firstIndex(of: argument), arguments.indices.contains(flag + 1)
      else { return nil }
      return arguments[flag + 1].split(separator: ",").map { name in
        guard let fault = Fault(rawValue: String(name)) else {
          preconditionFailure("unknown \(argument) value \(name)")
        }
        return fault
      }
    }()

    static func next() -> Fault? {
      guard var faults = remaining else { return nil }
      let fault = faults.isEmpty ? Fault.none : faults.removeFirst()
      remaining = faults
      return fault
    }

    nonisolated static func url(for fault: Fault, mediaBaseURL: URL) -> URL {
      switch fault {
      case .none: mediaBaseURL.appending(path: "runtime-proof.m3u8")
      case .forbidden: mediaBaseURL.appending(path: "forbidden/runtime-proof.m3u8")
      case .refused: URL(string: "http://127.0.0.1:1/runtime-proof.m3u8")!
      }
    }
  }
#endif
