import XCTest

@testable import PutioCore

@MainActor
final class ContinueWatchingTests: XCTestCase {
  private var defaults: UserDefaults!
  private var suiteName = ""
  private var now = Date(timeIntervalSince1970: 1_800_000_000)

  override func setUp() async throws {
    try await super.setUp()
    suiteName = "ContinueWatchingTests.\(UUID().uuidString)"
    defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
  }

  override func tearDown() async throws {
    defaults.removePersistentDomain(forName: suiteName)
    try await super.tearDown()
  }

  private func makeModel(accountID: Int = 7) -> PutioContinueWatchingModel {
    PutioContinueWatchingModel(
      store: PutioContinueWatchingStore(defaults: defaults, accountID: accountID),
      clock: { [unowned self] in now })
  }

  private func play(
    _ model: PutioContinueWatchingModel, _ id: Int, name: String = "Sintel.mkv",
    duration: Double = 1_000, at seconds: Int
  ) {
    model.opened(
      fileID: PutioFileID(rawValue: id), parentID: .root, name: name, durationSeconds: duration)
    model.positionSaved(fileID: PutioFileID(rawValue: id), seconds: seconds)
  }

  func testInProgressIsAboveZeroBelowNinetyFivePercentAndMoreThanTenSecondsBeforeTheEnd() {
    let cases: [(position: Int, duration: Double, inProgress: Bool)] = [
      (0, 600, false), (1, 600, true), (569, 600, true), (570, 600, false),
      (89, 100, true), (90, 100, false), (179, 190, true), (180, 190, false),
      (5, 0, false), (5, .infinity, false),
    ]
    for (position, duration, inProgress) in cases {
      XCTAssertEqual(
        PutioContinueWatchingEntry.isInProgress(
          positionSeconds: position, durationSeconds: duration),
        inProgress, "\(position) of \(duration)")
    }
  }

  func testTimeLeftReadsAsMinutesUnderAnHourAndHoursFromOne() {
    let short = PutioContinueWatchingEntry(
      fileID: PutioFileID(rawValue: 1), parentID: .root, name: "a", positionSeconds: 1_260,
      durationSeconds: 3_127, watchedAt: now)
    XCTAssertEqual(short.remainingClock, "31:07")
    let long = PutioContinueWatchingEntry(
      fileID: PutioFileID(rawValue: 1), parentID: .root, name: "a", positionSeconds: 60,
      durationSeconds: 4_480, watchedAt: now)
    XCTAssertEqual(long.remainingClock, "1:13:40")
    XCTAssertEqual(long.fraction, 60.0 / 4_480, accuracy: 0.0001)
  }

  func testAVideoPlayedToTheMiddleIsListedNewestFirstAndPersists() {
    let model = makeModel()
    play(model, 1, name: "First.mkv", at: 300)
    now = now.addingTimeInterval(10)
    play(model, 2, name: "Second.mkv", at: 400)

    XCTAssertEqual(model.entries.map(\.name), ["Second.mkv", "First.mkv"])
    XCTAssertEqual(makeModel().entries.map(\.name), ["Second.mkv", "First.mkv"])
    XCTAssertEqual(makeModel(accountID: 8).entries, [])
  }

  func testAPositionWithoutAKnownLengthListsNothing() {
    let model = makeModel()
    model.positionSaved(fileID: PutioFileID(rawValue: 1), seconds: 300)
    XCTAssertEqual(model.entries, [])
  }

  func testAFinishedOrResetVideoLeaves() {
    let model = makeModel()
    play(model, 1, at: 300)
    play(model, 2, at: 300)
    model.positionSaved(fileID: PutioFileID(rawValue: 1), seconds: 960)
    model.positionSaved(fileID: PutioFileID(rawValue: 2), seconds: 0)
    XCTAssertEqual(model.entries, [])
    XCTAssertEqual(makeModel().entries, [])
  }

  func testAVideoPlayedPastNinetyFivePercentIsNeverListed() {
    let model = makeModel()
    play(model, 1, at: 951)
    XCTAssertEqual(model.entries, [])
  }

  func testRemovedStaysRemovedUntilPlayedAgain() {
    let model = makeModel()
    play(model, 1, at: 300)
    model.remove(PutioFileID(rawValue: 1))
    model.positionSaved(fileID: PutioFileID(rawValue: 1), seconds: 320)
    XCTAssertEqual(model.entries, [])

    play(model, 1, at: 340)
    XCTAssertEqual(model.entries.map(\.positionSeconds), [340])
  }

  func testTheListKeepsTheTenNewest() {
    let model = makeModel()
    for id in 1...12 {
      now = now.addingTimeInterval(1)
      play(model, id, name: "\(id).mkv", at: 100)
    }
    XCTAssertEqual(model.entries.count, PutioContinueWatchingModel.limit)
    XCTAssertEqual(model.entries.first?.name, "12.mkv")
    XCTAssertEqual(model.entries.last?.name, "3.mkv")
  }

  func testReconcileDropsGoneAndFinishedFilesMovesPositionsAndKeepsOnFailure() async {
    let model = makeModel()
    for id in 1...5 { play(model, id, name: "\(id).mkv", at: 300) }
    let positions = [1: 500, 3: 990, 4: 0]

    await model.reconcile(
      loadFile: { id in
        switch id.rawValue {
        case 2: throw PutioRuntimeError.notFound
        case 5: throw PutioRuntimeError.transient
        default:
          return BrowserTestFixtures.item(
            id: id.rawValue, parentID: 9, name: "Renamed \(id.rawValue).mkv",
            resumePositionSeconds: positions[id.rawValue] ?? 0)
        }
      })

    XCTAssertEqual(model.entries.map(\.fileID.rawValue).sorted(), [1, 5])
    let first = model.entries.first { $0.fileID.rawValue == 1 }
    XCTAssertEqual(first?.positionSeconds, 500)
    XCTAssertEqual(first?.name, "Renamed 1.mkv")
    XCTAssertEqual(first?.parentID, PutioFileID(rawValue: 9))
  }

  func testReconcileKeepsAPositionTheDeviceOwns() async {
    let model = makeModel()
    play(model, 1, at: 300)

    await model.reconcile(
      loadFile: { id in
        BrowserTestFixtures.item(id: id.rawValue, parentID: 0, name: "Sintel.mkv")
      },
      keepsLocalPosition: { _ in true })

    XCTAssertEqual(model.entries.map(\.positionSeconds), [300])
  }

  func testADamagedDocumentReadsAsEmpty() {
    defaults.set(Data("not json".utf8), forKey: "putio.files.continue-watching.7")
    XCTAssertEqual(makeModel().entries, [])
  }

  func testClearForgetsOnlyThatAccount() {
    play(makeModel(accountID: 7), 1, at: 300)
    play(makeModel(accountID: 8), 1, at: 300)
    PutioContinueWatchingStore.clear(defaults: defaults, accountID: 7)
    XCTAssertEqual(makeModel(accountID: 7).entries, [])
    XCTAssertEqual(makeModel(accountID: 8).entries.count, 1)
  }
}
