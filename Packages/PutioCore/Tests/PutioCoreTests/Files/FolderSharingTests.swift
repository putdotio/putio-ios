import XCTest

@testable import PutioCore

private enum Fixtures {
  static func ids(_ values: [Int]) -> [PutioFileItem] {
    values.map { BrowserTestFixtures.item(id: $0) }
  }

  static func id(_ value: Int) -> PutioFileID { PutioFileID(rawValue: value) }
}

private final class LoadScript: @unchecked Sendable {
  private let lock = NSLock()
  private var results: [Result<PutioFolderContents, Error>]
  private(set) var calls = 0

  init(_ results: [Result<PutioFolderContents, Error>]) {
    self.results = results
  }

  func next() throws -> PutioFolderContents {
    lock.lock()
    defer { lock.unlock() }
    calls += 1
    return try (results.count > 1 ? results.removeFirst() : results[0]).get()
  }
}

final class FolderNeighbourTests: XCTestCase {
  func testRemovingARowFocusesTheNextRowOrThePreviousAtTheEnd() {
    let items = Fixtures.ids([410, 412, 406])
    let all = Set(items.map(\.id))
    XCTAssertEqual(
      PutioFolderContents.neighbour(afterRemoving: Fixtures.id(412), from: items, firstPage: all),
      Fixtures.id(406))
    XCTAssertEqual(
      PutioFolderContents.neighbour(afterRemoving: Fixtures.id(406), from: items, firstPage: all),
      Fixtures.id(412))
    XCTAssertNil(
      PutioFolderContents.neighbour(
        afterRemoving: Fixtures.id(410), from: [items[0]], firstPage: all))
  }

  func testRemovingALaterPageRowFocusesARowTheReloadKeeps() {
    let items = Fixtures.ids([424, 410, 422, 426])
    let firstPage: Set = [Fixtures.id(424), Fixtures.id(410)]
    XCTAssertEqual(
      PutioFolderContents.neighbour(
        afterRemoving: Fixtures.id(422), from: items, firstPage: firstPage),
      Fixtures.id(410))
    XCTAssertEqual(
      PutioFolderContents.neighbour(
        afterRemoving: Fixtures.id(424), from: items, firstPage: firstPage),
      Fixtures.id(410))
  }

  func testKeepingARowFallsBackToTheFirstPage() {
    let items = Fixtures.ids([424, 410, 422, 426])
    let firstPage: Set = [Fixtures.id(424), Fixtures.id(410)]
    XCTAssertEqual(
      PutioFolderContents.neighbour(keeping: Fixtures.id(410), in: items, firstPage: firstPage),
      Fixtures.id(410))
    XCTAssertEqual(
      PutioFolderContents.neighbour(keeping: Fixtures.id(426), in: items, firstPage: firstPage),
      Fixtures.id(410))
  }
}

final class FolderPagingAndSortTests: XCTestCase {
  @MainActor
  func testFoldersLoadPagesOfFifty() {
    XCTAssertEqual(PutioRuntime.folderPageSize, 50)
  }

  func testSortChoicesKeepTheDirectionWhenSwitchingFields() {
    let choices = PutioFolderSortChoices(current: .sizeDescending)
    XCTAssertEqual(choices.checkedField, .size)
    XCTAssertEqual(choices.orders, [.sizeAscending, .sizeDescending])
    XCTAssertEqual(choices.selecting(.name), .nameDescending)
    XCTAssertEqual(
      PutioFolderSortChoices(current: .watchStatusAscending).selecting(.size), .sizeAscending)
    XCTAssertEqual(
      PutioFolderSortChoices.videoOrders.map(\.orderTitle),
      [
        "Unwatched first", "Watched first",
      ])
  }
}

@MainActor
final class FolderRefreshRegistrationTests: XCTestCase {
  func testAFolderMutationAsksOtherScreensToRefreshOnceItSettles() async {
    let requests = PutioFolderRefreshRequests()
    let search = PutioFolderRefreshRegistration(folderID: .root, requests: requests)
    search.activate()
    let screen = PutioFolderRefreshRegistration(folderID: .root, requests: requests)
    var settled = false

    await screen.mutate(.allFolders) {
      XCTAssertNil(search.pendingSequence, "asked before settling")
      settled = true
      return true
    }

    XCTAssertTrue(settled)
    XCTAssertNotNil(search.pendingSequence)
  }

  func testAFailedMutationRefreshesTheStartingScreenToo() async {
    let requests = PutioFolderRefreshRequests()
    let screen = PutioFolderRefreshRegistration(folderID: .root, requests: requests)
    screen.activate()

    await screen.mutate(.allFolders) { true }
    XCTAssertNil(screen.pendingSequence, "a committed delete refreshes itself")

    await screen.mutate(.folder(.root)) { false }
    XCTAssertNotNil(screen.pendingSequence)
  }

  func testOnlyASuccessfulRefreshConsumesThePendingRequest() async {
    let requests = PutioFolderRefreshRequests()
    let loaded = BrowserTestFixtures.contents(items: Fixtures.ids([1]))
    let script = LoadScript([
      .success(loaded), .failure(URLError(.badServerResponse)), .success(loaded),
    ])
    let registration = PutioFolderRefreshRegistration(folderID: .root, requests: requests)
    let model = PutioFolderModel(folderID: .root, load: { _ in try script.next() })

    let result1 = await registration.loadIfNeeded(model)
    XCTAssertTrue(result1)
    requests.request(folderID: .root)
    XCTAssertNotNil(registration.pendingSequence)

    let result2 = await registration.refreshPending(model)
    XCTAssertFalse(result2)
    XCTAssertNotNil(registration.pendingSequence, "a failed refresh keeps the request")

    let result3 = await registration.refreshPending(model)
    XCTAssertTrue(result3)
    XCTAssertNil(registration.pendingSequence)
    let result4 = await registration.refreshPending(model)
    XCTAssertFalse(result4, "nothing pending, nothing loads")
    XCTAssertEqual(script.calls, 3)
  }

  func testTheFirstLoadConsumesARequestThatPredatesIt() async {
    let requests = PutioFolderRefreshRequests()
    let registration = PutioFolderRefreshRegistration(folderID: .root, requests: requests)
    registration.activate()
    requests.request(folderID: .root)
    let model = PutioFolderModel(
      folderID: .root, load: { _ in BrowserTestFixtures.contents(items: Fixtures.ids([1])) })

    let result5 = await registration.loadIfNeeded(model)
    XCTAssertTrue(result5)
    XCTAssertNil(registration.pendingSequence)
  }

  func testARetryThatLoadsConsumesThePendingRequest() async {
    let requests = PutioFolderRefreshRequests()
    let script = LoadScript([
      .failure(URLError(.notConnectedToInternet)),
      .success(BrowserTestFixtures.contents(items: Fixtures.ids([1]))),
    ])
    let registration = PutioFolderRefreshRegistration(folderID: .root, requests: requests)
    let model = PutioFolderModel(folderID: .root, load: { _ in try script.next() })

    let result6 = await registration.loadIfNeeded(model)
    XCTAssertFalse(result6)
    requests.request(folderID: .root)
    let result7 = await registration.retryKeepingFailure(model)
    XCTAssertTrue(result7)
    XCTAssertNil(registration.pendingSequence)
  }
}

@MainActor
final class OfflineRetryTests: XCTestCase {
  func testDelaysDoubleFromThreeSecondsUpToThirty() {
    XCTAssertEqual(
      (0..<7).map(PutioOfflineRetry.delay(attempt:)),
      [
        .seconds(3), .seconds(6), .seconds(12), .seconds(24), .seconds(30), .seconds(30),
        .seconds(30),
      ])
  }

  func testRetriesUntilTheScreenIsBackOnline() async {
    let slept = SleepLog()
    var offline = true
    var attempts = 0
    await PutioOfflineRetry(sleep: { await slept.record($0) }).run(while: offline) {
      attempts += 1
      if attempts == 3 { offline = false }
    }
    XCTAssertEqual(attempts, 3)
    let durations = await slept.durations
    XCTAssertEqual(durations, [.seconds(3), .seconds(6), .seconds(12)])
  }

  func testStopsWhenTheSleepIsCancelled() async {
    var attempts = 0
    await PutioOfflineRetry(sleep: { _ in throw CancellationError() }).run(while: true) {
      attempts += 1
    }
    XCTAssertEqual(attempts, 0)
  }
}

private actor SleepLog {
  private(set) var durations: [Duration] = []

  func record(_ duration: Duration) {
    durations.append(duration)
  }
}
