import PutioCore
import XCTest

@testable import PutioTV

final class TVAccountHistoryTrashTests: XCTestCase {
  func testTurningHistoryOffClosesHistoryAndTheFileItOpened() {
    let path: [TVRoute] = [.history, .file(Self.file)]
    XCTAssertEqual(TVRoute.reconcile(path, account: Self.account()), path)
    XCTAssertEqual(TVRoute.reconcile(path, account: Self.account(historyEnabled: false)), [])
  }

  func testTurningTrashOffClosesTrashButKeepsAccount() {
    let path: [TVRoute] = [.account, .trash]
    XCTAssertEqual(TVRoute.reconcile(path, account: Self.account()), path)
    XCTAssertEqual(TVRoute.reconcile(path, account: Self.account(trashEnabled: false)), [.account])
    XCTAssertEqual(
      TVRoute.reconcile([.account, .proxy], account: Self.account(trashEnabled: false)),
      [.account, .proxy])
  }

  func testHomeListsHistoryOnlyWhileTheAccountKeepsIt() {
    XCTAssertEqual(
      TVHomeEntry.entries(for: Self.account()), [.files, .search, .history, .account])
    XCTAssertEqual(
      TVHomeEntry.entries(for: Self.account(historyEnabled: false)), [.files, .search, .account])
  }

  func testAccountRowsFollowTheSettingsTheyDependOn() {
    XCTAssertEqual(
      TVAccountSection.playback.rows(for: Self.account()),
      [.proxy, .rememberPosition, .showSubtitles, .subtitleSelection])
    XCTAssertEqual(
      TVAccountSection.playback.rows(for: Self.account(hideSubtitles: true)),
      [.proxy, .rememberPosition, .showSubtitles])
    XCTAssertEqual(TVAccountSection.storage.rows(for: Self.account()), [.trash, .manageTrash])
    XCTAssertEqual(TVAccountSection.storage.rows(for: Self.account(trashEnabled: false)), [.trash])
  }

  func testTVOffersNoPlaybackTypeOrBufferSetting() {
    let titles = TVAccountSection.allCases.flatMap { $0.rows(for: Self.account()) }.map(\.title)
    XCTAssertFalse(
      titles.contains { $0.localizedCaseInsensitiveContains("type") },
      "playback type belongs to the system player on tvOS: \(titles)")
    XCTAssertFalse(titles.contains { $0.localizedCaseInsensitiveContains("buffer") })
  }

  /// Rows show and send the account's own semantics: "Show subtitles" is
  /// the inverse of `hide_subtitles`, and turning Trash off is confirmed.
  func testRowValuesAndChangesUseTheSharedSettings() {
    let account = Self.account(hideSubtitles: true, dontAutoSelectSubtitles: true)
    XCTAssertEqual(TVAccountRow.showSubtitles.isOn(in: account), false)
    XCTAssertEqual(TVAccountRow.subtitleSelection.isOn(in: account), true)
    XCTAssertEqual(TVAccountRow.rememberPosition.isOn(in: account), true)
    XCTAssertEqual(TVAccountRow.trash.isOn(in: account), true)
    XCTAssertNil(TVAccountRow.proxy.isOn(in: account))

    XCTAssertEqual(TVAccountRow.showSubtitles.change(to: true), .save(.showSubtitles(true)))
    XCTAssertEqual(
      TVAccountRow.subtitleSelection.change(to: false), .save(.dontAutoSelectSubtitles(false)))
    XCTAssertEqual(TVAccountRow.trash.change(to: true), .save(.trash(true)))
    XCTAssertEqual(TVAccountRow.trash.change(to: false), .confirmDisablingTrash)
    XCTAssertNil(TVAccountRow.rememberPosition.change(to: false))
  }

  func testHistoryShowsOnlyCompletedTransfersAndShares() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let page = PutioHistoryPage(
      items: [
        Self.event(
          1,
          .transferCompleted(
            name: "Movie.mkv", sizeBytes: 1_073_741_824, fileID: .init(rawValue: 11)), at: now),
        Self.event(
          2, .upload(name: "Notes.txt", sizeBytes: 10, fileID: .init(rawValue: 12)), at: now),
        Self.event(
          3,
          .fileShared(name: "Shared.mkv", sharingUserName: "friend", fileID: .init(rawValue: 13)),
          at: now),
        Self.event(4, .transferError(name: "Broken.zip"), at: now),
      ],
      nextBefore: nil)

    let sections = TVHistoryPresentation.sections(page, now: now)
    XCTAssertEqual(sections.flatMap(\.items).map(\.id), [1, 3])
    XCTAssertFalse(TVHistoryPresentation.isEmpty(page))
    XCTAssertEqual(
      TVHistoryPresentation.detail(page.items[0], now: now, locale: Locale(identifier: "en_US")),
      "now · 1.07 GB")
    XCTAssertEqual(
      TVHistoryPresentation.detail(page.items[2], now: now, locale: Locale(identifier: "en_US")),
      "now · Shared by friend")
  }

  /// A page of hidden events with more to load is still loading, so the
  /// screen must not claim History is empty before walking it.
  func testHiddenEventsWithAContinuationAreNotEmpty() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let hidden = [Self.event(2, .transferError(name: "Broken.zip"), at: now)]
    XCTAssertFalse(TVHistoryPresentation.isEmpty(PutioHistoryPage(items: hidden, nextBefore: 2)))
    XCTAssertTrue(TVHistoryPresentation.isEmpty(PutioHistoryPage(items: hidden, nextBefore: nil)))
  }

  private static let file = PutioFileItem(
    id: PutioFileID(rawValue: 411), parentID: .root, name: "Nested Movie.mkv", kind: .video,
    sizeBytes: 1, createdAt: .distantPast, updatedAt: .distantPast, resumePositionSeconds: 0)

  private static func event(
    _ id: Int, _ kind: PutioHistoryEventKind, at date: Date
  ) -> PutioHistoryEventItem {
    PutioHistoryEventItem(id: id, createdAt: date, kind: kind)
  }

  private static func account(
    historyEnabled: Bool = true, trashEnabled: Bool = true, hideSubtitles: Bool = false,
    dontAutoSelectSubtitles: Bool = false
  ) -> PutioAccountSnapshot {
    PutioAccountSnapshot(
      id: 1001, username: "moviebuff", email: "moviebuff@example.com", suggestNextVideo: true,
      rememberVideoTime: true, defaultSort: nil, historyEnabled: historyEnabled,
      trashEnabled: trashEnabled,
      storage: PutioAccountSnapshot.Storage(availableBytes: 1, totalBytes: 2, usedBytes: 1),
      hideSubtitles: hideSubtitles, dontAutoSelectSubtitles: dontAutoSelectSubtitles)
  }
}
