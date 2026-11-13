import Foundation
import XCTest

@testable import PutioCore

@MainActor
final class RecentSearchesModelTests: XCTestCase {
  private var stored = PutioRecentSearches(enabled: true, terms: [])
  private var saved: [[String]] = []
  private var loadFails = false
  private var saveFails = false

  private func makeModel() -> PutioRecentSearchesModel {
    PutioRecentSearchesModel(
      actions: PutioRecentSearchActions(
        load: { [unowned self] in
          if loadFails { throw PutioRuntimeError.transient }
          return stored
        },
        save: { [unowned self] terms in
          if saveFails { throw PutioRuntimeError.transient }
          stored.terms = terms
          saved.append(terms)
        }))
  }

  func testASixthSearchEvictsTheOldestAndARepeatMovesToTheTop() async {
    let model = makeModel()
    await model.load()

    for query in ["one", "two", "three", "four", "five", "six"] {
      await model.record(query)
    }
    XCTAssertEqual(model.terms, ["six", "five", "four", "three", "two"])

    await model.record("  four ")
    XCTAssertEqual(model.terms, ["four", "six", "five", "three", "two"])
    XCTAssertEqual(stored.terms, model.terms)
  }

  func testAnEmptyQueryIsNotRecorded() async {
    let model = makeModel()
    await model.load()

    await model.record("   ")

    XCTAssertEqual(saved, [])
  }

  func testRemoveAndClearRewriteTheStoredList() async {
    stored.terms = ["blue lights", "sintel", "mp3"]
    let model = makeModel()
    await model.load()

    await model.remove("sintel")
    XCTAssertEqual(model.terms, ["blue lights", "mp3"])

    await model.clear()
    XCTAssertEqual(model.terms, [])
    XCTAssertEqual(saved, [["blue lights", "mp3"], []])
  }

  func testHistoryOffShowsNothingAndRecordsNothing() async {
    stored = PutioRecentSearches(enabled: false, terms: ["sintel"])
    let model = makeModel()
    await model.load()

    await model.record("blue")

    XCTAssertEqual(model.terms, [])
    XCTAssertEqual(saved, [])
  }

  func testAFailedLoadKeepsTheLastLoadedList() async {
    stored.terms = ["sintel"]
    let model = makeModel()
    await model.load()

    loadFails = true
    await model.load()

    XCTAssertEqual(model.terms, ["sintel"])
  }

  func testAFailedWriteKeepsTheListAndReportsIt() async {
    stored.terms = ["sintel", "mp3"]
    let model = makeModel()
    await model.load()

    saveFails = true
    await model.remove("mp3")

    XCTAssertEqual(model.terms, ["sintel", "mp3"])
    XCTAssertNotNil(model.editFailure)
    model.clearEditFailure()
    XCTAssertNil(model.editFailure)
  }

  func testASearchSubmittedOfflineRecordsNothingAndReportsNothing() async {
    stored.terms = ["sintel"]
    let model = makeModel()
    await model.load()

    loadFails = true
    await model.record("blue")
    XCTAssertEqual(model.terms, ["sintel"])
    XCTAssertNil(model.editFailure)

    await model.remove("sintel")
    XCTAssertEqual(model.terms, ["sintel"])
    XCTAssertNotNil(model.editFailure)
  }

  func testAnEditAppliesToWhatAnotherClientStoredSinceTheLoad() async {
    stored.terms = ["sintel"]
    let model = makeModel()
    await model.load()

    stored.terms = ["tree rings", "sintel"]
    await model.record("blue")

    XCTAssertEqual(model.terms, ["blue", "tree rings", "sintel"])
  }

  func testStoredDuplicatesAndBlanksCollapse() async {
    stored.terms = ["a", " ", "b", "a", "c", "d", "e", "f"]
    let model = makeModel()

    await model.load()

    XCTAssertEqual(model.terms, ["a", "b", "c", "d", "e"])
  }
}
