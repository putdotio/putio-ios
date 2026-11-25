import PutioCore
import XCTest

@testable import PutioTV

final class TVAccountHistoryTrashTests: XCTestCase {
  func testTurningHistoryOffClosesItsTabAndTheFileItOpened() {
    var navigation = TVShellNavigation(selection: .history)
    navigation.setPath([.file(Self.file)], for: .history, account: Self.account())
    navigation.reconcile(account: Self.account())
    XCTAssertEqual(navigation.path(for: .history), [.file(Self.file)])
    navigation.reconcile(account: Self.account(historyEnabled: false))
    XCTAssertEqual(navigation.path(for: .history), [])
    XCTAssertEqual(navigation.selection, .home)
  }

  func testTurningTrashOffClosesTrashButKeepsTheOtherAccountPages() {
    var navigation = TVShellNavigation(selection: .account)
    navigation.setPath([.trash], for: .account, account: Self.account())
    navigation.reconcile(account: Self.account(trashEnabled: false))
    XCTAssertEqual(navigation.path(for: .account), [])
    navigation.setPath([.privacy], for: .account, account: Self.account(trashEnabled: false))
    XCTAssertEqual(navigation.path(for: .account), [.privacy])
  }

  func testTabBarOffersHistoryOnlyWhileTheAccountKeepsIt() {
    XCTAssertEqual(
      TVTab.tabs(for: Self.account()), [.home, .files, .search, .history, .account])
    XCTAssertEqual(
      TVTab.tabs(for: Self.account(historyEnabled: false)), [.home, .files, .search, .account])
  }

  func testHidingHomeDropsItsTabAndMovesToFiles() {
    XCTAssertEqual(
      TVTab.tabs(for: Self.account(), showsHome: false), [.files, .search, .history, .account])
    var navigation = TVShellNavigation(selection: .home)
    navigation.reconcile(account: Self.account(), showsHome: false)
    XCTAssertEqual(navigation.selection, .files)
    navigation.selection = .account
    navigation.reconcile(account: Self.account(), showsHome: false)
    XCTAssertEqual(navigation.selection, .account)
  }

  @MainActor func testShowHomeIsKeptPerAccountAndClearedOnSignOut() throws {
    let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
    defer { defaults.removePersistentDomain(forName: #function) }
    let preference = PutioShowHomePreference(defaults: defaults, accountID: 1001)
    XCTAssertTrue(preference.isShown)
    preference.set(false)
    XCTAssertFalse(PutioShowHomePreference(defaults: defaults, accountID: 1001).isShown)
    XCTAssertTrue(PutioShowHomePreference(defaults: defaults, accountID: 1002).isShown)
    PutioShowHomePreference.clear(defaults: defaults, accountID: 1001)
    XCTAssertTrue(PutioShowHomePreference(defaults: defaults, accountID: 1001).isShown)
  }

  func testAccountRowsFollowTheSettingsTheyDependOn() {
    XCTAssertEqual(
      TVAccountSection.library.rows(for: Self.account()),
      [.manageTrash, .trash, .defaultSort, .history, .showHome])
    XCTAssertEqual(
      TVAccountSection.library.rows(for: Self.account(trashEnabled: false)),
      [.trash, .defaultSort, .history, .showHome])
    XCTAssertEqual(TVAccountSection.playback.rows(for: Self.account()), [.resume, .proxy])
    XCTAssertEqual(
      TVAccountSection.playback.rows(for: Self.account(), offersAutoplay: true),
      [.resume, .autoplay, .proxy])
    XCTAssertEqual(
      TVAccountSection.subtitles.rows(for: Self.account()), [.showSubtitles, .subtitleSelection])
    XCTAssertEqual(
      TVAccountSection.subtitles.rows(for: Self.account(hideSubtitles: true)), [.showSubtitles])
    XCTAssertEqual(TVAccountSection.account.rows(for: Self.account()), [.manageAccount, .signOut])
  }

  func testTVOffersNoPlaybackTypeOrBufferSetting() {
    let titles = TVAccountSection.allCases.flatMap {
      $0.rows(for: Self.account(), offersAutoplay: true)
    }.map(\.title)
    XCTAssertFalse(
      titles.contains { $0.localizedCaseInsensitiveContains("type") },
      "playback type belongs to the system player on tvOS: \(titles)")
    XCTAssertFalse(titles.contains { $0.localizedCaseInsensitiveContains("buffer") })
  }

  /// Rows show and send the account's own semantics: "Show subtitles" is
  /// the inverse of `hide_subtitles`, "Pick matching subtitles" the inverse
  /// of `dont_autoselect_subtitles`, and turning off trash, history, or
  /// resume is confirmed.
  func testRowValuesAndChangesUseTheSharedSettings() {
    let account = Self.account(hideSubtitles: true, dontAutoSelectSubtitles: true)
    XCTAssertEqual(TVAccountRow.showSubtitles.isOn(in: account), false)
    XCTAssertEqual(TVAccountRow.subtitleSelection.isOn(in: account), false)
    XCTAssertEqual(TVAccountRow.resume.isOn(in: account), true)
    XCTAssertEqual(TVAccountRow.trash.isOn(in: account), true)
    XCTAssertEqual(TVAccountRow.showHome.isOn(in: account, showsHome: false), false)
    XCTAssertEqual(TVAccountRow.autoplay.isOn(in: account, autoplay: true), true)
    XCTAssertNil(TVAccountRow.proxy.isOn(in: account))
    XCTAssertNil(TVAccountRow.defaultSort.isOn(in: account))

    XCTAssertEqual(TVAccountRow.showSubtitles.change(to: true), .save(.showSubtitles(true)))
    XCTAssertEqual(
      TVAccountRow.subtitleSelection.change(to: false), .save(.dontAutoSelectSubtitles(true)))
    XCTAssertEqual(TVAccountRow.trash.change(to: true), .save(.trash(true)))
    XCTAssertEqual(TVAccountRow.trash.change(to: false), .confirm(.trashOff))
    XCTAssertEqual(TVAccountRow.history.change(to: false), .confirm(.historyOff))
    XCTAssertEqual(TVAccountRow.resume.change(to: true), .save(.resumePlayback(true)))
    XCTAssertEqual(TVAccountRow.resume.change(to: false), .confirm(.resumeOff))
    XCTAssertEqual(TVAccountRow.showHome.change(to: false), .showHome(false))
    XCTAssertEqual(TVAccountRow.autoplay.change(to: true), .autoplay(true))
    XCTAssertNil(TVAccountRow.signOut.change(to: false))
  }

  private static let file = PutioFileItem(
    id: PutioFileID(rawValue: 411), parentID: .root, name: "Nested Movie.mkv", kind: .video,
    sizeBytes: 1, createdAt: .distantPast, updatedAt: .distantPast, resumePositionSeconds: 0)

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
