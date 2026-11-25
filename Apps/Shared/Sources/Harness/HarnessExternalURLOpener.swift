import Foundation
import PutioCore

#if DEBUG
  /// Records handoff requests for the journey instead of leaving the app. The
  /// tokened stream URL is reduced to its scheme, host, and path before it is
  /// exposed.
  final class HarnessExternalURLOpener: PutioExternalURLOpening, @unchecked Sendable {
    private var vlcInstalled: Bool
    private var hidesVLCAtHandoff: Bool
    private var refusesNextHandoff: Bool
    private static var requests: [String] = []
    private static let lock = NSLock()

    init(vlcInstalled: Bool, hidesVLCAtHandoff: Bool, refusesFirstHandoff: Bool) {
      self.vlcInstalled = vlcInstalled || hidesVLCAtHandoff
      self.hidesVLCAtHandoff = hidesVLCAtHandoff
      refusesNextHandoff = refusesFirstHandoff
    }

    static func summary() -> String {
      lock.withLock { "\(requests.count)|\(requests.last ?? "")" }
    }

    @MainActor func canOpen(_ url: URL) -> Bool {
      url.scheme == PutioVLCHandoff.scheme ? vlcInstalled : true
    }

    @MainActor func canHandOff(_ url: URL) -> Bool {
      canOpen(url) && !(url.scheme == PutioVLCHandoff.scheme && hidesVLCAtHandoff)
    }

    @MainActor func open(_ url: URL) async -> Bool {
      if url == PutioVLCHandoff.appStoreURL {
        vlcInstalled = true
        hidesVLCAtHandoff = false
      }
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
      var summary = "\(url.scheme ?? "")://\(components?.host ?? "")\(components?.path ?? "")"
      if let target = components?.queryItems?.first(where: { $0.name == "url" })?.value,
        let targetURL = URL(string: target)
      {
        summary += "?url=\(targetURL.scheme ?? "")://\(targetURL.host ?? "")\(targetURL.path)"
      }
      if let success = components?.queryItems?.first(where: { $0.name == "x-success" })?.value {
        summary += "&x-success=\(success)"
      }
      Self.lock.withLock { Self.requests.append(summary) }
      guard url.scheme == PutioVLCHandoff.scheme, refusesNextHandoff else { return true }
      refusesNextHandoff = false
      return false
    }
  }

  extension HarnessExternalURLOpener {
    static func launchArguments(
      _ arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> HarnessExternalURLOpener {
      HarnessExternalURLOpener(
        vlcInstalled: arguments.contains("--putio-harness-vlc-installed"),
        hidesVLCAtHandoff: arguments.contains("--putio-harness-vlc-removed"),
        refusesFirstHandoff: arguments.contains("--putio-harness-vlc-refuses-once"))
    }
  }
#endif
