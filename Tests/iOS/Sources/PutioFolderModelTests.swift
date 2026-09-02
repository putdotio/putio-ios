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

private actor ControlledBulkMutation {
  private struct PendingRequest {
    let fileID: PutioFileID
    let destinationID: PutioFileID?
    let continuation: CheckedContinuation<Void, any Error>
  }

  private var nextRequest = 0
  private var pending: [Int: PendingRequest] = [:]

  func run(fileID: PutioFileID, destinationID: PutioFileID? = nil) async throws {
    let request = nextRequest
    nextRequest += 1
    try await withCheckedThrowingContinuation { continuation in
      pending[request] = PendingRequest(
        fileID: fileID,
        destinationID: destinationID,
        continuation: continuation
      )
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

  func fileID(for request: Int) -> PutioFileID {
    guard let pending = pending[request] else {
      preconditionFailure("request \(request) is not pending")
    }
    return pending.fileID
  }

  func destinationID(for request: Int) -> PutioFileID? {
    guard let pending = pending[request] else {
      preconditionFailure("request \(request) is not pending")
    }
    return pending.destinationID
  }

  func succeed(request: Int) {
    guard let pending = pending.removeValue(forKey: request) else {
      preconditionFailure("request \(request) is not pending")
    }
    pending.continuation.resume()
  }

  func fail(request: Int, with error: Error) {
    guard let pending = pending.removeValue(forKey: request) else {
      preconditionFailure("request \(request) is not pending")
    }
    pending.continuation.resume(throwing: error)
  }
}

@MainActor
final class PutioFolderModelTests: XCTestCase {
  private func waitForState(_ model: PutioFolderModel, _ expected: PutioFolderLoadState) async {
    let deadline = ContinuousClock.now + .seconds(5)
    while model.state != expected, ContinuousClock.now < deadline {
      await Task.yield()
    }
  }

  func testMovePickerShowsOnlyReachableFolderDestinations() {
    let source = BrowserTestFixtures.item(id: 7, parentID: 42, name: "Source", kind: .folder)
    let eligible = BrowserTestFixtures.item(id: 8, parentID: 42, name: "Destination", kind: .folder)
    let file = BrowserTestFixtures.item(id: 9, parentID: 42, name: "Episode.mkv")
    let policy = PutioMovePickerPolicy(item: source)

    XCTAssertEqual(
      policy.folders(in: BrowserTestFixtures.contents(items: [source, eligible, file])),
      [eligible]
    )
    XCTAssertFalse(policy.canMove(to: PutioFolderRoute(id: source.parentID, title: "Current")))
    XCTAssertFalse(policy.canMove(to: PutioFolderRoute(id: source.id, title: source.name)))
    XCTAssertTrue(policy.canMove(to: PutioFolderRoute(id: eligible.id, title: eligible.name)))
  }

  func testBulkMovePickerExcludesEverySelectedFolderAndCurrentParent() {
    let firstFolder = BrowserTestFixtures.item(
      id: 7, parentID: 42, name: "First", kind: .folder)
    let selectedFile = BrowserTestFixtures.item(id: 8, parentID: 42, name: "Episode.mkv")
    let secondFolder = BrowserTestFixtures.item(
      id: 9, parentID: 42, name: "Second", kind: .folder)
    let eligible = BrowserTestFixtures.item(
      id: 10, parentID: 42, name: "Destination", kind: .folder)
    let policy = PutioMovePickerPolicy(items: [firstFolder, selectedFile, secondFolder])

    XCTAssertEqual(
      policy.folders(
        in: BrowserTestFixtures.contents(
          items: [firstFolder, selectedFile, secondFolder, eligible]
        )
      ),
      [eligible]
    )
    XCTAssertFalse(
      policy.canMove(to: PutioFolderRoute(id: PutioFileID(rawValue: 42), title: "Current")))
    XCTAssertFalse(policy.canMove(to: PutioFolderRoute(id: firstFolder.id, title: "First")))
    XCTAssertFalse(policy.canMove(to: PutioFolderRoute(id: secondFolder.id, title: "Second")))
    XCTAssertTrue(policy.canMove(to: PutioFolderRoute(id: eligible.id, title: "Destination")))
    XCTAssertFalse(PutioMovePickerPolicy(items: []).canMove(to: .root))
  }

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
    let requests = PutioFolderRefreshRequests()

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
    await waitForState(model, .loaded(refreshed))

    XCTAssertEqual(model.state, .loaded(refreshed))
    XCTAssertEqual(
      model.actionOutcome,
      .succeeded(.rename(fileID: item.id, oldName: "Original.mkv", newName: "Renamed.mkv"))
    )
  }

  func testQueuedRefreshRunsAfterCallerCancellation() async {
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
    await waitForState(model, .loaded(refreshed))

    XCTAssertEqual(model.state, .loaded(refreshed))
    XCTAssertNil(model.activeAction)
    XCTAssertEqual(
      model.actionOutcome,
      .succeeded(.rename(fileID: item.id, oldName: "Original.mkv", newName: "Renamed.mkv"))
    )
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
    await waitForState(model, .loaded(refreshed))

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

  func testMoveUsesTheLatestItemAndOptimisticallyRemovesIt() async {
    let mutation = SuspendedFileMutation()
    let staleItem = BrowserTestFixtures.item(id: 7, parentID: 42, name: "Old Name.mkv")
    let currentItem = BrowserTestFixtures.item(
      id: 7,
      parentID: 42,
      name: "Episode.mkv",
      sizeBytes: 8_192,
      resumePositionSeconds: 137
    )
    let survivor = BrowserTestFixtures.item(id: 8, parentID: 42)
    let original = BrowserTestFixtures.contents(folderID: 42, items: [currentItem, survivor])
    let destination = PutioFolderRoute(id: PutioFileID(rawValue: 91), title: "Season 2")
    let expectedAction = PutioFileAction.move(
      fileID: currentItem.id,
      name: currentItem.name,
      sourceParentID: currentItem.parentID,
      destinationID: destination.id,
      destinationName: destination.title
    )
    let optimistic = PutioFolderContents(
      folder: original.folder,
      items: [survivor],
      hasMore: original.hasMore
    )
    let model = PutioFolderModel(
      folderID: PutioFileID(rawValue: 42),
      load: { _ in original },
      actions: PutioFileActions(
        createFolder: { _, _ in throw PutioRuntimeError.unknown },
        renameFile: { _, _ in throw PutioRuntimeError.unknown },
        deleteFile: { _ in throw PutioRuntimeError.unknown },
        moveFile: { fileID, parentID in
          XCTAssertEqual(fileID, currentItem.id)
          XCTAssertEqual(parentID, destination.id)
          try await mutation.run()
        }
      ),
      initialContents: original
    )

    let task = Task { await model.move(staleItem, to: destination) }
    await mutation.waitUntilStarted()

    XCTAssertEqual(model.state, .loaded(optimistic))
    XCTAssertEqual(model.activeAction, expectedAction)

    await mutation.succeed()
    await task.value

    XCTAssertEqual(model.state, .loaded(optimistic))
    XCTAssertEqual(model.actionOutcome, .succeeded(expectedAction))
  }

  func testMoveFailureRestoresTheExactPriorContents() async {
    let item = BrowserTestFixtures.item(id: 7, parentID: 42, name: "Episode.mkv")
    let original = BrowserTestFixtures.contents(folderID: 42, items: [item], hasMore: true)
    let destination = PutioFolderRoute(id: PutioFileID(rawValue: 91), title: "Season 2")
    let model = PutioFolderModel(
      folderID: PutioFileID(rawValue: 42),
      load: { _ in original },
      actions: PutioFileActions(
        createFolder: { _, _ in throw PutioRuntimeError.unknown },
        renameFile: { _, _ in throw PutioRuntimeError.unknown },
        deleteFile: { _ in throw PutioRuntimeError.unknown },
        moveFile: { _, _ in throw PutioRuntimeError.transient }
      ),
      initialContents: original
    )

    await model.move(item, to: destination)

    XCTAssertEqual(model.state, .loaded(original))
    guard case .failed(let action, let failure) = model.actionOutcome else {
      return XCTFail("expected failed move, got \(String(describing: model.actionOutcome))")
    }
    XCTAssertEqual(
      action,
      .move(
        fileID: item.id,
        name: item.name,
        sourceParentID: item.parentID,
        destinationID: destination.id,
        destinationName: destination.title
      )
    )
    XCTAssertEqual(failure.title, "Could not move item")
  }

  func testMoveRejectsTheCurrentParentAndTheSourceFolder() async {
    let item = BrowserTestFixtures.item(id: 7, parentID: 42, name: "Folder", kind: .folder)
    let original = BrowserTestFixtures.contents(folderID: 42, items: [item])
    var moveCount = 0
    let model = PutioFolderModel(
      folderID: PutioFileID(rawValue: 42),
      load: { _ in original },
      actions: PutioFileActions(
        createFolder: { _, _ in throw PutioRuntimeError.unknown },
        renameFile: { _, _ in throw PutioRuntimeError.unknown },
        deleteFile: { _ in throw PutioRuntimeError.unknown },
        moveFile: { _, _ in moveCount += 1 }
      ),
      initialContents: original
    )

    await model.move(item, to: PutioFolderRoute(id: item.parentID, title: "Current"))
    await model.move(item, to: PutioFolderRoute(id: item.id, title: item.name))

    XCTAssertEqual(moveCount, 0)
    XCTAssertEqual(model.state, .loaded(original))
    XCTAssertNil(model.activeAction)
    XCTAssertNil(model.actionOutcome)
  }

  func testBulkDeleteReportsProgressAndRestoresOnlyTheFailedLatestSnapshot() async {
    let mutations = ControlledBulkMutation()
    let leading = BrowserTestFixtures.item(id: 7, parentID: 42, name: "Leading.mkv")
    let failed = BrowserTestFixtures.item(
      id: 8,
      parentID: 42,
      name: "Server Failed.mkv",
      sizeBytes: 8_192,
      resumePositionSeconds: 137
    )
    let middle = BrowserTestFixtures.item(id: 9, parentID: 42, name: "Middle.mkv")
    let succeeded = BrowserTestFixtures.item(id: 10, parentID: 42, name: "Server Success.mkv")
    let trailing = BrowserTestFixtures.item(id: 11, parentID: 42, name: "Trailing.mkv")
    let original = BrowserTestFixtures.contents(
      folderID: 42,
      items: [leading, failed, middle, succeeded, trailing],
      hasMore: true
    )
    let reconciled = BrowserTestFixtures.contents(
      folderID: 42,
      items: [leading, failed, middle, trailing],
      hasMore: true
    )
    let staleFailed = BrowserTestFixtures.item(id: 8, parentID: 42, name: "Stale Failed")
    let staleSucceeded = BrowserTestFixtures.item(id: 10, parentID: 42, name: "Stale Success")
    let model = PutioFolderModel(
      folderID: PutioFileID(rawValue: 42),
      load: { _ in reconciled },
      actions: PutioFileActions(
        createFolder: { _, _ in throw PutioRuntimeError.unknown },
        renameFile: { _, _ in throw PutioRuntimeError.unknown },
        deleteFile: { fileID in try await mutations.run(fileID: fileID) }
      ),
      initialContents: original
    )

    let task = Task { await model.delete([staleFailed, staleSucceeded]) }
    await mutations.waitForRequestCount(1)

    let firstRequestedID = await mutations.fileID(for: 0)
    XCTAssertEqual(firstRequestedID, failed.id)
    XCTAssertEqual(
      model.state,
      .loaded(
        BrowserTestFixtures.contents(
          folderID: 42,
          items: [leading, middle, trailing],
          hasMore: true
        )
      )
    )
    XCTAssertEqual(
      model.bulkProgress,
      PutioBulkFileProgress(
        action: .delete,
        completedCount: 0,
        totalCount: 2,
        currentItem: failed
      )
    )
    XCTAssertFalse(model.canStartAction)

    await mutations.fail(request: 0, with: PutioRuntimeError.transient)
    await mutations.waitForRequestCount(2)

    let secondRequestedID = await mutations.fileID(for: 1)
    XCTAssertEqual(secondRequestedID, succeeded.id)
    XCTAssertEqual(
      model.state,
      .loaded(
        BrowserTestFixtures.contents(
          folderID: 42,
          items: [leading, failed, middle, trailing],
          hasMore: true
        )
      )
    )
    XCTAssertEqual(
      model.bulkProgress,
      PutioBulkFileProgress(
        action: .delete,
        completedCount: 1,
        totalCount: 2,
        currentItem: succeeded
      )
    )

    await mutations.succeed(request: 1)
    await task.value
    await waitForState(model, .loaded(reconciled))

    guard let outcome = model.bulkOutcome else {
      return XCTFail("expected an aggregate bulk outcome")
    }
    XCTAssertEqual(outcome.action, .delete)
    XCTAssertEqual(outcome.succeeded, [succeeded])
    XCTAssertEqual(outcome.completedCount, 2)
    XCTAssertEqual(outcome.failures.count, 1)
    XCTAssertEqual(outcome.failures[0].item, failed)
    XCTAssertEqual(outcome.failures[0].error, .transient)
    XCTAssertEqual(outcome.failures[0].presentation?.title, "Could not remove item")
    XCTAssertEqual(
      model.state,
      .loaded(reconciled)
    )
    XCTAssertNil(model.activeBulkAction)
    XCTAssertNil(model.bulkProgress)
    XCTAssertTrue(model.canStartAction)
  }

  func testBulkDeleteStopsAfterRateLimitAndDefersRemainingItemsForRetry() async {
    let mutations = ControlledBulkMutation()
    let first = BrowserTestFixtures.item(id: 7, parentID: 42, name: "First.mkv")
    let second = BrowserTestFixtures.item(id: 8, parentID: 42, name: "Second.mkv")
    let third = BrowserTestFixtures.item(id: 9, parentID: 42, name: "Third.mkv")
    let original = BrowserTestFixtures.contents(folderID: 42, items: [first, second, third])
    let model = PutioFolderModel(
      folderID: PutioFileID(rawValue: 42),
      load: { _ in original },
      actions: PutioFileActions(
        createFolder: { _, _ in throw PutioRuntimeError.unknown },
        renameFile: { _, _ in throw PutioRuntimeError.unknown },
        deleteFile: { fileID in try await mutations.run(fileID: fileID) }
      ),
      initialContents: original
    )

    let task = Task { await model.delete([first, second, third]) }
    await mutations.waitForRequestCount(1)
    await mutations.fail(request: 0, with: PutioRuntimeError.rateLimited)
    await task.value

    let requestCount = await mutations.requestCount()
    XCTAssertEqual(requestCount, 1)
    XCTAssertEqual(model.state, .loaded(original))
    XCTAssertEqual(model.bulkOutcome?.succeeded, [])
    XCTAssertEqual(model.bulkOutcome?.failures.map(\.item), [first, second, third])
    XCTAssertEqual(
      model.bulkOutcome?.failures.map(\.error),
      [
        .rateLimited, .rateLimited, .rateLimited,
      ])
    XCTAssertNil(model.activeBulkAction)
    XCTAssertNil(model.bulkProgress)
    XCTAssertTrue(model.canStartAction)
  }

  func testBulkMoveUsesEveryPerItemBoundaryAndSurvivesCallerCancellation() async {
    let mutations = ControlledBulkMutation()
    let first = BrowserTestFixtures.item(id: 7, parentID: 42, name: "First.mkv")
    let second = BrowserTestFixtures.item(id: 8, parentID: 42, name: "Second.mkv")
    let survivor = BrowserTestFixtures.item(id: 9, parentID: 42, name: "Survivor.mkv")
    let original = BrowserTestFixtures.contents(folderID: 42, items: [first, second, survivor])
    let reconciled = BrowserTestFixtures.contents(folderID: 42, items: [second, survivor])
    let destination = PutioFolderRoute(id: PutioFileID(rawValue: 91), title: "Season 2")
    let model = PutioFolderModel(
      folderID: PutioFileID(rawValue: 42),
      load: { _ in reconciled },
      actions: PutioFileActions(
        createFolder: { _, _ in throw PutioRuntimeError.unknown },
        renameFile: { _, _ in throw PutioRuntimeError.unknown },
        deleteFile: { _ in throw PutioRuntimeError.unknown },
        moveFile: { fileID, destinationID in
          try await mutations.run(fileID: fileID, destinationID: destinationID)
        }
      ),
      initialContents: original
    )

    let caller = Task { await model.move([first, second], to: destination) }
    await mutations.waitForRequestCount(1)
    caller.cancel()
    let rejoin = Task { await model.waitForActiveAction() }
    await Task.yield()

    XCTAssertEqual(
      model.state,
      .loaded(BrowserTestFixtures.contents(folderID: 42, items: [survivor]))
    )
    let firstDestinationID = await mutations.destinationID(for: 0)
    XCTAssertEqual(firstDestinationID, destination.id)
    await mutations.succeed(request: 0)
    await mutations.waitForRequestCount(2)
    let secondRequestedID = await mutations.fileID(for: 1)
    let secondDestinationID = await mutations.destinationID(for: 1)
    XCTAssertEqual(secondRequestedID, second.id)
    XCTAssertEqual(secondDestinationID, destination.id)
    await mutations.fail(request: 1, with: PutioRuntimeError.notFound)
    await rejoin.value
    await caller.value
    await waitForState(model, .loaded(reconciled))

    XCTAssertEqual(model.state, .loaded(reconciled))
    XCTAssertEqual(model.bulkOutcome?.succeeded, [first])
    XCTAssertEqual(model.bulkOutcome?.failures.map(\.item), [second])
    XCTAssertEqual(model.bulkOutcome?.failures.map(\.error), [.notFound])
  }

  func testBulkActionsRejectEmptyStaleDuplicateAndInvalidMoveSelections() async {
    let folder = BrowserTestFixtures.item(id: 7, parentID: 42, name: "Folder", kind: .folder)
    let file = BrowserTestFixtures.item(id: 8, parentID: 42, name: "Episode.mkv")
    let stale = BrowserTestFixtures.item(id: 99, parentID: 42, name: "Gone.mkv")
    let original = BrowserTestFixtures.contents(folderID: 42, items: [folder, file])
    var operationCount = 0
    let model = PutioFolderModel(
      folderID: PutioFileID(rawValue: 42),
      load: { _ in original },
      actions: PutioFileActions(
        createFolder: { _, _ in throw PutioRuntimeError.unknown },
        renameFile: { _, _ in throw PutioRuntimeError.unknown },
        deleteFile: { _ in operationCount += 1 },
        moveFile: { _, _ in operationCount += 1 }
      ),
      initialContents: original
    )

    await model.delete([])
    await model.delete([stale])
    await model.delete([file, file])
    await model.move([file], to: PutioFolderRoute(id: file.parentID, title: "Current"))
    await model.move([folder, file], to: PutioFolderRoute(id: folder.id, title: folder.name))

    XCTAssertEqual(operationCount, 0)
    XCTAssertEqual(model.state, .loaded(original))
    XCTAssertNil(model.activeBulkAction)
    XCTAssertNil(model.bulkProgress)
    XCTAssertNil(model.bulkOutcome)
  }

  func testBulkMutationKeepsAllMutationsExclusive() async {
    let mutations = ControlledBulkMutation()
    let first = BrowserTestFixtures.item(id: 7, parentID: 42, name: "First.mkv")
    let second = BrowserTestFixtures.item(id: 8, parentID: 42, name: "Second.mkv")
    let original = BrowserTestFixtures.contents(folderID: 42, items: [first, second])
    var renameCount = 0
    let model = PutioFolderModel(
      folderID: PutioFileID(rawValue: 42),
      load: { _ in original },
      actions: PutioFileActions(
        createFolder: { _, _ in throw PutioRuntimeError.unknown },
        renameFile: { _, _ in renameCount += 1 },
        deleteFile: { fileID in try await mutations.run(fileID: fileID) }
      ),
      initialContents: original
    )

    let bulk = Task { await model.delete([first, second]) }
    await mutations.waitForRequestCount(1)
    await model.rename(second, to: "Renamed.mkv")
    await model.delete(second)
    await model.delete([second])

    XCTAssertEqual(renameCount, 0)
    let blockedRequestCount = await mutations.requestCount()
    XCTAssertEqual(blockedRequestCount, 1)
    await mutations.succeed(request: 0)
    await mutations.waitForRequestCount(2)
    await mutations.succeed(request: 1)
    await bulk.value
  }

  func testBulkRefreshRequestsCoalesceAfterTheEntireOperation() async {
    let loader = ControlledFolderLoader()
    let mutations = ControlledBulkMutation()
    let first = BrowserTestFixtures.item(id: 7, parentID: 42, name: "First.mkv")
    let second = BrowserTestFixtures.item(id: 8, parentID: 42, name: "Second.mkv")
    let original = BrowserTestFixtures.contents(folderID: 42, items: [first, second])
    let stale = BrowserTestFixtures.contents(
      folderID: 42,
      items: [BrowserTestFixtures.item(id: 99, parentID: 42, name: "Stale.mkv")]
    )
    let refreshed = BrowserTestFixtures.contents(folderID: 42, items: [])
    let model = PutioFolderModel(
      folderID: PutioFileID(rawValue: 42),
      load: { folderID in try await loader.load(folderID: folderID) },
      actions: PutioFileActions(
        createFolder: { _, _ in throw PutioRuntimeError.unknown },
        renameFile: { _, _ in throw PutioRuntimeError.unknown },
        deleteFile: { fileID in try await mutations.run(fileID: fileID) }
      ),
      initialContents: original
    )

    let staleRefresh = Task { await model.refresh() }
    await loader.waitForRequestCount(1)
    let bulk = Task { await model.delete([first, second]) }
    await mutations.waitForRequestCount(1)
    await loader.succeed(request: 0, with: stale)
    await staleRefresh.value
    await model.refresh()
    await model.refresh()
    let queuedRequestCount = await loader.requestCount()
    XCTAssertEqual(queuedRequestCount, 1)

    await mutations.succeed(request: 0)
    await mutations.waitForRequestCount(2)
    let midOperationRequestCount = await loader.requestCount()
    XCTAssertEqual(midOperationRequestCount, 1)
    await mutations.succeed(request: 1)
    await bulk.value
    await loader.waitForRequestCount(2)
    let replayedRequestCount = await loader.requestCount()
    XCTAssertEqual(replayedRequestCount, 2)
    await loader.succeed(request: 1, with: refreshed)
    await waitForState(model, .loaded(refreshed))

    XCTAssertEqual(model.state, .loaded(refreshed))
    let finalRequestCount = await loader.requestCount()
    XCTAssertEqual(finalRequestCount, 2)
  }

  func testBulkCompletionRefreshesTheSourceFolder() async {
    let loader = ControlledFolderLoader()
    let mutations = ControlledBulkMutation()
    let first = BrowserTestFixtures.item(id: 7, parentID: 42, name: "First.mkv")
    let second = BrowserTestFixtures.item(id: 8, parentID: 42, name: "Second.mkv")
    let original = BrowserTestFixtures.contents(folderID: 42, items: [first, second])
    let reconciled = BrowserTestFixtures.contents(
      folderID: 42,
      items: [BrowserTestFixtures.item(id: 9, parentID: 42, name: "Server Added.mkv")]
    )
    let model = PutioFolderModel(
      folderID: PutioFileID(rawValue: 42),
      load: { folderID in try await loader.load(folderID: folderID) },
      actions: PutioFileActions(
        createFolder: { _, _ in throw PutioRuntimeError.unknown },
        renameFile: { _, _ in throw PutioRuntimeError.unknown },
        deleteFile: { fileID in try await mutations.run(fileID: fileID) }
      ),
      initialContents: original
    )

    let bulk = Task { await model.delete([first, second]) }
    await mutations.waitForRequestCount(1)
    await mutations.succeed(request: 0)
    await mutations.waitForRequestCount(2)
    await mutations.succeed(request: 1)
    await bulk.value

    await loader.waitForRequestCount(1)
    let refreshedFolderID = await loader.folderID(for: 0)
    XCTAssertEqual(refreshedFolderID, PutioFileID(rawValue: 42))
    await loader.succeed(request: 0, with: reconciled)
    await waitForState(model, .loaded(reconciled))

    XCTAssertEqual(model.state, .loaded(reconciled))
    XCTAssertEqual(model.bulkOutcome?.succeeded, [first, second])
    let requestCount = await loader.requestCount()
    XCTAssertEqual(requestCount, 1)
  }

  func testMutationOutlivesACancelledCallerAndSettlesTheServerOutcome() async {
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

    let caller = Task { await model.rename(item, to: "Renamed.mkv") }
    await mutation.waitUntilStarted()
    caller.cancel()
    await Task.yield()
    XCTAssertEqual(
      model.activeAction,
      .rename(fileID: item.id, oldName: "Original.mkv", newName: "Renamed.mkv")
    )

    await mutation.succeed()
    await model.waitForActiveAction()
    await caller.value

    guard case .loaded(let contents) = model.state else {
      return XCTFail("expected loaded, got \(model.state)")
    }
    XCTAssertEqual(contents.items.first?.name, "Renamed.mkv")
    XCTAssertNil(model.activeAction)
    XCTAssertEqual(
      model.actionOutcome,
      .succeeded(.rename(fileID: item.id, oldName: "Original.mkv", newName: "Renamed.mkv"))
    )
  }

  func testMutationRefetchesARefreshItSuperseded() async {
    let loader = ControlledFolderLoader()
    let mutation = SuspendedFileMutation()
    let item = BrowserTestFixtures.item(id: 7, name: "Original.mkv")
    let original = BrowserTestFixtures.contents(items: [item])
    let stale = BrowserTestFixtures.contents(
      items: [BrowserTestFixtures.item(id: 99, name: "Stale.mkv")]
    )
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

    let refresh = Task { await model.refresh() }
    await loader.waitForRequestCount(1)
    let rename = Task { await model.rename(item, to: "Renamed.mkv") }
    await mutation.waitUntilStarted()
    await loader.succeed(request: 0, with: stale)
    await refresh.value

    await mutation.succeed()
    await rename.value
    await loader.waitForRequestCount(2)
    await loader.succeed(request: 1, with: refreshed)
    await waitForState(model, .loaded(refreshed))

    XCTAssertEqual(model.state, .loaded(refreshed))
    XCTAssertNil(model.activeAction)
  }

  func testQueuedRefreshDoesNotExtendTheMutationCall() async {
    let loader = ControlledFolderLoader()
    let mutation = SuspendedFileMutation()
    let item = BrowserTestFixtures.item(id: 7, name: "Original.mkv")
    let original = BrowserTestFixtures.contents(items: [item])
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
    await mutation.succeed()

    // The mutation call returns while the queued refresh is still pending.
    await rename.value
    await loader.waitForRequestCount(1)
    XCTAssertNil(model.activeAction)
    XCTAssertEqual(
      model.actionOutcome,
      .succeeded(.rename(fileID: item.id, oldName: "Original.mkv", newName: "Renamed.mkv"))
    )
    await loader.succeed(request: 0, with: original)
  }

  func testTransportCancellationRestoresTheExactPriorContents() async {
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
    await mutation.fail(with: CancellationError())
    await task.value

    XCTAssertEqual(model.state, .loaded(original))
    XCTAssertNil(model.actionOutcome)
    XCTAssertNil(model.activeAction)
  }
}
