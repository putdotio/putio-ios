import Foundation
import Observation
import PutioCore
import SwiftUI
import UIKit

/// The VLC handoff contract: `vlc-x-callback://x-callback-url/stream?url=…`
/// streams the tokened download URL, and `x-success` brings the user back to
/// the file's folder when this bundle registers the `putio` scheme.
enum PutioVLCHandoff {
  static let scheme = "vlc-x-callback"
  static let probeURL = URL(string: "\(scheme)://x-callback-url/stream")!
  static let appStoreURL = URL(string: "https://apps.apple.com/app/id650377962")!

  static func streamURL(for source: URL, returnTo folderID: PutioFileID?) -> URL? {
    var components = URLComponents()
    components.scheme = scheme
    components.host = "x-callback-url"
    components.path = "/stream"
    var items = [URLQueryItem(name: "url", value: source.absoluteString)]
    if let folderID {
      items.append(
        URLQueryItem(name: "x-success", value: "putio:///files/\(folderID.rawValue)"))
    }
    components.queryItems = items
    return components.url
  }

  /// Nightly installs beside the store app without the `putio` scheme, so its
  /// handoff omits the return link instead of bouncing into the wrong app.
  static func registersPutioScheme(bundle: Bundle = .main) -> Bool {
    let types = bundle.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
    return types.contains { type in
      (type["CFBundleURLSchemes"] as? [String])?.contains("putio") == true
    }
  }
}

protocol PutioExternalURLOpening: Sendable {
  @MainActor func canOpen(_ url: URL) -> Bool
  @MainActor func open(_ url: URL) async -> Bool
}

struct PutioSystemURLOpener: PutioExternalURLOpening {
  @MainActor func canOpen(_ url: URL) -> Bool {
    UIApplication.shared.canOpenURL(url)
  }

  @MainActor func open(_ url: URL) async -> Bool {
    await UIApplication.shared.open(url)
  }
}

enum PutioExternalPlaybackFailure: Equatable {
  case downloadTokenUnavailable
  case refused
  case failed(PutioRuntimeError)

  static func resolving(_ error: Error) -> Self? {
    if error is PutioDownloadTokenUnavailable { return .downloadTokenUnavailable }
    switch error as? PutioRuntimeError {
    case .authenticationRequired, .sessionExpired: return nil
    case .some(let error): return .failed(error)
    case nil: return .failed(.unknown)
    }
  }

  func message(fileName name: String) -> String {
    switch self {
    case .downloadTokenUnavailable:
      String(localized: "Couldn’t prepare “\(name)” for VLC. Sign in again.")
    case .refused:
      String(localized: "Install VLC to open “\(name)”.")
    case .failed(let error):
      String(localized: "Couldn’t prepare “\(name)” for VLC. \(Self.reason(error))")
    }
  }

  private static func reason(_ error: PutioRuntimeError) -> String {
    switch error {
    case .rateLimited:
      String(localized: "put.io is receiving too many requests. Try again shortly.")
    case .transient:
      String(localized: "Check your connection and try again.")
    case .authenticationRequired, .sessionExpired, .notFound, .invalidResponse, .unknown:
      String(localized: "put.io is temporarily unavailable. Try again.")
    }
  }
}

typealias PutioExternalPlaybackResolve =
  @MainActor @Sendable (PutioFileID) async throws -> PutioFileDownloadSource

@MainActor
@Observable
final class PutioExternalPlaybackModel {
  private(set) var isVLCInstalled = false
  private(set) var missingVLCRoute: PutioFileRoute?
  var toast: PutioToast?
  private(set) var openedRequestCount = 0
  private let opener: PutioExternalURLOpening
  private let resolve: PutioExternalPlaybackResolve
  private let returnsToFolder: Bool
  private var generation: UInt64 = 0

  init(
    opener: PutioExternalURLOpening,
    returnsToFolder: Bool = PutioVLCHandoff.registersPutioScheme(),
    resolve: @escaping PutioExternalPlaybackResolve
  ) {
    self.opener = opener
    self.returnsToFolder = returnsToFolder
    self.resolve = resolve
  }

  func refreshInstallation() {
    isVLCInstalled = opener.canOpen(PutioVLCHandoff.probeURL)
  }

  func open(_ route: PutioFileRoute) async {
    guard route.supportsExternalPlayback else { return }
    generation &+= 1
    let request = generation
    missingVLCRoute = nil
    toast = nil
    guard opener.canOpen(PutioVLCHandoff.probeURL) else {
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

  func openAppStore() async {
    missingVLCRoute = nil
    _ = await opener.open(PutioVLCHandoff.appStoreURL)
    openedRequestCount += 1
    refreshInstallation()
  }

  func dismissMissingVLC() {
    missingVLCRoute = nil
  }

  private func report(_ failure: PutioExternalPlaybackFailure, for route: PutioFileRoute) {
    toast = PutioToast(failure.message(fileName: route.item.name))
  }
}

struct PutioExternalPlaybackPresentation: ViewModifier {
  let model: PutioExternalPlaybackModel

  func body(content: Content) -> some View {
    content.alert(
      String(localized: "VLC is not installed"),
      isPresented: Binding(
        get: { model.missingVLCRoute != nil },
        set: { if !$0 { model.dismissMissingVLC() } }
      )
    ) {
      Button(String(localized: "Cancel"), role: .cancel) { model.dismissMissingVLC() }
      Button(String(localized: "Get VLC")) { Task { await model.openAppStore() } }
        .keyboardShortcut(.defaultAction)
    } message: {
      Text(String(localized: "Install VLC for iOS from the App Store to stream this file there."))
    }
  }
}
