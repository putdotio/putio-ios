import PutioCore
import XCTest

@testable import Putio

private actor ControlledFolderLoader {
  private struct PendingRequest {
    let folderID: PutioFileID
    let continuation: CheckedContinuation<PutioFolderContents, any Error>
  }

  private var nextRequest = 0
  private var pending: [Int: PendingRequest] = [:]

  func load(folderID: PutioFileID) async throws -> PutioFolderContents {
    let request = nextRequest
    nextRequest += 1
    return try await withCheckedThrowingContinuation { continuation in
      pending[request] = PendingRequest(folderID: folderID, continuation: continuation)
    }
  }

  func waitForRequestCount(_ expected: Int) async {
    while nextRequest < expected {
      await Task.yield()
    }
  }

  func requestCount() -> Int {
    nextRequest
  }

  func folderID(for request: Int) -> PutioFileID {
    guard let pending = pending[request] else {
      preconditionFailure("request \(request) is not pending")
    }
    return pending.folderID
  }

  func succeed(request: Int, with contents: PutioFolderContents) {
    guard let pending = pending.removeValue(forKey: request) else {
      preconditionFailure("request \(request) is not pending")
    }
    pending.continuation.resume(returning: contents)
  }

  func fail(request: Int, with error: Error) {
    guard let pending = pending.removeValue(forKey: request) else {
      preconditionFailure("request \(request) is not pending")
    }
    pending.continuation.resume(throwing: error)
  }
}

private actor LoadStartProbe {
  private var started = false

  func markStarted() {
    started = true
  }

  func waitUntilStarted() async {
    while !started {
      await Task.yield()
    }
  }
}

@MainActor
final class PutioFolderModelTests: XCTestCase {
  func testInitialLoadRunsOnceAndUsesStableFolderID() async {
    let loader = ControlledFolderLoader()
    let loaded = BrowserTestFixtures.contents(
      folderID: 42,
      items: [BrowserTestFixtures.item(id: 7, parentID: 42)]
    )
    let model = PutioFolderModel(folderID: PutioFileID(rawValue: 42)) { folderID in
      try await loader.load(folderID: folderID)
    }

    let loadTask = Task { await model.loadIfNeeded() }
    await loader.waitForRequestCount(1)
    let requestedFolderID = await loader.folderID(for: 0)
    XCTAssertEqual(requestedFolderID, PutioFileID(rawValue: 42))
    await loader.succeed(request: 0, with: loaded)
    await loadTask.value

    XCTAssertEqual(model.state, .loaded(loaded))
    await model.loadIfNeeded()
    let requestCount = await loader.requestCount()
    XCTAssertEqual(requestCount, 1)
  }

  func testInitialEmptyFolderLoadsAsEmptyContent() async {
    let empty = BrowserTestFixtures.contents(items: [])
    let model = PutioFolderModel(folderID: .root) { _ in empty }

    await model.loadIfNeeded()

    XCTAssertEqual(model.state, .loaded(empty))
  }

  func testFailureThenRetryReturnsToLoadingAndSucceeds() async {
    let loader = ControlledFolderLoader()
    let recovered = BrowserTestFixtures.contents(
      items: [BrowserTestFixtures.item(id: 9)]
    )
    let model = PutioFolderModel(folderID: .root) { folderID in
      try await loader.load(folderID: folderID)
    }

    let initialTask = Task { await model.loadIfNeeded() }
    await loader.waitForRequestCount(1)
    await loader.fail(request: 0, with: PutioRuntimeError.transient)
    await initialTask.value

    guard case .failed(let failure) = model.state else {
      return XCTFail("expected failed, got \(model.state)")
    }
    XCTAssertEqual(failure.kind, .transient)

    let retryTask = Task { await model.retry() }
    await loader.waitForRequestCount(2)
    XCTAssertEqual(model.state, .loading)
    await loader.succeed(request: 1, with: recovered)
    await retryTask.value

    XCTAssertEqual(model.state, .loaded(recovered))
  }

  func testInitialSessionFailureNeverBecomesAnInlineBrowserError() async {
    let model = PutioFolderModel(folderID: .root) { _ in
      throw PutioRuntimeError.authenticationRequired
    }

    await model.loadIfNeeded()

    XCTAssertEqual(model.state, .loading)
    XCTAssertNil(model.refreshFailure)
    XCTAssertNil(
      PutioBrowserErrorPresentation(error: PutioRuntimeError.authenticationRequired)
    )
    XCTAssertNil(PutioBrowserErrorPresentation(error: PutioRuntimeError.sessionExpired))
  }

  func testActiveCancellationErrorBecomesARecoverableFailure() async {
    let model = PutioFolderModel(folderID: .root) { _ in
      throw CancellationError()
    }

    await model.loadIfNeeded()

    guard case .failed(let failure) = model.state else {
      return XCTFail("expected failed, got \(model.state)")
    }
    XCTAssertEqual(failure.kind, .unknown)
  }

  func testLifecycleCancellationAllowsInitialLoadToRunAgain() async {
    let probe = LoadStartProbe()
    let loaded = BrowserTestFixtures.contents(
      items: [BrowserTestFixtures.item(id: 1)]
    )
    var attempts = 0
    let model = PutioFolderModel(folderID: .root) { _ in
      attempts += 1
      if attempts == 1 {
        await probe.markStarted()
        try await Task.sleep(for: .seconds(60))
      }
      return loaded
    }

    let initialTask = Task { await model.loadIfNeeded() }
    await probe.waitUntilStarted()
    initialTask.cancel()
    await initialTask.value
    await model.loadIfNeeded()

    XCTAssertEqual(attempts, 2)
    XCTAssertEqual(model.state, .loaded(loaded))
  }

  func testReentryDuringCancelledInitialLoadUnwindRestartsTheLoad() async {
    let loader = ControlledFolderLoader()
    let loaded = BrowserTestFixtures.contents(
      items: [BrowserTestFixtures.item(id: 3)]
    )
    let model = PutioFolderModel(folderID: .root) { folderID in
      try await loader.load(folderID: folderID)
    }

    let firstVisit = Task { await model.loadIfNeeded() }
    await loader.waitForRequestCount(1)
    firstVisit.cancel()

    // The next visit starts before the cancelled attempt finishes unwinding.
    let secondVisit = Task { await model.loadIfNeeded() }
    await loader.waitForRequestCount(2)
    await loader.succeed(request: 1, with: loaded)
    await secondVisit.value
    XCTAssertEqual(model.state, .loaded(loaded))

    // The late unwind of the superseded attempt must not clobber the result.
    await loader.fail(request: 0, with: CancellationError())
    await firstVisit.value
    XCTAssertEqual(model.state, .loaded(loaded))
  }

  func testRefreshPreservesRowsAndSurfacesRecoverableFailure() async {
    let loader = ControlledFolderLoader()
    let original = BrowserTestFixtures.contents(
      items: [BrowserTestFixtures.item(id: 1)]
    )
    let refreshed = BrowserTestFixtures.contents(
      items: [BrowserTestFixtures.item(id: 2)]
    )
    let model = PutioFolderModel(
      folderID: .root,
      load: { folderID in try await loader.load(folderID: folderID) },
      initialContents: original
    )

    let failedRefresh = Task { await model.refresh() }
    await loader.waitForRequestCount(1)
    XCTAssertEqual(model.state, .loaded(original))
    await loader.fail(request: 0, with: PutioRuntimeError.rateLimited)
    await failedRefresh.value

    XCTAssertEqual(model.state, .loaded(original))
    XCTAssertEqual(model.refreshFailure?.kind, .rateLimited)

    let successfulRefresh = Task { await model.refresh() }
    await loader.waitForRequestCount(2)
    XCTAssertEqual(model.state, .loaded(original))
    XCTAssertNil(model.refreshFailure)
    await loader.succeed(request: 1, with: refreshed)
    await successfulRefresh.value

    XCTAssertEqual(model.state, .loaded(refreshed))
    XCTAssertNil(model.refreshFailure)
  }

  func testPlaybackRefreshTargetsOnlyTheOwningFolder() async {
    let loader = ControlledFolderLoader()
    let original = BrowserTestFixtures.contents(
      folderID: 42,
      items: [BrowserTestFixtures.item(id: 1, parentID: 42)]
    )
    let refreshed = BrowserTestFixtures.contents(
      folderID: 42,
      items: [BrowserTestFixtures.item(id: 2, parentID: 42)]
    )
    let model = PutioFolderModel(
      folderID: PutioFileID(rawValue: 42),
      load: { folderID in try await loader.load(folderID: folderID) },
      initialContents: original
    )

    await model.refresh(
      for: PutioFolderRefreshRequest(id: 1, folderID: PutioFileID(rawValue: 7))
    )
    let requestCount = await loader.requestCount()
    XCTAssertEqual(requestCount, 0)

    let refresh = Task {
      await model.refresh(
        for: PutioFolderRefreshRequest(id: 2, folderID: PutioFileID(rawValue: 42))
      )
    }
    await loader.waitForRequestCount(1)
    await loader.succeed(request: 0, with: refreshed)
    await refresh.value

    XCTAssertEqual(model.state, .loaded(refreshed))
  }

  func testRefreshSessionExpiryPreservesRowsWithoutAnInlineBrowserError() async {
    let original = BrowserTestFixtures.contents(
      items: [BrowserTestFixtures.item(id: 1)]
    )
    let model = PutioFolderModel(
      folderID: .root,
      load: { _ in throw PutioRuntimeError.sessionExpired },
      initialContents: original
    )

    await model.refresh()

    XCTAssertEqual(model.state, .loaded(original))
    XCTAssertNil(model.refreshFailure)
  }

  func testEmptyFolderRefreshFailureRemainsRecoverable() async {
    let empty = BrowserTestFixtures.contents(items: [])
    let model = PutioFolderModel(
      folderID: .root,
      load: { _ in throw PutioRuntimeError.transient },
      initialContents: empty
    )

    await model.refresh()

    XCTAssertEqual(model.state, .loaded(empty))
    XCTAssertEqual(model.refreshFailure?.kind, .transient)
  }

  func testRefreshCancellationRestoresPriorContent() async {
    let probe = LoadStartProbe()
    let original = BrowserTestFixtures.contents(
      items: [BrowserTestFixtures.item(id: 1)]
    )
    let model = PutioFolderModel(
      folderID: .root,
      load: { _ in
        await probe.markStarted()
        try await Task.sleep(for: .seconds(60))
        return BrowserTestFixtures.contents(items: [])
      },
      initialContents: original
    )

    let refreshTask = Task { await model.refresh() }
    await probe.waitUntilStarted()
    refreshTask.cancel()
    await refreshTask.value

    XCTAssertEqual(model.state, .loaded(original))
    XCTAssertNil(model.refreshFailure)
  }

  func testLaterGenerationDropsStaleSuccessAndError() async {
    let loader = ControlledFolderLoader()
    let original = BrowserTestFixtures.contents(
      items: [BrowserTestFixtures.item(id: 1)]
    )
    let newest = BrowserTestFixtures.contents(
      items: [BrowserTestFixtures.item(id: 2)]
    )
    let newestAgain = BrowserTestFixtures.contents(
      items: [BrowserTestFixtures.item(id: 3)]
    )
    let stale = BrowserTestFixtures.contents(
      items: [BrowserTestFixtures.item(id: 999)]
    )
    let model = PutioFolderModel(
      folderID: .root,
      load: { folderID in try await loader.load(folderID: folderID) },
      initialContents: original
    )

    let first = Task { await model.refresh() }
    await loader.waitForRequestCount(1)
    let second = Task { await model.refresh() }
    await loader.waitForRequestCount(2)
    await loader.succeed(request: 1, with: newest)
    await second.value
    await loader.succeed(request: 0, with: stale)
    await first.value
    XCTAssertEqual(model.state, .loaded(newest))

    let third = Task { await model.refresh() }
    await loader.waitForRequestCount(3)
    let fourth = Task { await model.refresh() }
    await loader.waitForRequestCount(4)
    await loader.succeed(request: 3, with: newestAgain)
    await fourth.value
    await loader.fail(request: 2, with: PutioRuntimeError.transient)
    await third.value

    XCTAssertEqual(model.state, .loaded(newestAgain))
    XCTAssertNil(model.refreshFailure)
  }

  func testLaterGenerationDropsStaleCancellation() async {
    let loader = ControlledFolderLoader()
    let original = BrowserTestFixtures.contents(
      items: [BrowserTestFixtures.item(id: 1)]
    )
    let newest = BrowserTestFixtures.contents(
      items: [BrowserTestFixtures.item(id: 2)]
    )
    let model = PutioFolderModel(
      folderID: .root,
      load: { folderID in try await loader.load(folderID: folderID) },
      initialContents: original
    )

    let stale = Task { await model.refresh() }
    await loader.waitForRequestCount(1)
    let current = Task { await model.refresh() }
    await loader.waitForRequestCount(2)
    await loader.succeed(request: 1, with: newest)
    await current.value
    await loader.fail(request: 0, with: CancellationError())
    await stale.value

    XCTAssertEqual(model.state, .loaded(newest))
    XCTAssertNil(model.refreshFailure)
  }
}
