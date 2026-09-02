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

private actor SuspendedFileMutation {
  private var started = false
  private var continuation: CheckedContinuation<Void, any Error>?

  func run() async throws {
    started = true
    try await withCheckedThrowingContinuation { continuation = $0 }
  }

  func waitUntilStarted() async {
    while !started {
      await Task.yield()
    }
  }

  func succeed() {
    continuation?.resume()
    continuation = nil
  }

  func fail(with error: Error) {
    continuation?.resume(throwing: error)
    continuation = nil
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

  func testPlaybackRefreshSequencesAreIndependentPerFolder() {
    let firstFolder = PutioFileID(rawValue: 42)
    let secondFolder = PutioFileID(rawValue: 7)
    var requests = PutioFolderRefreshRequests()

    requests.request(folderID: firstFolder)
    let firstSequence = requests.sequence(for: firstFolder)
    requests.request(folderID: secondFolder)

    XCTAssertEqual(requests.sequence(for: firstFolder), firstSequence)
    XCTAssertEqual(requests.sequence(for: secondFolder), 1)

    requests.request(folderID: firstFolder)
    XCTAssertEqual(requests.sequence(for: firstFolder), 2)
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

  func testCreateFolderAppendsTheServerOwnedIdentity() async {
    let original = BrowserTestFixtures.contents(items: [])
    let created = BrowserTestFixtures.item(
      id: 91,
      parentID: 42,
      name: "Season 2",
      kind: .folder
    )
    let model = PutioFolderModel(
      folderID: PutioFileID(rawValue: 42),
      load: { _ in original },
      actions: PutioFileActions(
        createFolder: { name, parentID in
          XCTAssertEqual(name, "Season 2")
          XCTAssertEqual(parentID, PutioFileID(rawValue: 42))
          return created
        },
        renameFile: { _, _ in XCTFail("rename should not run") },
        deleteFile: { _ in XCTFail("delete should not run") }
      ),
      initialContents: original
    )

    await model.createFolder(name: "  Season 2  ")

    guard case .loaded(let contents) = model.state else {
      return XCTFail("expected loaded, got \(model.state)")
    }
    XCTAssertEqual(contents.items, [created])
    XCTAssertEqual(model.actionOutcome, .succeeded(.createFolder(name: "Season 2")))
  }

  func testFileActionsBecomeAvailableOnlyAfterTheFolderLoads() async {
    let contents = BrowserTestFixtures.contents(items: [])
    let actions = PutioFileActions(
      createFolder: { _, _ in throw PutioRuntimeError.unknown },
      renameFile: { _, _ in throw PutioRuntimeError.unknown },
      deleteFile: { _ in throw PutioRuntimeError.unknown }
    )
    let model = PutioFolderModel(
      folderID: .root,
      load: { _ in contents },
      actions: actions
    )
    let failedModel = PutioFolderModel(
      folderID: .root,
      load: { _ in throw PutioRuntimeError.transient },
      actions: actions
    )

    XCTAssertFalse(model.canStartAction)
    XCTAssertFalse(failedModel.canStartAction)
    await model.loadIfNeeded()
    await failedModel.loadIfNeeded()
    XCTAssertTrue(model.canStartAction)
    XCTAssertFalse(failedModel.canStartAction)
  }

  func testRenameIsOptimisticAndRollsBackWithRecoverableFailure() async {
    let mutation = SuspendedFileMutation()
    let item = BrowserTestFixtures.item(id: 7, name: "Original.mkv")
    let original = BrowserTestFixtures.contents(items: [item])
    let model = PutioFolderModel(
      folderID: .root,
      load: { _ in original },
      actions: PutioFileActions(
        createFolder: { _, _ in throw PutioRuntimeError.unknown },
        renameFile: { _, _ in try await mutation.run() },
        deleteFile: { _ in throw PutioRuntimeError.unknown }
      ),
      initialContents: original
    )

    let task = Task { await model.rename(item, to: "Renamed.mkv") }
    await mutation.waitUntilStarted()
    XCTAssertFalse(model.canStartAction)
    guard case .loaded(let optimistic) = model.state else {
      return XCTFail("expected loaded, got \(model.state)")
    }
    XCTAssertEqual(optimistic.items.first?.name, "Renamed.mkv")

    await mutation.fail(with: PutioRuntimeError.transient)
    await task.value

    XCTAssertEqual(model.state, .loaded(original))
    guard case .failed(let action, let failure) = model.actionOutcome else {
      return XCTFail("expected failed action, got \(String(describing: model.actionOutcome))")
    }
    XCTAssertEqual(
      action,
      .rename(fileID: item.id, oldName: "Original.mkv", newName: "Renamed.mkv")
    )
    XCTAssertEqual(failure.title, "Could not rename item")
    XCTAssertTrue(model.canStartAction)
  }

  func testMutationSupersedesAnInFlightRefresh() async {
    let loader = ControlledFolderLoader()
    let mutation = SuspendedFileMutation()
    let item = BrowserTestFixtures.item(id: 7, name: "Original.mkv")
    let original = BrowserTestFixtures.contents(items: [item])
    let stale = BrowserTestFixtures.contents(
      items: [BrowserTestFixtures.item(id: 99, name: "Stale.mkv")]
    )
    let model = PutioFolderModel(
      folderID: .root,
      load: { folderID in try await loader.load(folderID: folderID) },
      actions: PutioFileActions(
        createFolder: { _, _ in throw PutioRuntimeError.unknown },
        renameFile: { _, _ in try await mutation.run() },
        deleteFile: { _ in throw PutioRuntimeError.unknown }
      ),
      initialContents: original
    )

    let refresh = Task { await model.refresh() }
    await loader.waitForRequestCount(1)
    let rename = Task { await model.rename(item, to: "Renamed.mkv") }
    await mutation.waitUntilStarted()

    await loader.succeed(request: 0, with: stale)
    await refresh.value
    guard case .loaded(let optimistic) = model.state else {
      return XCTFail("expected loaded, got \(model.state)")
    }
    XCTAssertEqual(optimistic.items.first?.name, "Renamed.mkv")

    await mutation.succeed()
    await rename.value
    XCTAssertEqual(model.state, .loaded(optimistic))
  }

  func testRenameUsesTheLatestLoadedItemSnapshot() async {
    let staleEditorItem = BrowserTestFixtures.item(
      id: 7,
      name: "Original.mkv",
      sizeBytes: 1_024,
      resumePositionSeconds: 0
    )
    let latestItem = BrowserTestFixtures.item(
      id: 7,
      name: "Server Original.mkv",
      sizeBytes: 8_192,
      resumePositionSeconds: 137
    )
    let latestContents = BrowserTestFixtures.contents(items: [latestItem], hasMore: true)
    let model = PutioFolderModel(
      folderID: .root,
      load: { _ in latestContents },
      actions: PutioFileActions(
        createFolder: { _, _ in throw PutioRuntimeError.unknown },
        renameFile: { fileID, name in
          XCTAssertEqual(fileID, latestItem.id)
          XCTAssertEqual(name, "Renamed.mkv")
        },
        deleteFile: { _ in throw PutioRuntimeError.unknown }
      ),
      initialContents: latestContents
    )

    await model.rename(staleEditorItem, to: "Renamed.mkv")

    guard case .loaded(let renamedContents) = model.state else {
      return XCTFail("expected loaded, got \(model.state)")
    }
    guard let renamedItem = renamedContents.items.first else {
      return XCTFail("renamed item is missing")
    }
    XCTAssertEqual(renamedItem.id, latestItem.id)
    XCTAssertEqual(renamedItem.parentID, latestItem.parentID)
    XCTAssertEqual(renamedItem.name, "Renamed.mkv")
    XCTAssertEqual(renamedItem.kind, latestItem.kind)
    XCTAssertEqual(renamedItem.sizeBytes, latestItem.sizeBytes)
    XCTAssertEqual(renamedItem.createdAt, latestItem.createdAt)
    XCTAssertEqual(renamedItem.updatedAt, latestItem.updatedAt)
    XCTAssertEqual(renamedItem.resumePositionSeconds, latestItem.resumePositionSeconds)
    XCTAssertTrue(renamedContents.hasMore)
    XCTAssertEqual(
      model.actionOutcome,
      .succeeded(
        .rename(
          fileID: latestItem.id,
          oldName: "Server Original.mkv",
          newName: "Renamed.mkv"
        )
      )
    )
  }

  func testRefreshRequestedDuringMutationRunsAfterItSettles() async {
    let loader = ControlledFolderLoader()
    let mutation = SuspendedFileMutation()
    let item = BrowserTestFixtures.item(id: 7, name: "Original.mkv")
    let original = BrowserTestFixtures.contents(items: [item])
    let refreshed = BrowserTestFixtures.contents(
      items: [BrowserTestFixtures.item(id: 7, name: "Renamed.mkv", sizeBytes: 8_192)]
    )
    let model = PutioFolderModel(
      folderID: .root,
      load: { folderID in try await loader.load(folderID: folderID) },
      actions: PutioFileActions(
        createFolder: { _, _ in throw PutioRuntimeError.unknown },
        renameFile: { _, _ in try await mutation.run() },
        deleteFile: { _ in throw PutioRuntimeError.unknown }
      ),
      initialContents: original
    )

    let rename = Task { await model.rename(item, to: "Renamed.mkv") }
    await mutation.waitUntilStarted()
    await model.refresh()
    let queuedRequestCount = await loader.requestCount()
    XCTAssertEqual(queuedRequestCount, 0)

    await mutation.succeed()
    await loader.waitForRequestCount(1)
    let refreshedFolderID = await loader.folderID(for: 0)
    XCTAssertEqual(refreshedFolderID, .root)
    await loader.succeed(request: 0, with: refreshed)
    await rename.value

    XCTAssertEqual(model.state, .loaded(refreshed))
    XCTAssertEqual(
      model.actionOutcome,
      .succeeded(.rename(fileID: item.id, oldName: "Original.mkv", newName: "Renamed.mkv"))
    )
  }

  func testQueuedRefreshRunsAfterMutationCancellation() async {
    let loader = ControlledFolderLoader()
    let mutation = SuspendedFileMutation()
    let item = BrowserTestFixtures.item(id: 7, name: "Original.mkv")
    let original = BrowserTestFixtures.contents(items: [item])
    let refreshed = BrowserTestFixtures.contents(
      items: [BrowserTestFixtures.item(id: 7, name: "Server.mkv", sizeBytes: 8_192)]
    )
    let model = PutioFolderModel(
      folderID: .root,
      load: { folderID in try await loader.load(folderID: folderID) },
      actions: PutioFileActions(
        createFolder: { _, _ in throw PutioRuntimeError.unknown },
        renameFile: { _, _ in try await mutation.run() },
        deleteFile: { _ in throw PutioRuntimeError.unknown }
      ),
      initialContents: original
    )

    let rename = Task { await model.rename(item, to: "Renamed.mkv") }
    await mutation.waitUntilStarted()
    await model.refresh()
    rename.cancel()
    await mutation.succeed()
    await loader.waitForRequestCount(1)
    await loader.succeed(request: 0, with: refreshed)
    await rename.value

    XCTAssertEqual(model.state, .loaded(refreshed))
    XCTAssertNil(model.activeAction)
    XCTAssertNil(model.actionOutcome)
  }

  func testQueuedRefreshesCoalesceAfterMutationFailure() async {
    let loader = ControlledFolderLoader()
    let mutation = SuspendedFileMutation()
    let item = BrowserTestFixtures.item(id: 7, name: "Original.mkv")
    let original = BrowserTestFixtures.contents(items: [item])
    let refreshed = BrowserTestFixtures.contents(
      items: [BrowserTestFixtures.item(id: 7, name: "Server.mkv", sizeBytes: 8_192)]
    )
    let model = PutioFolderModel(
      folderID: .root,
      load: { folderID in try await loader.load(folderID: folderID) },
      actions: PutioFileActions(
        createFolder: { _, _ in throw PutioRuntimeError.unknown },
        renameFile: { _, _ in try await mutation.run() },
        deleteFile: { _ in throw PutioRuntimeError.unknown }
      ),
      initialContents: original
    )

    let rename = Task { await model.rename(item, to: "Renamed.mkv") }
    await mutation.waitUntilStarted()
    await model.refresh()
    await model.refresh()
    let queuedRequestCount = await loader.requestCount()
    XCTAssertEqual(queuedRequestCount, 0)

    await mutation.fail(with: PutioRuntimeError.transient)
    await loader.waitForRequestCount(1)
    await loader.succeed(request: 0, with: refreshed)
    await rename.value

    let finalRequestCount = await loader.requestCount()
    XCTAssertEqual(finalRequestCount, 1)
    XCTAssertEqual(model.state, .loaded(refreshed))
    guard case .failed(let action, let failure) = model.actionOutcome else {
      return XCTFail("expected failed action, got \(String(describing: model.actionOutcome))")
    }
    XCTAssertEqual(
      action,
      .rename(fileID: item.id, oldName: "Original.mkv", newName: "Renamed.mkv")
    )
    XCTAssertEqual(failure.title, "Could not rename item")
  }

  func testDeleteFailureTitleDoesNotPromiseTrashDisposition() async {
    let item = BrowserTestFixtures.item(id: 7, name: "Episode.mkv")
    let original = BrowserTestFixtures.contents(items: [item])
    let model = PutioFolderModel(
      folderID: .root,
      load: { _ in original },
      actions: PutioFileActions(
        createFolder: { _, _ in throw PutioRuntimeError.unknown },
        renameFile: { _, _ in throw PutioRuntimeError.unknown },
        deleteFile: { _ in throw PutioRuntimeError.transient }
      ),
      initialContents: original
    )

    await model.delete(item)

    guard case .failed(_, let failure) = model.actionOutcome else {
      return XCTFail("expected failed action, got \(String(describing: model.actionOutcome))")
    }
    XCTAssertEqual(failure.title, "Could not remove item")
    XCTAssertEqual(model.state, .loaded(original))
  }

  func testDeleteIsOptimisticAndSettlesAfterServerSuccess() async {
    let mutation = SuspendedFileMutation()
    let item = BrowserTestFixtures.item(id: 7, name: "Episode.mkv")
    let survivor = BrowserTestFixtures.item(id: 8)
    let original = BrowserTestFixtures.contents(items: [item, survivor])
    let model = PutioFolderModel(
      folderID: .root,
      load: { _ in original },
      actions: PutioFileActions(
        createFolder: { _, _ in throw PutioRuntimeError.unknown },
        renameFile: { _, _ in throw PutioRuntimeError.unknown },
        deleteFile: { _ in try await mutation.run() }
      ),
      initialContents: original
    )

    let task = Task { await model.delete(item) }
    await mutation.waitUntilStarted()
    guard case .loaded(let optimistic) = model.state else {
      return XCTFail("expected loaded, got \(model.state)")
    }
    XCTAssertEqual(optimistic.items, [survivor])

    await mutation.succeed()
    await task.value

    XCTAssertEqual(model.state, .loaded(optimistic))
    XCTAssertEqual(
      model.actionOutcome,
      .succeeded(.delete(fileID: item.id, name: "Episode.mkv"))
    )
  }

  func testMutationCancellationRestoresTheExactPriorContents() async {
    let mutation = SuspendedFileMutation()
    let item = BrowserTestFixtures.item(id: 7, name: "Episode.mkv")
    let original = BrowserTestFixtures.contents(items: [item])
    let model = PutioFolderModel(
      folderID: .root,
      load: { _ in original },
      actions: PutioFileActions(
        createFolder: { _, _ in throw PutioRuntimeError.unknown },
        renameFile: { _, _ in throw PutioRuntimeError.unknown },
        deleteFile: { _ in try await mutation.run() }
      ),
      initialContents: original
    )

    let task = Task { await model.delete(item) }
    await mutation.waitUntilStarted()
    task.cancel()
    await mutation.succeed()
    await task.value

    XCTAssertEqual(model.state, .loaded(original))
    XCTAssertNil(model.actionOutcome)
    XCTAssertNil(model.activeAction)
  }
}
