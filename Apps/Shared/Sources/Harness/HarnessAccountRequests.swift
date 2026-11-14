import Foundation
import Observation

#if DEBUG
  @MainActor @Observable
  final class HarnessAccountRequests {
    static let shared = HarnessAccountRequests()

    private(set) var entries: [String] = []

    nonisolated static func record(_ request: URLRequest) {
      guard let entry = entry(for: request) else { return }
      DispatchQueue.main.async {
        MainActor.assumeIsolated { shared.entries.append(entry) }
      }
    }

    nonisolated static func entry(for request: URLRequest) -> String? {
      guard let method = request.httpMethod, method != "GET", let path = request.url?.path,
        path.hasPrefix("/v2/oauth/grants/") || path == "/v2/oauth2/oob/code"
          || path == "/v2/account/clear"
      else { return nil }
      guard let body = HarnessSeededAPI.requestBodyData(request), !body.isEmpty else {
        return "\(method) \(path)"
      }
      guard let object = try? JSONSerialization.jsonObject(with: body),
        let canonical = try? JSONSerialization.data(
          withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
      else { return "\(method) \(path) <unreadable body>" }
      return "\(method) \(path) \(String(decoding: canonical, as: UTF8.self))"
    }
  }
#endif
