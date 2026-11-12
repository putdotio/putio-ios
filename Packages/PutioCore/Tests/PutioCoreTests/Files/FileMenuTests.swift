import Foundation
import XCTest

@testable import PutioCore

final class FileMenuTests: XCTestCase {
  private let everything = PutioFileMenu.Capabilities(
    canEdit: true, canDownload: true, vlcInstalled: true, tracksWatched: true)

  func testRowsFollowTheIssueOrderPerItemKind() {
    XCTAssertEqual(
      PutioFileMenu(item: item(.video, resume: 0), capabilities: everything).sections,
      [
        [.play, .download, .openInVLC], [.select, .markWatched], [.rename, .move], [.trash],
      ])
    XCTAssertEqual(
      PutioFileMenu(item: item(.other("iso")), capabilities: everything).sections,
      [[.select], [.rename, .move], [.trash]])
    XCTAssertEqual(
      PutioFileMenu(item: item(.folder), capabilities: everything).sections,
      [[.select], [.rename, .move], [.trash]])
  }

  func testWatchedVideoOffersUnwatched() {
    let menu = PutioFileMenu(item: item(.video, resume: 1_260), capabilities: everything)
    XCTAssertTrue(menu.contains(.markUnwatched))
    XCTAssertFalse(menu.contains(.markWatched))
  }

  func testOptionalRowsHideWithoutTheirCapability() {
    let menu = PutioFileMenu(
      item: item(.video, resume: 0),
      capabilities: .init(
        canEdit: true, canDownload: false, vlcInstalled: false, tracksWatched: false))
    XCTAssertEqual(menu.sections, [[.play], [.select], [.rename, .move], [.trash]])
    XCTAssertEqual(menu.trailingSwipe, [.trash])
  }

  func testWatchStatusIsForVideosOnly() {
    let audio = PutioFileMenu(item: item(.audio, resume: 0), capabilities: everything)
    XCTAssertFalse(audio.contains(.markWatched))
    XCTAssertFalse(audio.contains(.markUnwatched))
  }

  func testSwipesMatchTheBoard() {
    let video = PutioFileMenu(item: item(.video, resume: 0), capabilities: everything)
    XCTAssertEqual(video.trailingSwipe, [.trash, .download])
    XCTAssertEqual(video.leadingSwipe, [.move])
    let folder = PutioFileMenu(item: item(.folder), capabilities: everything)
    XCTAssertEqual(folder.trailingSwipe, [.trash])
  }

  func testReadOnlyListsOfferOnlyPlayback() {
    let menu = PutioFileMenu(
      item: item(.video, resume: 0),
      capabilities: .init(
        canEdit: false, canDownload: true, vlcInstalled: false, tracksWatched: true))
    XCTAssertEqual(menu.sections, [[.play, .download]])
    XCTAssertEqual(menu.leadingSwipe, [])
  }

  func testSharedItemsOfferNoActions() {
    let shared = item(.video, resume: 0, shared: true)
    XCTAssertEqual(
      PutioFileMenu(item: shared, capabilities: everything).sections,
      [[.play, .download, .openInVLC]])
    XCTAssertEqual(
      PutioFileMenu(item: item(.folder, shared: true), capabilities: everything).sections, [])
  }

  func testSelectionBarFollowsTheIssueTable() {
    let videos = [item(.video, resume: 0), item(.video, resume: 90)]
    XCTAssertEqual(selectionBar(videos), [.move, .download, .markWatched, .trash])
    XCTAssertEqual(selectionBar(videos + [item(.folder)]), [.move, .trash])
    XCTAssertEqual(selectionBar([item(.video), item(.other("pdf"))]), [.move, .trash])
    XCTAssertEqual(selectionBar([]), [.move, .trash])
  }

  func testSelectionOffersUnwatchedOnlyWhenEveryVideoIsWatched() {
    XCTAssertEqual(
      selectionBar([item(.video, resume: 1), item(.video, resume: 90)]),
      [.move, .download, .markUnwatched, .trash])
  }

  func testSelectionWatchStatusIsForVideosOnlyWithResumeTrackingOn() {
    XCTAssertEqual(selectionBar([item(.video), item(.audio)]), [.move, .download, .trash])
    XCTAssertEqual(
      PutioFileSelectionMenu(selected: [item(.video)], canDownload: false, tracksWatched: false)
        .actions,
      [.move, .trash])
  }

  private func selectionBar(_ items: [PutioFileItem]) -> [PutioFileSelectionAction] {
    PutioFileSelectionMenu(selected: items, canDownload: true, tracksWatched: true).actions
  }

  func testShareFollowsDownloadForFilesUnderThePreviewCap() {
    let sharing = PutioFileMenu.Capabilities(
      canEdit: true, canDownload: true, vlcInstalled: false, tracksWatched: false,
      canShare: true)
    let cap = PutioPreviewRoute.maximumBytes
    func rows(_ kind: PutioFileKind, size: Int64 = 1, downloaded: Bool = false)
      -> [PutioFileMenuRow]
    {
      PutioFileMenu(
        item: item(kind, size: size), capabilities: sharing, isDownloaded: downloaded
      ).sections.first ?? []
    }
    XCTAssertEqual(rows(.image), [.share])
    XCTAssertEqual(rows(.pdf, size: cap), [.share])
    XCTAssertEqual(rows(.text), [.share])
    XCTAssertEqual(rows(.video, downloaded: true), [.play, .download, .share])
    XCTAssertEqual(rows(.audio, downloaded: true), [.play, .download, .share])
    XCTAssertEqual(rows(.video), [.play, .download])
    XCTAssertEqual(rows(.audio), [.play, .download])
    XCTAssertEqual(rows(.image, size: cap + 1), [.select])
    XCTAssertEqual(rows(.video, size: cap + 1, downloaded: true), [.play, .download])
    XCTAssertEqual(rows(.other("iso")), [.select])
    XCTAssertFalse(
      PutioFileMenu(item: item(.folder), capabilities: sharing, isDownloaded: true)
        .contains(.share))
    XCTAssertFalse(PutioFileMenu(item: item(.image), capabilities: everything).contains(.share))
  }

  private func item(
    _ kind: PutioFileKind, resume: Int = 0, shared: Bool = false, size: Int64 = 1
  ) -> PutioFileItem {
    PutioFileItem(
      id: PutioFileID(rawValue: 7), parentID: .root, name: "Item", kind: kind, sizeBytes: size,
      createdAt: .distantPast, updatedAt: .distantPast, resumePositionSeconds: resume,
      isShared: shared)
  }
}
