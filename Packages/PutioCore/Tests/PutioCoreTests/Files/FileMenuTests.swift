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
    XCTAssertEqual(
      PutioFileSelectionMenu(selected: videos, capabilities: everything).actions,
      [.move, .download, .markWatched, .trash])
    XCTAssertEqual(
      PutioFileSelectionMenu(selected: videos + [item(.folder)], capabilities: everything)
        .actions,
      [.move, .trash])
    XCTAssertEqual(
      PutioFileSelectionMenu(
        selected: [item(.video), item(.other("pdf"))], capabilities: everything
      )
      .actions,
      [.move, .trash])
    XCTAssertEqual(
      PutioFileSelectionMenu(selected: [], capabilities: everything).actions, [.move, .trash])
  }

  func testSelectionOffersUnwatchedOnlyWhenEveryVideoIsWatched() {
    XCTAssertEqual(
      PutioFileSelectionMenu(
        selected: [item(.video, resume: 1), item(.video, resume: 90)], capabilities: everything
      ).actions,
      [.move, .download, .markUnwatched, .trash])
  }

  func testSelectionWatchStatusIsForVideosOnlyWithResumeTrackingOn() {
    XCTAssertEqual(
      PutioFileSelectionMenu(selected: [item(.video), item(.audio)], capabilities: everything)
        .actions,
      [.move, .download, .trash])
    XCTAssertEqual(
      PutioFileSelectionMenu(
        selected: [item(.video)],
        capabilities: .init(
          canEdit: true, canDownload: false, vlcInstalled: true, tracksWatched: false)
      ).actions,
      [.move, .trash])
  }

  private func item(_ kind: PutioFileKind, resume: Int = 0, shared: Bool = false)
    -> PutioFileItem
  {
    PutioFileItem(
      id: PutioFileID(rawValue: 7), parentID: .root, name: "Item", kind: kind, sizeBytes: 1,
      createdAt: .distantPast, updatedAt: .distantPast, resumePositionSeconds: resume,
      isShared: shared)
  }
}
