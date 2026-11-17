import XCTest

@testable import PutioCore

final class FilesSearchTotalTests: XCTestCase {
  private let english = Locale(identifier: "en_US")

  func testAPartialPageShowsPutioTotalNotTheLoadedRows() {
    let total = PutioFileSearchTotal(page: page(1...50, cursor: "next", total: 497), filter: .all)
    XCTAssertEqual(total, PutioFileSearchTotal(count: 497, isAtLeast: false))
    XCTAssertEqual(total?.label(locale: english), "497 results")
  }

  func testATotalAtTheCapReadsAsAtLeastTheCap() {
    let total = PutioFileSearchTotal(page: page(1...50, cursor: "next", total: 1_000), filter: .all)
    XCTAssertEqual(total, PutioFileSearchTotal(count: 1_000, isAtLeast: true))
    XCTAssertEqual(total?.label(locale: english), "1,000+ results")
  }

  func testACappedSearchStaysAtLeastOnceEveryPageLoaded() {
    let total = PutioFileSearchTotal(page: page(1...1_000, cursor: nil, total: 1_000), filter: .all)
    XCTAssertEqual(total?.label(locale: english), "1,000+ results")
  }

  func testACompleteSearchCountsWhatItLoaded() {
    let total = PutioFileSearchTotal(page: page(1...3, cursor: nil, total: 5), filter: .videos)
    XCTAssertEqual(total, PutioFileSearchTotal(count: 3, isAtLeast: false))
  }

  func testOneResultIsSingular() {
    let total = PutioFileSearchTotal(page: page(1...1, cursor: nil, total: 1), filter: .all)
    XCTAssertEqual(total?.label(locale: english), "1 result")
  }

  func testRemovedResultsLowerTheTotal() {
    let removed: Set = [PutioFileID(rawValue: 1), PutioFileID(rawValue: 2)]
    let exact = PutioFileSearchTotal(
      page: page(1...50, cursor: "next", total: 497), filter: .all, hiddenIDs: removed)
    XCTAssertEqual(exact, PutioFileSearchTotal(count: 495, isAtLeast: false))
    let capped = PutioFileSearchTotal(
      page: page(1...50, cursor: "next", total: 1_000), filter: .all, hiddenIDs: removed)
    XCTAssertEqual(capped, PutioFileSearchTotal(count: 998, isAtLeast: true))
  }

  func testSubtitlesCountOnlyOnceEveryPageLoaded() {
    let items = [
      BrowserTestFixtures.item(id: 1, name: "Sintel.srt", kind: .text),
      BrowserTestFixtures.item(id: 2, name: "Sintel.mkv"),
      BrowserTestFixtures.item(id: 3, name: "Sintel.vtt", kind: .text),
    ]
    let partial = PutioFileSearchPage(items: items, nextCursor: "next", totalCount: 40)
    XCTAssertNil(PutioFileSearchTotal(page: partial, filter: .subtitles))
    let complete = PutioFileSearchPage(items: items, nextCursor: nil, totalCount: 40)
    XCTAssertEqual(
      PutioFileSearchTotal(page: complete, filter: .subtitles),
      PutioFileSearchTotal(count: 2, isAtLeast: false))
  }

  private func page(_ ids: ClosedRange<Int>, cursor: String?, total: Int) -> PutioFileSearchPage {
    PutioFileSearchPage(
      items: ids.map { BrowserTestFixtures.item(id: $0) }, nextCursor: cursor, totalCount: total)
  }
}
