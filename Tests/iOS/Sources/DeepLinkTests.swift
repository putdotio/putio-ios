import Foundation
import PutioCore
import XCTest

@testable import Putio

@MainActor
final class DeepLinkTests: XCTestCase {
  func testLegacyPathFormsAndOwnedHTTPSHosts() throws {
    for value in [
      "putio:///files/410", "putio://put.io/files/410", "https://put.io/files/410",
      "https://app.put.io/files/410",
    ] {
      XCTAssertEqual(
        PutioDeepLink.parse(try XCTUnwrap(URL(string: value))), .file(.init(rawValue: 410)))
    }
    XCTAssertEqual(PutioDeepLink.parse(try url("/files/0")), .file(.root))
    XCTAssertEqual(PutioDeepLink.parse(try url("/history")), .history)
    XCTAssertEqual(PutioDeepLink.parse(try url("/settings")), .account)
    XCTAssertEqual(PutioDeepLink.parse(try url("/account")), .account)
  }

  func testForeignHostsAndAuthenticationCallbacksAreNotConsumed() throws {
    for value in [
      "https://evilput.io/files/1", "https://put.io.invalid/files/1", "http://put.io/files/1",
      "other:///files/1", "putio://files/1", "putio://history",
      "putio://auth#access_token=synthetic&state=synthetic",
    ] {
      XCTAssertNil(PutioDeepLink.parse(try XCTUnwrap(URL(string: value))))
    }
  }

  func testMalformedOrDeferredOwnedRoutesHaveAnExplicitOutcome() throws {
    for path in [
      "/files", "/files/-1", "/files/+1", "/files/1/extra", "/files/999999999999999999999999",
      "/files/1?oauth_token=synthetic", "/files/1#synthetic", "/files/%31", "/files//1",
      "/downloads/1", "/link",
    ] {
      XCTAssertEqual(PutioDeepLink.parse(try url(path)), .unavailable, path)
    }
    XCTAssertEqual(
      PutioDeepLink.parse(try XCTUnwrap(URL(string: "https://user:synthetic@put.io/files/1"))),
      .unavailable)
    XCTAssertEqual(
      PutioDeepLink.parse(try XCTUnwrap(URL(string: "https://put.io:8443/files/1"))), .unavailable)
  }

  func testColdSignedOutIntentResolvesAfterSignInWithoutAnEarlyRequest() async throws {
    let model = PutioDeepLinkModel()
    model.receive(try url("/files/10"))
    model.updateSession(.signedOut(nil))
    var calls = 0
    let load: @MainActor @Sendable (PutioFileID) async throws -> PutioFileItem = { id in
      calls += 1
      return BrowserTestFixtures.item(id: id.rawValue, kind: .folder)
    }
    await model.resolve(historyEnabled: true, file: load)
    XCTAssertEqual(calls, 0)
    model.updateSession(.authenticating)
    model.updateSession(.signedIn(account()))
    await model.resolve(historyEnabled: true, file: load)
    XCTAssertEqual(calls, 1)
    XCTAssertEqual(model.destination, .files([folder(10)], file: nil))
    XCTAssertNil(model.pending)
    model.consumeDestination()
    await model.resolve(historyEnabled: true, file: load)
    XCTAssertEqual(calls, 1)
  }

  func testWarmRootAndStaticRoutesDoNotFetchFileMetadata() async throws {
    let model = signedInModel()
    for (path, destination) in [
      ("/files/0", PutioDeepLinkDestination.files([], file: nil)),
      ("/history", .history), ("/account", .account),
    ] {
      model.receive(try url(path))
      await model.resolve(historyEnabled: true) { _ in
        XCTFail("static route fetched metadata")
        throw PutioRuntimeError.unknown
      }
      XCTAssertEqual(model.destination, destination)
    }
  }

  func testVideoBuildsAuthoritativeAncestorPath() async throws {
    let model = signedInModel()
    model.receive(try url("/files/30"))
    let video = BrowserTestFixtures.item(id: 30, parentID: 20)
    await model.resolve(historyEnabled: true) { id in
      switch id.rawValue {
      case 30: video
      case 20: BrowserTestFixtures.item(id: 20, parentID: 10, kind: .folder)
      default: BrowserTestFixtures.item(id: 10, kind: .folder)
      }
    }
    XCTAssertEqual(
      model.destination, .files([folder(10), folder(20)], file: PutioFileRoute(item: video)))
  }

  func testDeepFolderPathPreservesEveryAncestor() async throws {
    let model = signedInModel()
    model.receive(try url("/files/100"))
    var requestedIDs: [Int] = []
    await model.resolve(historyEnabled: true) { id in
      requestedIDs.append(id.rawValue)
      return BrowserTestFixtures.item(
        id: id.rawValue, parentID: id.rawValue - 1, kind: .folder)
    }
    XCTAssertEqual(requestedIDs, Array((1...100).reversed()))
    XCTAssertEqual(model.destination, .files((1...100).map(folder), file: nil))
    XCTAssertNil(model.failure)
  }

  func testCancelledResolutionAdvancesTheRequestSoTheOwningTaskRefires() async throws {
    let model = signedInModel()
    model.receive(try url("/files/10"))
    let before = model.request
    let started = expectation(description: "resolve started")
    let task = Task { @MainActor in
      await model.resolve(historyEnabled: true) { _ in
        started.fulfill()
        try await Task.sleep(for: .seconds(10))
        return BrowserTestFixtures.item(id: 10, kind: .folder)
      }
    }
    await fulfillment(of: [started], timeout: 2)
    task.cancel()
    await task.value
    XCTAssertNotNil(model.pending, "a cancelled run keeps the link pending")
    XCTAssertNotEqual(model.request, before, "the request must change so .task(id:) refires")
    XCTAssertFalse(model.isLoading)
    await model.resolve(historyEnabled: true) { _ in BrowserTestFixtures.item(id: 10, kind: .folder)
    }
    XCTAssertEqual(model.destination, .files([folder(10)], file: nil))
  }

  func testMissingFileRetryAndNonMediaFilesRouteToTheirScreens() async throws {
    let model = signedInModel()
    model.receive(try url("/files/10"))
    await model.resolve(historyEnabled: true) { _ in throw PutioRuntimeError.notFound }
    XCTAssertEqual(model.failure, .missingFile)
    model.retry()
    await model.resolve(historyEnabled: true) { _ in BrowserTestFixtures.item(id: 10, kind: .folder)
    }
    XCTAssertEqual(model.destination, .files([folder(10)], file: nil))
    model.consumeDestination()
    model.receive(try url("/files/20"))
    let document = BrowserTestFixtures.item(id: 20, parentID: 10, kind: .pdf)
    await model.resolve(historyEnabled: true) { id in
      id.rawValue == 20 ? document : BrowserTestFixtures.item(id: 10, kind: .folder)
    }
    XCTAssertEqual(model.destination, .files([folder(10)], file: PutioFileRoute(item: document)))
    model.consumeDestination()
    model.receive(try url("/files/21"))
    let archive = BrowserTestFixtures.item(id: 21, kind: .other("ARCHIVE"))
    await model.resolve(historyEnabled: true) { _ in archive }
    XCTAssertEqual(model.destination, .files([], file: PutioFileRoute(item: archive)))
    XCTAssertEqual(PutioFileRoute(item: archive).openAction, .unsupported(.init(item: archive)))
    model.cancel()
    XCTAssertFalse(model.presentsStatus)
  }

  func testDisabledHistoryCannotSelectAnAbsentTab() async throws {
    let model = signedInModel()
    model.receive(try url("/history"))
    await model.resolve(historyEnabled: false) { _ in throw PutioRuntimeError.unknown }
    XCTAssertEqual(model.failure, .historyDisabled)
    XCTAssertNil(model.destination)
  }

  func testCyclesAndMismatchedMetadataFailWithoutNavigation() async throws {
    for mismatch in [false, true] {
      let model = signedInModel()
      model.receive(try url("/files/10"))
      await model.resolve(historyEnabled: true) { _ in
        BrowserTestFixtures.item(id: mismatch ? 11 : 10, parentID: 10, kind: .folder)
      }
      XCTAssertEqual(model.failure, .invalidResponse)
      XCTAssertNil(model.destination)
    }
  }

  func testNewLinkSupersedesLateLookup() async throws {
    let model = signedInModel()
    let pending = PendingDeepLinkFile()
    defer { pending.finish() }
    model.receive(try url("/files/10"))
    let task = Task { await model.resolve(historyEnabled: true) { _ in try await pending.load() } }
    try await pending.waitForRequest()
    model.receive(try url("/account"))
    await model.resolve(historyEnabled: true) { _ in throw PutioRuntimeError.unknown }
    pending.finish()
    await task.value
    XCTAssertEqual(model.destination, .account)
    XCTAssertFalse(model.isLoading)
  }

  func testSignOutOrAccountSwitchRejectsLateLookupAndClearsIntent() async throws {
    for nextState in [PutioSessionState.signingOut, .signedIn(account(id: 2))] {
      let model = signedInModel()
      let pending = PendingDeepLinkFile()
      defer { pending.finish() }
      model.receive(try url("/files/10"))
      let task = Task {
        await model.resolve(historyEnabled: true) { _ in try await pending.load() }
      }
      try await pending.waitForRequest()
      model.updateSession(nextState)
      pending.finish()
      await task.value
      model.updateSession(.signedIn(account(id: 2)))
      XCTAssertNil(model.destination)
      XCTAssertNil(model.pending)
      XCTAssertFalse(model.isLoading)
    }
  }

  private func signedInModel() -> PutioDeepLinkModel {
    let model = PutioDeepLinkModel()
    model.updateSession(.signedIn(account()))
    return model
  }

  private func url(_ path: String) throws -> URL {
    try XCTUnwrap(URL(string: "putio://put.io\(path)"))
  }

  private func folder(_ id: Int) -> PutioFolderRoute {
    PutioFolderRoute(id: PutioFileID(rawValue: id), title: "File \(id)")
  }

  private func account(id: Int = 1) -> PutioAccountSnapshot {
    PutioAccountSnapshot(
      id: id, username: "Fixture", email: "fixture@example.invalid", suggestNextVideo: false,
      rememberVideoTime: true, defaultSort: nil, historyEnabled: true, trashEnabled: true,
      storage: .init(availableBytes: 1, totalBytes: 1, usedBytes: 0))
  }
}

@MainActor
private final class PendingDeepLinkFile {
  private var continuation: CheckedContinuation<PutioFileItem, any Error>?

  func load() async throws -> PutioFileItem {
    try await withCheckedThrowingContinuation { continuation = $0 }
  }

  func waitForRequest() async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while continuation == nil {
      guard ContinuousClock.now < deadline else {
        throw NSError(domain: "DeepLinkTests", code: 1)
      }
      try await Task.sleep(for: .milliseconds(1))
    }
  }

  func finish() {
    continuation?.resume(returning: BrowserTestFixtures.item(id: 10, kind: .folder))
    continuation = nil
  }
}
