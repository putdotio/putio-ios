import PutioCore
import SwiftUI

#if DEBUG
  enum HarnessPlaybackFixtureError: Error {
    case invalidResource
    case missingResource
  }

  struct HarnessFileSelectionProbe: View {
    let route: PutioFileRoute

    var body: some View {
      Color.clear
        .frame(width: 1, height: 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Selected file route")
        .accessibilityValue(selectionValue)
        .accessibilityIdentifier("files.selection")
        .allowsHitTesting(false)
    }

    private var selectionValue: String {
      "id=\(route.id.rawValue);parent=\(route.item.parentID.rawValue);kind=\(kindName)"
    }

    private var kindName: String {
      switch route.item.kind {
      case .folder: "folder"
      case .video: "video"
      case .audio: "audio"
      case .image: "image"
      case .pdf: "pdf"
      case .other: "other"
      }
    }
  }

  /// Re-renders on every handed-off URL so the recorded summary stays current.
  struct HarnessExternalPlaybackProbe: View {
    let requestCount: Int

    var body: some View {
      Color.clear
        .frame(width: 1, height: 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("External playback requests")
        .accessibilityValue(HarnessExternalURLOpener.summary())
        .accessibilityIdentifier("vlc.requests")
        .allowsHitTesting(false)
    }
  }

  struct HarnessPresentedVideoProbe: View {
    let route: PutioVideoRoute

    var body: some View {
      Color.clear
        .frame(width: 1, height: 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Presented video route")
        .accessibilityValue("id=\(route.id.rawValue)")
        .accessibilityIdentifier("video.presented-route")
        .allowsHitTesting(false)
    }
  }

  struct HarnessPlaybackPositionProbe: View {
    let fileID: PutioFileID
    let seconds: Int

    var body: some View {
      Color.clear
        .frame(width: 1, height: 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position reported")
        .accessibilityValue("id=\(fileID.rawValue);seconds=\(seconds)")
        .accessibilityIdentifier("video.position-reported")
        .allowsHitTesting(false)
    }
  }

  /// Records handoff requests for the journey instead of leaving the app. The
  /// tokened stream URL is reduced to its scheme, host, and path before it is
  /// exposed.
  final class HarnessExternalURLOpener: PutioExternalURLOpening, @unchecked Sendable {
    let vlcInstalled: Bool
    private static var requests: [String] = []
    private static let lock = NSLock()

    init(vlcInstalled: Bool) {
      self.vlcInstalled = vlcInstalled
    }

    static func summary() -> String {
      lock.withLock { "\(requests.count)|\(requests.last ?? "")" }
    }

    @MainActor func canOpen(_ url: URL) -> Bool {
      url.scheme == PutioVLCHandoff.scheme ? vlcInstalled : true
    }

    @MainActor func open(_ url: URL) async -> Bool {
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
      return true
    }
  }

#endif
