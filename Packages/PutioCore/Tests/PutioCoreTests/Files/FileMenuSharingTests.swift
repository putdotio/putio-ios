import XCTest

@testable import PutioCore

final class FileMenuSharingTests: XCTestCase {
  private let tv = PutioFileMenu.Capabilities.tv(tracksWatched: true, pinned: false)

  func testTheTVPanelListsTheBoardRowsForAFolder() {
    let folder = BrowserTestFixtures.item(id: 410, kind: .folder)
    XCTAssertEqual(
      PutioFileMenu(item: folder, capabilities: tv).sections,
      [[.open], [.pin], [.rename, .move], [.trash]])
  }

  func testTheTVPanelListsTheBoardRowsForAStartedVideo() {
    let video = BrowserTestFixtures.item(id: 412, resumePositionSeconds: 12)
    XCTAssertEqual(
      PutioFileMenu(item: video, capabilities: tv).sections,
      [[.play, .startOver, .openInVLC], [.pin, .markUnwatched], [.rename, .move], [.trash]])
    let fresh = BrowserTestFixtures.item(id: 413)
    XCTAssertFalse(PutioFileMenu(item: fresh, capabilities: tv).contains(.startOver))
  }

  func testIOSMenusKeepSelectAndLeaveOutPanelRows() {
    let folder = BrowserTestFixtures.item(id: 410, kind: .folder)
    let menu = PutioFileMenu(
      item: folder,
      capabilities: .init(
        canEdit: true, canDownload: true, vlcInstalled: true, tracksWatched: true))
    XCTAssertEqual(menu.sections, [[.select], [.rename, .move], [.trash]])
  }

  func testPanelTitlesResumeAndPinToHome() {
    let video = BrowserTestFixtures.item(id: 412, resumePositionSeconds: 12)
    XCTAssertEqual(
      PutioFileMenuRow.play.title(for: video, style: .panel, trashEnabled: true),
      "Resume from 0:12")
    XCTAssertEqual(PutioFileMenuRow.play.title(for: video, trashEnabled: true), "Play")
    XCTAssertEqual(
      PutioFileMenuRow.pin.title(for: video, style: .panel, trashEnabled: true), "Pin to Home")
    XCTAssertEqual(PutioFileMenuRow.pin.title(for: video, trashEnabled: true), "Pin")
    XCTAssertEqual(PutioFileMenuRow.trash.title(for: video, trashEnabled: true), "Move to trash")
    XCTAssertEqual(
      PutioFileMenuRow.trash.title(for: video, trashEnabled: false), "Delete permanently")
    XCTAssertNil(PutioFileMenuRow.playWithOtherMethod.title(for: video, trashEnabled: true))
  }

  func testOnlyAPermanentDeleteAsksFirst() {
    let item = BrowserTestFixtures.item(id: 412)
    let request = PutioFileItemActionRequest(row: .trash, item: item)
    XCTAssertEqual(request?.step(trashEnabled: true), .trash(item))
    XCTAssertEqual(request?.step(trashEnabled: false), .confirmPermanentDelete(item))
    XCTAssertEqual(
      PutioFileItemActionRequest(row: .markUnwatched, item: item)?.step(trashEnabled: true),
      .setWatched(item, false))
    XCTAssertNil(PutioFileItemActionRequest(row: .play, item: item))
  }

  func testOutcomeToastsShareOneCopySet() {
    let delete = PutioFileAction.delete(fileID: PutioFileID(rawValue: 1), name: "a")
    let permanent = PutioFileAction.delete(
      fileID: PutioFileID(rawValue: 1), name: "a", permanently: true)
    XCTAssertEqual(
      PutioFileActionOutcome.succeeded(delete).toastTitle(trashEnabled: true), "Moved to trash")
    XCTAssertEqual(
      PutioFileActionOutcome.succeeded(delete).toastTitle(trashEnabled: false), "Item deleted")
    XCTAssertEqual(
      PutioFileActionOutcome.succeeded(permanent).toastTitle(trashEnabled: true), "Item deleted")
    XCTAssertEqual(
      PutioFileActionOutcome.succeeded(
        .setWatched(fileID: PutioFileID(rawValue: 1), parentID: .root, name: "a", watched: true)
      ).toastTitle(trashEnabled: true),
      "Marked as watched")
    XCTAssertEqual(
      PutioFileActionOutcome.succeeded(
        .move(
          fileID: PutioFileID(rawValue: 1), name: "a", sourceParentID: .root,
          destinationID: PutioFileID(rawValue: 2), destinationName: "b")
      ).toastTitle(trashEnabled: true),
      "1 item is in the selected folder.")
    XCTAssertNil(
      PutioFileActionOutcome.succeeded(.sort(folderID: .root, sort: .nameDescending))
        .toastTitle(trashEnabled: true),
      "the header already shows the new sort")
  }

  func testDetailFactsListLengthAndSubtitlesOnlyForVideos() {
    let video = BrowserTestFixtures.item(id: 412, sizeBytes: 1_000_000)
    let details = PutioVideoDetails(
      resumePositionSeconds: 754, durationSeconds: 3_723, subtitles: ["English", "Turkish"])
    let detail = PutioFileDetailModel(
      item: video, isVideo: true, details: details, folder: "Movies")
    XCTAssertEqual(detail.primaryTitle, "Resume from 12:34")
    let locale = Locale(identifier: "en_US")
    XCTAssertEqual(
      detail.facts(locale: locale).map(\.kind), [.size, .added, .length, .subtitles, .folder])
    XCTAssertEqual(detail.facts(locale: locale)[2].value, "1:02:03")
    let file = PutioFileDetailModel(
      item: video, isVideo: false, details: details, folder: nil)
    XCTAssertEqual(file.facts(locale: locale).map(\.kind), [.size, .added])
    XCTAssertEqual(
      PutioFileDetailModel(
        item: BrowserTestFixtures.item(id: 413), isVideo: true, details: nil, folder: nil
      ).primaryTitle,
      "Play")
  }
}
