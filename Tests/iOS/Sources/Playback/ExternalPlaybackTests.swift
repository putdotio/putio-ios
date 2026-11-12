import PutioCore
import XCTest

@testable import Putio

@MainActor
final class ExternalPlaybackTests: XCTestCase {
  @MainActor
  private final class Opener: PutioExternalURLOpening {
    var installed = true
    var accepts = true
    var opened: [URL] = []

    func canOpen(_ url: URL) -> Bool { url.scheme == PutioVLCHandoff.scheme ? installed : true }

    func open(_ url: URL) async -> Bool {
      opened.append(url)
      return accepts
    }
  }

  private let source = PutioFileDownloadSource(
    id: PutioFileID(rawValue: 412), kind: .video, name: "Movie.mkv",
    url: URL(string: "https://api.put.io/v2/files/412/download?oauth_token=secret")!)

  private func route(kind: PutioFileKind = .video) -> PutioFileRoute {
    PutioFileRoute(
      item: BrowserTestFixtures.item(id: 412, parentID: 410, name: "Movie.mkv", kind: kind))
  }

  func testStreamURLCarriesTheSourceAndAnOptionalReturnLink() throws {
    let url = try XCTUnwrap(
      PutioVLCHandoff.streamURL(for: source.url, returnTo: PutioFileID(rawValue: 410)))
    let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
    XCTAssertEqual(components.scheme, "vlc-x-callback")
    XCTAssertEqual(components.host, "x-callback-url")
    XCTAssertEqual(components.path, "/stream")
    XCTAssertEqual(
      components.queryItems?.first { $0.name == "url" }?.value, source.url.absoluteString)
    XCTAssertEqual(
      components.queryItems?.first { $0.name == "x-success" }?.value, "putio:///files/410")

    let detached = try XCTUnwrap(PutioVLCHandoff.streamURL(for: source.url, returnTo: nil))
    XCTAssertNil(
      URLComponents(url: detached, resolvingAgainstBaseURL: false)?.queryItems?
        .first { $0.name == "x-success" })
  }

  func testInstalledHandoffOpensTheOriginalStreamOnce() async throws {
    let opener = Opener()
    var resolved = 0
    let model = PutioExternalPlaybackModel(opener: opener, returnsToFolder: true) { _ in
      resolved += 1
      return self.source
    }
    await model.open(route())
    XCTAssertNil(model.toast)
    XCTAssertNil(model.missingVLCRoute)
    XCTAssertEqual(resolved, 1)
    XCTAssertEqual(opener.opened.count, 1)
    let handoff = try XCTUnwrap(
      URLComponents(url: try XCTUnwrap(opener.opened.first), resolvingAgainstBaseURL: false))
    XCTAssertEqual(handoff.scheme, "vlc-x-callback")
    XCTAssertEqual(
      handoff.queryItems?.first { $0.name == "url" }?.value,
      "https://api.put.io/v2/files/412/download?oauth_token=secret")
    XCTAssertEqual(
      handoff.queryItems?.first { $0.name == "x-success" }?.value, "putio:///files/410")
  }

  func testMissingVLCSkipsResolutionAndOffersTheStore() async {
    let opener = Opener()
    let model = PutioExternalPlaybackModel(opener: opener, returnsToFolder: true) { _ in
      XCTFail("resolved a file for a missing VLC")
      return self.source
    }
    model.refreshInstallation()
    XCTAssertTrue(model.isVLCInstalled)
    opener.installed = false
    await model.open(route())
    XCTAssertEqual(model.missingVLCRoute?.id, PutioFileID(rawValue: 412))
    XCTAssertFalse(model.isVLCInstalled)
    XCTAssertNil(model.toast)
    opener.installed = true
    await model.openAppStore()
    XCTAssertEqual(opener.opened, [PutioVLCHandoff.appStoreURL])
    XCTAssertNil(model.missingVLCRoute)
    XCTAssertTrue(model.isVLCInstalled)
  }

  func testFailuresShowAndroidsMessageAndTheNextTapHandsOff() async {
    let opener = Opener()
    var errors: [Error] = [
      PutioDownloadTokenUnavailable(), PutioRuntimeError.transient, PutioRuntimeError.rateLimited,
      PutioRuntimeError.notFound, PutioRuntimeError.invalidResponse,
    ]
    let model = PutioExternalPlaybackModel(opener: opener, returnsToFolder: false) { _ in
      if !errors.isEmpty { throw errors.removeFirst() }
      return self.source
    }
    let expected = [
      "Couldn’t prepare “Movie.mkv” for VLC. Sign in again.",
      "Couldn’t prepare “Movie.mkv” for VLC. Check your connection and try again.",
      "Couldn’t prepare “Movie.mkv” for VLC. "
        + "put.io is receiving too many requests. Try again shortly.",
      "Couldn’t prepare “Movie.mkv” for VLC. put.io is temporarily unavailable. Try again.",
      "Couldn’t prepare “Movie.mkv” for VLC. put.io is temporarily unavailable. Try again.",
    ]
    for message in expected {
      await model.open(route())
      XCTAssertEqual(model.toast?.text, message)
      XCTAssertNil(model.toast?.action)
      XCTAssertNil(model.missingVLCRoute)
    }
    XCTAssertTrue(opener.opened.isEmpty)

    opener.accepts = false
    await model.open(route())
    XCTAssertEqual(model.toast?.text, "Install VLC to open “Movie.mkv”.")
    opener.accepts = true
    await model.open(route())
    XCTAssertNil(model.toast)
    XCTAssertEqual(opener.opened.count, 2)
  }

  func testSessionLossShowsNothing() async {
    let opener = Opener()
    let model = PutioExternalPlaybackModel(opener: opener, returnsToFolder: false) { _ in
      throw PutioRuntimeError.sessionExpired
    }
    await model.open(route())
    XCTAssertNil(model.toast)
    XCTAssertNil(model.missingVLCRoute)
    XCTAssertTrue(opener.opened.isEmpty)
  }

  func testALaterTapSupersedesAFailureInFlight() async {
    let opener = Opener()
    let gate = Gate()
    var attempts = 0
    let model = PutioExternalPlaybackModel(opener: opener, returnsToFolder: false) { _ in
      attempts += 1
      if attempts == 1 {
        await gate.wait()
        throw PutioRuntimeError.transient
      }
      return self.source
    }
    let first = Task { await model.open(self.route()) }
    while attempts == 0 { await Task.yield() }
    await model.open(route())
    gate.open()
    await first.value
    XCTAssertNil(model.toast)
    XCTAssertEqual(opener.opened.count, 1)
  }

  @MainActor
  private final class Gate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
      await withCheckedContinuation { continuation = $0 }
    }

    func open() {
      continuation?.resume()
      continuation = nil
    }
  }

  func testNonMediaRoutesAreIgnored() async {
    let opener = Opener()
    let model = PutioExternalPlaybackModel(opener: opener, returnsToFolder: false) { _ in
      XCTFail("resolved a preview route")
      return self.source
    }
    await model.open(route(kind: .image))
    XCTAssertNil(model.outcome)
    XCTAssertTrue(opener.opened.isEmpty)
  }
}
