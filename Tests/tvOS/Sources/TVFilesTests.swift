import PutioCore
import XCTest

@testable import PutioTV

final class TVFilesTests: XCTestCase {
  func testMenuOffersWatchStatusOnlyForVideosWhileRememberPositionIsOn() {
    let account = Self.account()
    XCTAssertEqual(
      TVFilePresentation.menuActions(for: Self.video(), account: account, canDelete: true),
      [.markWatched, .delete])
    XCTAssertEqual(
      TVFilePresentation.menuActions(
        for: Self.video(resumePositionSeconds: 90), account: account, canDelete: true),
      [.markUnwatched, .delete])
    XCTAssertEqual(
      TVFilePresentation.menuActions(
        for: Self.video(), account: Self.account(rememberVideoTime: false), canDelete: true),
      [.delete])
    XCTAssertEqual(
      TVFilePresentation.menuActions(
        for: Self.video(kind: .audio, resumePositionSeconds: 90), account: account,
        canDelete: true),
      [.delete])
    XCTAssertEqual(
      TVFilePresentation.menuActions(for: Self.video(), account: account, canDelete: false),
      [.markWatched], "Trash or Delete waits for the trash setting to be known")
  }

  /// The shipped TV sort menu: the current key flips, every other key keeps
  /// the current direction, and the current sort itself is never offered.
  func testSortChoicesMatchTheShippedMenu() {
    XCTAssertEqual(
      TVFilePresentation.sortChoices(from: .nameAscending),
      [
        .nameDescending, .sizeAscending, .dateAddedAscending, .dateModifiedAscending,
        .typeAscending, .watchStatusAscending,
      ])
    XCTAssertEqual(
      TVFilePresentation.sortChoices(from: .sizeDescending),
      [
        .nameDescending, .sizeAscending, .dateAddedDescending, .dateModifiedDescending,
        .typeDescending, .watchStatusDescending,
      ])
  }

  func testAFolderWithoutItsOwnSortFollowsTheAccountDefault() {
    XCTAssertEqual(
      TVFilePresentation.effectiveSort(.sizeAscending, account: Self.account(defaultSort: nil)),
      .sizeAscending)
    XCTAssertEqual(
      TVFilePresentation.effectiveSort(
        nil, account: Self.account(defaultSort: .dateAddedDescending)),
      .dateAddedDescending)
    XCTAssertEqual(
      TVFilePresentation.effectiveSort(nil, account: Self.account(defaultSort: nil)),
      .nameAscending)
  }

  /// History and Search open what the browser opens: folders browse, and
  /// every other file gets its own screen.
  func testOpeningAFolderBrowsesItAndAFileOpensItsScreen() {
    let folder = Self.video(id: 410, kind: .folder)
    XCTAssertEqual(
      TVRoute.opening(folder), .folder(PutioFolderRoute(id: folder.id, title: folder.name)))
    let video = Self.video()
    XCTAssertEqual(TVRoute.opening(video), .file(video))
  }

  func testBrowsingSurvivesHistoryTurningOffUnlessHistoryOpenedIt() {
    let folder = TVRoute.folder(PutioFolderRoute(id: PutioFileID(rawValue: 410), title: "F"))
    let historyOff = Self.account(historyEnabled: false)
    XCTAssertEqual(
      TVRoute.reconcile([.files, folder, .file(Self.video())], account: historyOff),
      [.files, folder, .file(Self.video())])
    XCTAssertEqual(TVRoute.reconcile([.search, folder], account: historyOff), [.search, folder])
    XCTAssertEqual(TVRoute.reconcile([.history, folder], account: historyOff), [])
  }

  func testRemovingARowFocusesTheNextRowOrThePreviousAtTheEnd() {
    let items = [410, 412, 406].map { Self.video(id: $0) }
    let all = Set(items.map(\.id))
    XCTAssertEqual(
      TVFilePresentation.focusAfterRemoving(
        PutioFileID(rawValue: 412), from: items, firstPage: all),
      PutioFileID(rawValue: 406))
    XCTAssertEqual(
      TVFilePresentation.focusAfterRemoving(
        PutioFileID(rawValue: 406), from: items, firstPage: all),
      PutioFileID(rawValue: 412))
    XCTAssertNil(
      TVFilePresentation.focusAfterRemoving(
        PutioFileID(rawValue: 410), from: [items[0]], firstPage: all))
  }

  /// The removal reloads only the first page; a neighbour on a later page
  /// would vanish and send focus back to the top.
  func testRemovingALaterPageRowFocusesARowTheReloadKeeps() {
    let items = [424, 410, 422, 426].map { Self.video(id: $0) }
    let firstPage: Set = [PutioFileID(rawValue: 424), PutioFileID(rawValue: 410)]
    XCTAssertEqual(
      TVFilePresentation.focusAfterRemoving(
        PutioFileID(rawValue: 422), from: items, firstPage: firstPage),
      PutioFileID(rawValue: 410))
    XCTAssertEqual(
      TVFilePresentation.focusAfterRemoving(
        PutioFileID(rawValue: 424), from: items, firstPage: firstPage),
      PutioFileID(rawValue: 410))
  }

  /// Search refreshes after a folder mutation even when the folder screen
  /// closed before it settled: the request follows the mutation, not the view.
  @MainActor
  func testFolderMutationAsksOtherScreensToRefreshOnceItSettles() async {
    let requests = PutioFolderRefreshRequests()
    let search = PutioFolderRefreshRegistration(folderID: .root, requests: requests)
    search.activate()
    let screen = UUID()
    var settled = false

    await TVFolderMutation.run(.allFolders, requests: requests, owner: screen) {
      XCTAssertNil(requests.sequence(for: .root, owner: search.owner), "asked before settling")
      settled = true
    }

    XCTAssertTrue(settled)
    XCTAssertNotNil(requests.sequence(for: .root, owner: search.owner))
  }

  func testToastsNameTheActionAndFollowTheTrashSetting() {
    let video = Self.video()
    let delete = PutioFileAction.delete(fileID: video.id, name: video.name)
    XCTAssertEqual(
      TVFilePresentation.toast(for: .succeeded(delete), trashEnabled: true)?.title,
      "Moved to Trash")
    XCTAssertEqual(
      TVFilePresentation.toast(for: .succeeded(delete), trashEnabled: false)?.title,
      "Item deleted")
    XCTAssertEqual(
      TVFilePresentation.toast(
        for: .succeeded(
          .setWatched(fileID: video.id, parentID: .root, name: video.name, watched: false)),
        trashEnabled: true)?.title,
      "Marked as unwatched")
    XCTAssertNil(
      TVFilePresentation.toast(
        for: .succeeded(.sort(folderID: .root, sort: .nameDescending)), trashEnabled: true),
      "the header already shows the new sort")
  }

  private static func video(
    id: Int = 412, kind: PutioFileKind = .video, resumePositionSeconds: Int = 0
  ) -> PutioFileItem {
    PutioFileItem(
      id: PutioFileID(rawValue: id), parentID: .root, name: "Root Movie.mkv", kind: kind,
      sizeBytes: 1, createdAt: .distantPast, updatedAt: .distantPast,
      resumePositionSeconds: resumePositionSeconds)
  }

  private static func account(
    rememberVideoTime: Bool = true, defaultSort: PutioFolderSort? = nil,
    historyEnabled: Bool = true
  ) -> PutioAccountSnapshot {
    PutioAccountSnapshot(
      id: 1001, username: "moviebuff", email: "moviebuff@example.com", suggestNextVideo: true,
      rememberVideoTime: rememberVideoTime, defaultSort: defaultSort,
      historyEnabled: historyEnabled, trashEnabled: true,
      storage: PutioAccountSnapshot.Storage(availableBytes: 1, totalBytes: 2, usedBytes: 1),
      routeName: "default", hideSubtitles: false, dontAutoSelectSubtitles: false,
      twoFactorEnabled: false, trashSizeBytes: 0)
  }
}
