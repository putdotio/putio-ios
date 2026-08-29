import Foundation
import PutioCore
import XCTest

@testable import Putio

final class PutioFileRouteTests: XCTestCase {
  func testFolderRouteIdentityAndHashUseOnlyStableID() {
    let original = PutioFolderRoute(id: PutioFileID(rawValue: 42), title: "Original")
    let renamed = PutioFolderRoute(id: PutioFileID(rawValue: 42), title: "Renamed")
    let other = PutioFolderRoute(id: PutioFileID(rawValue: 43), title: "Original")

    XCTAssertEqual(original, renamed)
    XCTAssertEqual(Set([original, renamed]).count, 1)
    XCTAssertNotEqual(original, other)
  }

  func testFolderAndFileRoutesRemainSeparate() throws {
    let folder = BrowserTestFixtures.item(id: 10, name: "Shows", kind: .folder)
    let file = BrowserTestFixtures.item(id: 11, name: "Episode.mkv", kind: .video)

    let folderPresentation = PutioBrowserItemPresentation(item: folder)
    XCTAssertEqual(folderPresentation.folderRoute?.id, folder.id)
    XCTAssertEqual(folderPresentation.folderRoute?.title, folder.name)
    XCTAssertNil(folderPresentation.fileRoute)

    let filePresentation = PutioBrowserItemPresentation(item: file)
    XCTAssertNil(filePresentation.folderRoute)
    XCTAssertEqual(try XCTUnwrap(filePresentation.fileRoute).item, file)
  }

  func testRowPresentationMapsEveryRuntimeKind() {
    let cases: [(PutioFileKind, PutioFileRowModel.Kind)] = [
      (.folder, .folder),
      (.video, .video),
      (.audio, .audio),
      (.image, .image),
      (.pdf, .file),
      (.other("ARCHIVE"), .file),
    ]

    for (index, testCase) in cases.enumerated() {
      let item = BrowserTestFixtures.item(id: index, kind: testCase.0)
      XCTAssertEqual(PutioBrowserItemPresentation(item: item).row.kind, testCase.1)
    }
  }

  func testRowPresentationUsesRawNameSizeRelativeDateAndWatchedState() throws {
    let item = BrowserTestFixtures.item(
      id: 12,
      name: "The.Wire.S03E04.Back.Burners.mkv",
      kind: .video,
      sizeBytes: 4_682_500_000,
      resumePositionSeconds: 120
    )

    let presentation = PutioBrowserItemPresentation(
      item: item,
      relativeTo: BrowserTestFixtures.referenceDate,
      locale: Locale(identifier: "en_US")
    )

    XCTAssertEqual(presentation.row.name, item.name)
    XCTAssertEqual(presentation.row.kind, .video)
    XCTAssertTrue(presentation.row.isWatched)
    let detail = try XCTUnwrap(presentation.row.sizeText)
    XCTAssertTrue(detail.hasPrefix("4.68 GB · "))
    XCTAssertFalse(detail.hasSuffix(" · "))
  }

  func testFolderRowOmitsFileSizeAndRelativeDate() {
    let folder = BrowserTestFixtures.item(
      id: 13,
      name: "Films",
      kind: .folder,
      sizeBytes: 9_999
    )

    XCTAssertNil(PutioBrowserItemPresentation(item: folder).row.sizeText)
  }
}
