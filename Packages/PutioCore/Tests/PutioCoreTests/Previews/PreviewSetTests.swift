import Foundation
import XCTest

@testable import PutioCore

@MainActor
final class PreviewSetTests: XCTestCase {
  private let images = [
    BrowserTestFixtures.item(id: 1, kind: .image),
    BrowserTestFixtures.item(id: 2, kind: .video),
    BrowserTestFixtures.item(id: 3, kind: .image),
    BrowserTestFixtures.item(id: 4, kind: .pdf),
    BrowserTestFixtures.item(id: 5, kind: .image, sizeBytes: PutioPreviewRoute.maximumBytes + 1),
  ]

  func testTheSetHoldsTheFolderFilesOfTheShownKindInListingOrder() throws {
    let set = try XCTUnwrap(
      PutioPreviewSet(items: images, shownID: PutioFileID(rawValue: 3), kind: .image))
    XCTAssertEqual(set.items.map(\.id.rawValue), [1, 3, 5])
    XCTAssertEqual(set.index, 1)
    XCTAssertEqual(set.position(hasMore: false)?.text, "2 / 3")
    XCTAssertEqual(set.position(hasMore: true)?.text, "2 / 3+")
  }

  func testOneFileOrAMissingFileHasNoPosition() {
    let document = PutioPreviewSet(items: images, shownID: PutioFileID(rawValue: 4), kind: .pdf)
    XCTAssertEqual(document?.pages, false)
    XCTAssertNil(document?.position(hasMore: true))
    XCTAssertNil(PutioPreviewSet(items: images, shownID: PutioFileID(rawValue: 9), kind: .image))
  }

  func testPagesAreReadNearTheEndUntilThreeBringNothingThenAgainAtTheLastFile() {
    var reads = PutioPreviewPageReads()
    XCTAssertFalse(reads.shouldRead(index: 0, count: 20, hasMore: true))
    XCTAssertFalse(reads.shouldRead(index: 14, count: 20, hasMore: false))
    XCTAssertTrue(reads.shouldRead(index: 14, count: 20, hasMore: true))
    reads.didRead(countBefore: 20, countAfter: 26)
    XCTAssertEqual(reads.fruitless, 0)
    for _ in 0..<3 {
      XCTAssertTrue(reads.shouldRead(index: 20, count: 26, hasMore: true))
      reads.didRead(countBefore: 26, countAfter: 26)
    }
    XCTAssertTrue(reads.stopped)
    XCTAssertFalse(reads.shouldRead(index: 24, count: 26, hasMore: true))
    XCTAssertTrue(reads.shouldRead(index: 25, count: 26, hasMore: true))
    XCTAssertFalse(reads.stopped)
  }

  func testTheFolderSourceAppendsTheNextPage() async {
    let later = BrowserTestFixtures.item(id: 6, kind: .image)
    let model = PutioFolderModel(
      folderID: .root,
      load: { _ in BrowserTestFixtures.contents(items: []) },
      continueLoad: { _ in BrowserTestFixtures.contents(items: [later]) },
      initialContents: BrowserTestFixtures.contents(items: images, hasMore: true))
    let source = model.previewSource
    XCTAssertTrue(source.hasMore())
    let loaded = await source.loadMore()
    XCTAssertTrue(loaded)
    XCTAssertFalse(source.hasMore())
    XCTAssertEqual(
      PutioPreviewSet(items: source.items(), shownID: PutioFileID(rawValue: 1), kind: .image)?
        .items.map(\.id.rawValue),
      [1, 3, 5, 6])
  }
}
