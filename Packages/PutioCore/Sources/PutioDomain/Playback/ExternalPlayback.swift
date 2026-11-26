import Foundation
import Observation

/// The VLC handoff contract: `vlc-x-callback://x-callback-url/stream?url=…`
/// streams the tokened download URL, and `x-success` brings the user back to
/// the file's folder when this bundle registers the `putio` scheme.
public enum PutioVLCHandoff {
  public static let scheme = "vlc-x-callback"
  public static let probeURL = URL(string: "\(scheme)://x-callback-url/stream")!
  public static let appStoreURL = URL(string: "https://apps.apple.com/app/id650377962")!

  public static var missingTitle: String {
    String(localized: "VLC is not installed", bundle: .module)
  }

  public static func streamURL(for source: URL, returnTo folderID: PutioFileID?) -> URL? {
    var components = URLComponents()
    components.scheme = scheme
    components.host = "x-callback-url"
    components.path = "/stream"
    var items = [URLQueryItem(name: "url", value: encoded(source.absoluteString))]
    if let folderID {
      items.append(
        URLQueryItem(name: "x-success", value: encoded("putio:///files/\(folderID.rawValue)")))
    }
    components.percentEncodedQueryItems = items
    return components.url
  }

  /// VLC splits the raw query on `&` and `=` before decoding, so nested URLs
  /// encode both.
  private static func encoded(_ value: String) -> String? {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "&=+")
    return value.addingPercentEncoding(withAllowedCharacters: allowed)
  }

  /// Nightly installs beside the store app without the `putio` scheme, so its
  /// handoff omits the return link instead of bouncing into the wrong app.
  public static func registersPutioScheme(bundle: Bundle = .main) -> Bool {
    let types = bundle.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
    return types.contains { type in
      (type["CFBundleURLSchemes"] as? [String])?.contains("putio") == true
    }
  }
}

public protocol PutioExternalURLOpening: Sendable {
  @MainActor func canOpen(_ url: URL) -> Bool
  @MainActor func canHandOff(_ url: URL) -> Bool
  @MainActor func open(_ url: URL) async -> Bool
}

extension PutioExternalURLOpening {
  @MainActor public func canHandOff(_ url: URL) -> Bool { canOpen(url) }
}

public enum PutioExternalPlaybackFailure: Equatable {
  case downloadTokenUnavailable
  case refused
  case failed(PutioRuntimeError)

  public static func resolving(_ error: Error) -> Self? {
    if error is PutioDownloadTokenUnavailable { return .downloadTokenUnavailable }
    switch error as? PutioRuntimeError {
    case .authenticationRequired, .sessionExpired: return nil
    case .some(let error): return .failed(error)
    case nil: return .failed(.unknown)
    }
  }

  public func message(fileName name: String) -> String {
    switch self {
    case .downloadTokenUnavailable:
      String(localized: "Couldn’t prepare “\(name)” for VLC. Sign in again.", bundle: .module)
    case .refused:
      String(localized: "Install VLC to open “\(name)”.", bundle: .module)
    case .failed(let error):
      String(
        localized: "Couldn’t prepare “\(name)” for VLC. \(Self.reason(error))", bundle: .module)
    }
  }

  private static func reason(_ error: PutioRuntimeError) -> String {
    switch error {
    case .rateLimited:
      String(
        localized: "put.io is receiving too many requests. Try again shortly.", bundle: .module)
    case .transient:
      String(localized: "Check your connection and try again.", bundle: .module)
    case .authenticationRequired, .sessionExpired, .notFound, .invalidResponse, .unknown:
      String(localized: "put.io is temporarily unavailable. Try again.", bundle: .module)
    }
  }
}

public typealias PutioExternalPlaybackResolve =
  @MainActor @Sendable (PutioFileID) async throws -> PutioFileDownloadSource

@MainActor
@Observable
public final class PutioExternalPlaybackModel {
  public private(set) var isVLCInstalled = false
  public private(set) var missingVLCRoute: PutioFileRoute?
  public var toast: PutioToast?
  public private(set) var openedRequestCount = 0
  private let opener: PutioExternalURLOpening
  private let resolve: PutioExternalPlaybackResolve
  private let returnsToFolder: Bool
  private var generation: UInt64 = 0

  public init(
    opener: PutioExternalURLOpening,
    returnsToFolder: Bool = PutioVLCHandoff.registersPutioScheme(),
    resolve: @escaping PutioExternalPlaybackResolve
  ) {
    self.opener = opener
    self.returnsToFolder = returnsToFolder
    self.resolve = resolve
  }

  public func refreshInstallation() {
    isVLCInstalled = opener.canOpen(PutioVLCHandoff.probeURL)
  }

  public func open(_ route: PutioFileRoute) async {
    guard route.supportsExternalPlayback else { return }
    generation &+= 1
    let request = generation
    missingVLCRoute = nil
    toast = nil
    guard opener.canHandOff(PutioVLCHandoff.probeURL) else {
      isVLCInstalled = false
      missingVLCRoute = route
      return
    }
    do {
      let source = try await resolve(route.id)
      try Task.checkCancellation()
      guard request == generation else { return }
      guard
        let url = PutioVLCHandoff.streamURL(
          for: source.url, returnTo: returnsToFolder ? route.item.parentID : nil)
      else {
        report(.refused, for: route)
        return
      }
      let opened = await opener.open(url)
      openedRequestCount += 1
      guard request == generation else { return }
      if !opened { report(.refused, for: route) }
    } catch {
      guard request == generation, !Task.isCancelled, !(error is CancellationError),
        let failure = PutioExternalPlaybackFailure.resolving(error)
      else { return }
      report(failure, for: route)
    }
  }

  public func openAppStore() async {
    missingVLCRoute = nil
    _ = await opener.open(PutioVLCHandoff.appStoreURL)
    openedRequestCount += 1
    refreshInstallation()
  }

  public func dismissMissingVLC() {
    missingVLCRoute = nil
  }

  private func report(_ failure: PutioExternalPlaybackFailure, for route: PutioFileRoute) {
    toast = PutioToast(failure.message(fileName: route.item.name))
  }
}
