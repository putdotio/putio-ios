import PutioCore
import XCTest

@testable import Putio

@MainActor
final class ExternalPlaybackTests: XCTestCase {
  private final class Opener: PutioExternalURLOpening, @unchecked Sendable {
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
    PutioFileRoute(item: BrowserTestFixtures.item(id: 412, parentID: 410, kind: kind))
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

  func testInstalledHandoffOpensOnceAndClearsThePendingRoute() async {
    let opener = Opener()
    var resolved = 0
    let model = PutioExternalPlaybackModel(opener: opener, returnsToFolder: true) { _ in
      resolved += 1
      return self.source
    }
    await model.open(route())
    XCTAssertEqual(model.outcome, .opened)
    XCTAssertFalse(model.presentsOutcome)
    XCTAssertNil(model.pendingRoute)
    XCTAssertEqual(resolved, 1)
    XCTAssertEqual(opener.opened.count, 1)
    XCTAssertEqual(opener.opened.first?.scheme, "vlc-x-callback")
    XCTAssertEqual(
      opener.opened.first?.query?.contains("x-success=putio:///files/410"), true)
  }

  func testMissingVLCSkipsResolutionAndOffersTheStore() async {
    let opener = Opener()
    opener.installed = false
    var resolved = 0
    let model = PutioExternalPlaybackModel(opener: opener, returnsToFolder: true) { _ in
      resolved += 1
      return self.source
    }
    await model.open(route())
    XCTAssertEqual(model.outcome, .notInstalled)
    XCTAssertTrue(model.presentsOutcome)
    XCTAssertEqual(resolved, 0)
    await model.openAppStore()
    XCTAssertEqual(opener.opened, [PutioVLCHandoff.appStoreURL])
    XCTAssertNil(model.outcome)
  }

  func testResolutionAndLaunchFailuresStayRetryable() async {
    let opener = Opener()
    var attempts = 0
    let model = PutioExternalPlaybackModel(opener: opener, returnsToFolder: false) { _ in
      attempts += 1
      if attempts == 1 { throw PutioRuntimeError.transient }
      return self.source
    }
    await model.open(route())
    guard case .failed(let failure) = model.outcome else {
      return XCTFail("\(model.outcome as Any)")
    }
    XCTAssertTrue(failure.canRetry)
    XCTAssertEqual(failure.message, "Check your connection and try again.")
    opener.accepts = false
    await model.retry()
    XCTAssertEqual(model.outcome, .failed(.launch))
    XCTAssertNotNil(model.pendingRoute)
    opener.accepts = true
    await model.retry()
    XCTAssertEqual(model.outcome, .opened)
    XCTAssertEqual(attempts, 3)
  }

  func testNotFoundIsTerminalAndSessionLossDismissesQuietly() async {
    let opener = Opener()
    let missing = PutioExternalPlaybackModel(opener: opener, returnsToFolder: false) { _ in
      throw PutioRuntimeError.notFound
    }
    await missing.open(route())
    guard case .failed(let failure) = missing.outcome else {
      return XCTFail("\(missing.outcome as Any)")
    }
    XCTAssertFalse(failure.canRetry)

    let expired = PutioExternalPlaybackModel(opener: opener, returnsToFolder: false) { _ in
      throw PutioRuntimeError.sessionExpired
    }
    await expired.open(route())
    XCTAssertNil(expired.outcome)
    XCTAssertNil(expired.pendingRoute)
    XCTAssertTrue(opener.opened.isEmpty)
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
