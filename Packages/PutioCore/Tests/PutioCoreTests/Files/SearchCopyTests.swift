import XCTest

@testable import PutioCore

@MainActor
final class SearchCopyTests: XCTestCase {
  func testNothingMatchesNamesTheShortenedTerm() {
    let long = String(repeating: "bunny ", count: 20)
    let nothing = PutioSearchResultPresentation.nothingMatches(long)
    XCTAssertEqual(nothing.copy.title, "Nothing matches")
    XCTAssertEqual(nothing.term, PutioFileSearchModel.shownTerm(long))
    XCTAssertTrue(nothing.term.hasSuffix("…"))
    XCTAssertEqual(
      nothing.copy.message,
      "No files or folders named \(PutioSearchResultPresentation.termMark). Try fewer words.")
  }

  func testIOSSearchStatesKeepTheirBoardCopy() throws {
    XCTAssertEqual(PutioSearchResultPresentation.start.title, "Find your files")
    XCTAssertNil(PutioSearchResultPresentation.start.kaomoji)
    let failure = try XCTUnwrap(
      PutioBrowserErrorPresentation(error: PutioRuntimeError.transient))
    XCTAssertEqual(PutioSearchResultPresentation.failed(failure).title, "Couldn’t search")
    XCTAssertEqual(PutioSearchResultPresentation.nothingMatches("x").copy.kaomoji, .shrug)
  }

  func testRecentSearchesAndPinnedCopy() {
    XCTAssertEqual(PutioRecentSearchesCopy.remove("sintel"), "Remove sintel from recent searches")
    XCTAssertEqual(PutioPinnedCopy.location("Movies"), "in Movies")
    XCTAssertEqual(PutioHomeCopy.itemCount(1), "1 item")
    XCTAssertEqual(PutioHomeCopy.itemCount(6), "6 items")
  }
}
