import Foundation
import PutioCore
import XCTest

@testable import Putio

final class PutioFileRouteTests: XCTestCase {
  func testDeletionPresentationDistinguishesTrashFromPermanentDeletion() {
    let trash = PutioFileDeletionPresentation(trashEnabled: true)
    XCTAssertEqual(trash.actionTitle, "Trash")
    XCTAssertEqual(trash.confirmationTitle(itemName: "Weekend"), "Move “Weekend” to Trash?")
    XCTAssertEqual(trash.confirmationTitle(itemCount: 2), "Move 2 items to Trash?")
    XCTAssertEqual(trash.confirmationMessage(itemCount: 1), "You can restore this item from Trash.")
    XCTAssertEqual(
      trash.progressTitle(currentItem: 1, totalItems: 2), "Moving item 1 of 2 to Trash…")
    XCTAssertEqual(
      trash.failureTitle(allItemsFailed: false), "Some items couldn’t be moved to Trash")
    XCTAssertEqual(
      trash.outcomeMessage(succeeded: 1, failed: 1),
      "Moved 1 item to Trash. 1 couldn’t be moved to Trash.")

    let permanentDelete = PutioFileDeletionPresentation(trashEnabled: false)
    XCTAssertEqual(permanentDelete.actionTitle, "Delete")
    XCTAssertEqual(
      permanentDelete.confirmationTitle(itemName: "Weekend"),
      "Delete “Weekend” permanently?"
    )
    XCTAssertEqual(
      permanentDelete.confirmationTitle(itemCount: 2),
      "Delete 2 items permanently?"
    )
    XCTAssertEqual(
      permanentDelete.confirmationMessage(itemCount: 1), "This item cannot be restored.")
    XCTAssertEqual(
      permanentDelete.progressTitle(currentItem: 1, totalItems: 2),
      "Deleting item 1 of 2…"
    )
    XCTAssertEqual(
      permanentDelete.failureTitle(allItemsFailed: false),
      "Some items couldn’t be deleted"
    )
    XCTAssertEqual(
      permanentDelete.outcomeMessage(succeeded: 1, failed: 1),
      "Deleted 1 item. 1 couldn’t be deleted."
    )
  }

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

  func testOnlyVideoRoutesRefineIntoPlaybackRoutes() throws {
    let video = PutioFileRoute(item: BrowserTestFixtures.item(id: 20, kind: .video))
    let videoRoute = try XCTUnwrap(video.videoPlaybackRoute)
    XCTAssertEqual(videoRoute.id, video.item.id)
    XCTAssertEqual(videoRoute.parentID, video.item.parentID)
    XCTAssertEqual(videoRoute.title, video.item.name)

    let nonVideoKinds: [PutioFileKind] = [
      .audio,
      .image,
      .pdf,
      .other("ARCHIVE"),
    ]
    for (index, kind) in nonVideoKinds.enumerated() {
      let route = PutioFileRoute(
        item: BrowserTestFixtures.item(id: 21 + index, kind: kind)
      )
      XCTAssertNil(route.videoPlaybackRoute, "\(kind) unexpectedly opened the video player")
    }
  }

  func testNextVideoMapsIntoPlaybackRoute() {
    let nextVideo = PutioNextVideo(
      id: PutioFileID(rawValue: 22),
      parentID: PutioFileID(rawValue: 10),
      name: "Episode 2.mkv"
    )
    let resolution = PutioPlaybackResolution.ready(
      PutioPlaybackSource(
        url: URL(fileURLWithPath: "/episode-2.m3u8"),
        startFromSeconds: 37
      )
    )
    let playableNextVideo = PutioPlayableNextVideo(
      video: nextVideo,
      initialResolution: resolution
    )

    let route = PutioVideoRoute(nextVideo: playableNextVideo)

    XCTAssertEqual(route.id, nextVideo.id)
    XCTAssertEqual(route.parentID, nextVideo.parentID)
    XCTAssertEqual(route.title, nextVideo.name)
    XCTAssertEqual(route.initialResolution, resolution)
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
