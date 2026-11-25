import PutioCore
import XCTest

@testable import PutioTV

final class TVFilesTests: XCTestCase {
  func testMenuOffersWatchStatusOnlyForVideosWhileRememberPositionIsOn() {
    let account = Self.account()
    XCTAssertEqual(
      TVFilePresentation.menuActions(for: Self.video(), account: account, canDelete: true),
      [.markWatched, .trash])
    XCTAssertEqual(
      TVFilePresentation.menuActions(
        for: Self.video(resumePositionSeconds: 90), account: account, canDelete: true),
      [.markUnwatched, .trash])
    XCTAssertEqual(
      TVFilePresentation.menuActions(
        for: Self.video(), account: Self.account(rememberVideoTime: false), canDelete: true),
      [.trash])
    XCTAssertEqual(
      TVFilePresentation.menuActions(
        for: Self.video(kind: .audio, resumePositionSeconds: 90), account: account,
        canDelete: true),
      [.trash])
    XCTAssertEqual(
      TVFilePresentation.menuActions(for: Self.video(), account: account, canDelete: false),
      [.markWatched], "Trash or Delete waits for the trash setting to be known")
  }

  /// The shipped app offers no actions on a file shared from another
  /// account, so its long press opens nothing.
  func testASharedFileHasNoMenuActions() {
    XCTAssertEqual(
      TVFilePresentation.menuActions(
        for: Self.video(resumePositionSeconds: 90, isShared: true), account: Self.account(),
        canDelete: true),
      [])
    XCTAssertEqual(
      TVFilePresentation.menuActions(
        for: Self.video(kind: .other("ZIP"), isShared: true), account: Self.account(),
        canDelete: true),
      [])
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

  func testOpeningAFolderBrowsesItAndAFileOpensItsScreen() {
    let folder = Self.video(id: 410, kind: .folder)
    XCTAssertEqual(
      TVRoute.opening(folder), .folder(PutioFolderRoute(id: folder.id, title: folder.name)))
    let video = Self.video()
    XCTAssertEqual(TVRoute.opening(video), .file(video))
  }

  func testAVideoRouteStartsWhereThePanelChose() {
    let video = Self.video(resumePositionSeconds: 90)
    XCTAssertEqual(TVRoute.video(video, .startOver).videoRoute?.start, .chosen(.startOver))
    XCTAssertEqual(TVRoute.video(video, .resume).videoRoute?.start, .chosen(.resume))
    XCTAssertNil(TVRoute.video(Self.video(kind: .other("ZIP")), .resume).videoRoute)
  }

  func testBrowsingSurvivesHistoryTurningOffUnlessHistoryOpenedIt() {
    let folder = TVRoute.folder(PutioFolderRoute(id: PutioFileID(rawValue: 410), title: "F"))
    let account = Self.account()
    var navigation = TVShellNavigation(selection: .files)
    navigation.setPath([folder, .file(Self.video())], for: .files, account: account)
    navigation.setPath([folder], for: .search, account: account)
    navigation.setPath([folder], for: .history, account: account)
    navigation.reconcile(account: Self.account(historyEnabled: false))
    XCTAssertEqual(navigation.path(for: .files), [folder, .file(Self.video())])
    XCTAssertEqual(navigation.path(for: .search), [folder])
    XCTAssertEqual(navigation.path(for: .history), [])
    XCTAssertEqual(navigation.selection, .files)
  }

  private static func video(
    id: Int = 412, kind: PutioFileKind = .video, resumePositionSeconds: Int = 0,
    isShared: Bool = false
  ) -> PutioFileItem {
    PutioFileItem(
      id: PutioFileID(rawValue: id), parentID: .root, name: "Root Movie.mkv", kind: kind,
      sizeBytes: 1, createdAt: .distantPast, updatedAt: .distantPast,
      resumePositionSeconds: resumePositionSeconds, isShared: isShared)
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
