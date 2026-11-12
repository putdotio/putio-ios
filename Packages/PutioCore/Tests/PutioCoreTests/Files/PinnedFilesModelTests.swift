import XCTest

@testable import PutioCore

@MainActor
final class PinnedFilesModelTests: XCTestCase {
  private var stored: [Int] = []
  private var saved: [[Int]] = []
  private var loadFails = false
  private var saveFails = false
  private var reads: [Int] = []

  private let files: [Int: PutioFileItem] = [
    20: BrowserTestFixtures.item(id: 20, parentID: 0, name: "Series", kind: .folder),
    21: BrowserTestFixtures.item(id: 21, parentID: 20, name: "Blue Lights", kind: .folder),
    22: BrowserTestFixtures.item(id: 22, parentID: 0, name: "Sintel.mkv"),
    23: BrowserTestFixtures.item(id: 23, parentID: 30, name: "notes.pdf", kind: .pdf),
    30: BrowserTestFixtures.item(id: 30, parentID: 0, name: "Movies", kind: .folder),
    31: BrowserTestFixtures.item(id: 31, parentID: 0, name: "IMG_4392.HEIC", kind: .image),
  ]

  private func makeModel() -> PutioPinnedFilesModel {
    PutioPinnedFilesModel(
      actions: PutioPinnedFilesActions(
        loadIDs: { [unowned self] in
          if loadFails { throw PutioRuntimeError.transient }
          return stored.map(PutioFileID.init)
        },
        saveIDs: { [unowned self] ids in
          if saveFails { throw PutioRuntimeError.transient }
          stored = ids.map(\.rawValue)
          saved.append(stored)
        },
        loadFile: { [unowned self] id in
          reads.append(id.rawValue)
          if id.rawValue == 99 { throw PutioRuntimeError.transient }
          guard let file = files[id.rawValue] else { throw PutioRuntimeError.notFound }
          return file
        }),
      rootName: "Files")
  }

  func testPinsLoadInPinOrderWithTheFolderThatHoldsThem() async {
    stored = [21, 22, 23]
    let model = makeModel()

    await model.load()

    XCTAssertEqual(model.items.map(\.item.name), ["Blue Lights", "Sintel.mkv", "notes.pdf"])
    XCTAssertEqual(model.items.map(\.location), ["Series", "Files", "Movies"])
    XCTAssertTrue(model.isPinned(PutioFileID(rawValue: 22)))
    XCTAssertEqual(saved, [])
  }

  func testAPinWhoseFileIsGoneIsDroppedFromTheConfig() async {
    stored = [21, 404, 22]
    let model = makeModel()

    await model.load()

    XCTAssertEqual(model.items.map(\.item.name), ["Blue Lights", "Sintel.mkv"])
    XCTAssertEqual(saved, [[21, 22]])
    XCTAssertFalse(model.isPinned(PutioFileID(rawValue: 404)))
  }

  func testAPinThatCannotBeReadIsLeftOutButStaysPinned() async {
    stored = [99, 22]
    let model = makeModel()

    await model.load()

    XCTAssertEqual(model.items.map(\.item.name), ["Sintel.mkv"])
    XCTAssertEqual(saved, [])
    XCTAssertTrue(model.isPinned(PutioFileID(rawValue: 99)))
  }

  func testPinsThatFailToLoadLeaveTheSectionAbsent() async {
    stored = [21]
    loadFails = true
    let model = makeModel()

    await model.load()

    XCTAssertEqual(model.state, .unavailable)
    XCTAssertEqual(model.items, [])
  }

  func testAFailedReloadKeepsThePinsShown() async {
    stored = [21, 22]
    let model = makeModel()
    await model.load()
    loadFails = true

    await model.load()

    XCTAssertEqual(model.items.map(\.item.name), ["Blue Lights", "Sintel.mkv"])
  }

  func testPinningShowsTheItemFirstAndKeepsPinsFromOtherDevices() async {
    stored = [22]
    let model = makeModel()
    await model.load()
    stored = [21, 22]
    reads = []

    await model.pin(files[23]!, in: "Movies")

    XCTAssertEqual(saved, [[23, 21, 22]])
    XCTAssertEqual(model.items.map(\.item.name), ["notes.pdf", "Blue Lights", "Sintel.mkv"])
    XCTAssertTrue(model.isPinned(PutioFileID(rawValue: 23)))
  }

  func testPinningWithoutOtherChangesReadsNoFiles() async {
    stored = [22]
    let model = makeModel()
    await model.load()
    reads = []

    await model.pin(files[23]!, in: "Movies")

    XCTAssertEqual(reads, [])
    XCTAssertEqual(model.items.map(\.location), ["Movies", "Files"])
  }

  func testUnpinRemovesTheRowAndAFailedEditRollsBackWithItsName() async {
    stored = [21, 22]
    let model = makeModel()
    await model.load()

    await model.unpin(files[21]!)
    XCTAssertEqual(saved, [[22]])
    XCTAssertEqual(model.items.map(\.item.name), ["Sintel.mkv"])
    XCTAssertFalse(model.isPinned(PutioFileID(rawValue: 21)))

    saveFails = true
    await model.unpin(files[22]!)
    XCTAssertEqual(model.items.map(\.item.name), ["Sintel.mkv"])
    XCTAssertTrue(model.isPinned(PutioFileID(rawValue: 22)))
    XCTAssertEqual(model.editFailure?.name, "Sintel.mkv")
    model.clearEditFailure()
    XCTAssertNil(model.editFailure)
  }

  func testTwoFailedEditsRollBackToTheStoredPins() async {
    stored = [22]
    let model = makeModel()
    await model.load()
    saveFails = true

    let series = files[21]!
    let notes = files[23]!
    let first = Task { await model.pin(series, in: "Series") }
    let second = Task { await model.pin(notes, in: "Movies") }
    await first.value
    await second.value

    XCTAssertEqual(model.items.map(\.item.name), ["Sintel.mkv"])
    XCTAssertFalse(model.isPinned(PutioFileID(rawValue: 21)))
    XCTAssertFalse(model.isPinned(PutioFileID(rawValue: 23)))
  }

  func testPinningAfterAFailedLoadShowsTheSection() async {
    stored = []
    loadFails = true
    let model = makeModel()
    await model.load()
    XCTAssertEqual(model.state, .unavailable)
    loadFails = false

    await model.pin(files[22]!, in: "Files")

    XCTAssertEqual(saved, [[22]])
    XCTAssertEqual(model.items.map(\.item.name), ["Sintel.mkv"])
  }

  func testTheSectionShowsFivePinsAndSeeAllForMore() async {
    stored = [20, 21, 22, 23, 30]
    let model = makeModel()
    await model.load()
    XCTAssertEqual(model.sectionItems.count, 5)
    XCTAssertFalse(model.showsSeeAll)

    stored = [20, 21, 22, 23, 30, 99]
    await model.pin(files[31]!, in: "Files")

    XCTAssertEqual(model.items.count, 6)
    XCTAssertEqual(model.sectionItems.map(\.item.name).first, "IMG_4392.HEIC")
    XCTAssertEqual(model.sectionItems.count, 5)
    XCTAssertTrue(model.showsSeeAll)
  }
}
