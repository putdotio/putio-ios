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

enum PutioExternalPlaybackOutcome: Equatable {
  case opened
  case notInstalled
  case failed(PutioExternalPlaybackFailure)
}

struct PutioExternalPlaybackFailure: Equatable {
  let title: String
  let message: String
  let canRetry: Bool

  static func resolving(_ error: Error) -> Self? {
    switch error as? PutioRuntimeError {
    case .authenticationRequired, .sessionExpired:
      return nil
    case .notFound:
      return Self(
        title: "File not found", message: "It may have been moved or deleted.", canRetry: false)
    case .rateLimited:
      return Self(
        title: "Could not open in VLC",
        message: "put.io is receiving too many requests. Try again shortly.", canRetry: true)
    case .transient:
      return Self(
        title: "Could not open in VLC", message: "Check your connection and try again.",
        canRetry: true)
    case .invalidResponse:
      return Self(
        title: "Could not open in VLC", message: "put.io returned an invalid response. Try again.",
        canRetry: true)
    case .unknown, nil:
      return Self(
        title: "Could not open in VLC", message: "put.io could not prepare this file. Try again.",
        canRetry: true)
    }
  }

  static let launch = Self(
    title: "Could not open in VLC", message: "VLC did not accept the file. Try again.",
    canRetry: true)
}

typealias PutioExternalPlaybackResolve =
  @MainActor @Sendable (PutioFileID) async throws -> PutioFileDownloadSource

@MainActor
@Observable
final class PutioExternalPlaybackModel {
  private(set) var pendingRoute: PutioFileRoute?
  private(set) var outcome: PutioExternalPlaybackOutcome?
  private(set) var isResolving = false
  /// Counts URLs handed to the opener; the harness probe re-renders on it.
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

  var presentsOutcome: Bool {
    switch outcome {
    case .notInstalled, .failed: true
    case .opened, nil: false
    }
  }

  func open(_ route: PutioFileRoute) async {
    guard route.supportsExternalPlayback else { return }
    generation &+= 1
    let request = generation
    pendingRoute = route
    outcome = nil
    guard opener.canOpen(PutioVLCHandoff.probeURL) else {
      outcome = .notInstalled
      return
    }
    isResolving = true
    defer { if request == generation { isResolving = false } }
    do {
      let source = try await resolve(route.id)
      try Task.checkCancellation()
      guard request == generation else { return }
      guard
        let url = PutioVLCHandoff.streamURL(
          for: source.url, returnTo: returnsToFolder ? route.item.parentID : nil)
      else {
        outcome = .failed(.launch)
        return
      }
      let opened = await opener.open(url)
      openedRequestCount += 1
      guard request == generation else { return }
      outcome = opened ? .opened : .failed(.launch)
      if opened { pendingRoute = nil }
    } catch {
      guard request == generation, !Task.isCancelled, !(error is CancellationError) else {
        return
      }
      guard let failure = PutioExternalPlaybackFailure.resolving(error) else {
        dismiss()
        return
      }
      outcome = .failed(failure)
    }
  }

  func retry() async {
    guard let pendingRoute else { return }
    await open(pendingRoute)
  }

  func openAppStore() async {
    dismiss()
    _ = await opener.open(PutioVLCHandoff.appStoreURL)
    openedRequestCount += 1
  }

  func dismiss() {
    generation &+= 1
    pendingRoute = nil
    outcome = nil
    isResolving = false
  }
}
