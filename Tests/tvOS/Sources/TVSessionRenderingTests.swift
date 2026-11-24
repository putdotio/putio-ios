import PutioCore
import SwiftUI
import UIKit
import XCTest

@testable import PutioTV

final class TVSessionRenderingTests: XCTestCase {
  private let viewport = CGSize(width: 1920, height: 1080)

  @MainActor
  func testSignInCodeMatchesBaseline() throws {
    let image = try assertRenderingSnapshot(
      name: "tv-sign-in-code",
      view: TVSignInScreen(
        phase: .awaitingApproval(PutioDeviceCode(code: "FXWNPH", qrCode: Self.qrCode("FXWNPH"))),
        requestCode: {}, retryRestore: {}),
      size: viewport
    )
    XCTAssertEqual(image.size, viewport)
  }

  @MainActor
  func testSignInExpiredMatchesBaseline() throws {
    _ = try assertRenderingSnapshot(
      name: "tv-sign-in-expired",
      view: TVSignInScreen(
        phase: .expired(PutioDeviceCode(code: "FXWNPH", qrCode: Self.qrCode("FXWNPH"))),
        requestCode: {}, retryRestore: {}),
      size: viewport
    )
  }

  @MainActor
  func testSignInOfflineMatchesBaseline() throws {
    _ = try assertRenderingSnapshot(
      name: "tv-sign-in-offline",
      view: TVSignInScreen(
        phase: .awaitingApproval(
          PutioDeviceCode(code: "FXWNPH", qrCode: Self.qrCode("FXWNPH"), isOffline: true)),
        requestCode: {}, retryRestore: {}),
      size: viewport
    )
  }

  @MainActor
  func testSignInAfterAnExpiredSessionMatchesBaseline() throws {
    _ = try assertRenderingSnapshot(
      name: "tv-sign-in-session-expired",
      view: TVSignInScreen(
        phase: .awaitingApproval(PutioDeviceCode(code: "FXWNPH", qrCode: Self.qrCode("FXWNPH"))),
        sessionExpired: PutioSignedOutNotice(kind: .sessionExpired, device: .appleTV),
        requestCode: {}, retryRestore: {}),
      size: viewport
    )
  }

  @MainActor
  func testSessionCheckFailureMatchesBaseline() throws {
    _ = try assertRenderingSnapshot(
      name: "tv-session-check-failed",
      view: TVSignInScreen(
        phase: .failed(PutioSignedOutNotice(kind: .restoreFailed(.sessionCheck), device: .appleTV)),
        requestCode: {}, retryRestore: {}),
      size: viewport
    )
  }

  @MainActor
  func testCheckingSessionMatchesBaseline() throws {
    _ = try assertRenderingSnapshot(
      name: "tv-session-checking", view: TVSessionCheckingView(), size: viewport)
  }

  /// rd-tvos-acc-01: the profile and Library, with Manage your trash
  /// explained beside them.
  @MainActor
  func testAccountMatchesBaseline() throws {
    _ = try assertRenderingSnapshot(name: "tv-account", view: accountScreen(), size: viewport)
  }

  /// Hidden subtitles and disabled Trash drop their dependent rows; a stale
  /// account offers the refresh recovery.
  @MainActor
  func testAccountWithDependentRowsHiddenAndStaleSettingsMatchesBaseline() throws {
    _ = try assertRenderingSnapshot(
      name: "tv-account-stale",
      view: accountScreen(
        account: Self.account(hideSubtitles: true, trashEnabled: false),
        status: TVAccountStatus(
          message:
            "Saved, but the latest account settings could not be loaded. Refresh to continue.",
          retryTitle: "Refresh account", canSave: false)),
      size: viewport
    )
  }

  /// Each row's panel, as the boards draw it with that row focused.
  @MainActor
  func testAccountPanelsMatchBaselines() throws {
    let panels: [(String, TVAccountRow)] = [
      ("tv-account-trash-toggle", .trash),
      ("tv-account-resume", .resume),
      ("tv-account-subtitles", .subtitleSelection),
      ("tv-account-app-info", .appInfo),
      ("tv-account-manage", .manageAccount),
      ("tv-account-sign-out", .signOut),
      ("tv-account-show-home", .showHome),
    ]
    for (name, row) in panels {
      _ = try assertRenderingSnapshot(
        name: name, view: accountScreen(initialRow: row, showsHome: row != .showHome),
        size: viewport)
    }
  }

  /// rd-tvos-acc-13: almost full turns the meter red and warns under it.
  @MainActor
  func testAccountAlmostFullMatchesBaseline() throws {
    _ = try assertRenderingSnapshot(
      name: "tv-account-almost-full",
      view: accountScreen(account: Self.account(usedBytes: 1_077_521_395_220)),
      size: viewport)
  }

  /// rd-tvos-acc-15: settings that never loaded replace the list.
  @MainActor
  func testAccountLoadFailureMatchesBaseline() throws {
    _ = try assertRenderingSnapshot(
      name: "tv-account-load-failure", view: TVAccountLoadFailure {}, size: viewport)
  }

  /// rd-tvos-acc-08: the privacy controls with the policy beside them.
  @MainActor
  func testPrivacyControlsMatchBaseline() throws {
    _ = try assertRenderingSnapshot(
      name: "tv-privacy-controls",
      view: NavigationStack { TVPrivacyControlsScreen(account: Self.account) },
      size: viewport)
  }

  /// A privacy change whose account refresh failed says so and offers a
  /// refresh, with both controls held until it succeeds.
  @MainActor
  func testPrivacyControlsWithStaleSettingsMatchBaseline() throws {
    _ = try assertRenderingSnapshot(
      name: "tv-privacy-controls-stale",
      view: NavigationStack {
        TVPrivacyControlsScreen(
          account: Self.account,
          status: TVAccountStatus(
            message:
              "Saved, but the latest account settings could not be loaded. Refresh to continue.",
            retryTitle: "Refresh account", canSave: false))
      },
      size: viewport)
  }

  @MainActor
  private func accountScreen(
    account: PutioAccountSnapshot = TVSessionRenderingTests.account,
    status: TVAccountStatus = .idle, initialRow: TVAccountRow? = nil, showsHome: Bool = true
  ) -> some View {
    NavigationStack {
      TVAccountScreen(
        account: account, appInfo: Self.appInfo, status: status,
        locale: Locale(identifier: "en_US"), showsHome: showsHome, autoplay: false,
        initialRow: initialRow
      ) {}
    }
  }

  @MainActor
  func testHistoryMatchesBaseline() async throws {
    let runtime = try await Self.seededRuntime()
    let model = PutioHistoryModel(actions: PutioHistoryActions(runtime: runtime))
    await model.refresh()
    // The fixture's first continuation fails once; the retry ends the list.
    await model.loadMore()
    await model.loadMore()
    XCTAssertNil(model.page?.nextBefore)

    _ = try assertRenderingSnapshot(
      name: "tv-history",
      view: TVHistoryView(model: model, now: Self.fixtureNoon, locale: Self.locale) { _ in },
      size: viewport
    )
  }

  @MainActor
  func testTrashMatchesBaseline() async throws {
    let runtime = try await Self.seededRuntime()
    let model = PutioTrashModel(runtime: runtime, reconciliation: PutioTrashReconciliation())
    await model.refresh()
    await model.loadMore()
    XCTAssertEqual(model.page?.items.count, 3)
    XCTAssertNil(model.page?.nextCursor)

    _ = try assertRenderingSnapshot(
      name: "tv-trash",
      view: TVTrashView(
        model: model, now: Self.trashNow, locale: Self.locale, loadsOnAppear: false),
      size: viewport
    )
  }

  /// The seeded root with both pages loaded: a folder with its chevron, the
  /// watched video's eye, and each type icon under the persisted sort header.
  @MainActor
  func testFilesMatchesBaseline() async throws {
    HarnessSeededAPI.resetPlaybackPositions()
    let runtime = try await Self.seededRuntime()
    let model = PutioFolderModel(
      folderID: .root,
      load: { try await runtime.listFiles(parentID: $0) },
      continueLoad: { try await runtime.continueFiles(cursor: $0) },
      actions: PutioFileActions(runtime: runtime))
    await model.loadIfNeeded()
    await model.loadMore()
    guard case .loaded(let contents) = model.state else {
      return XCTFail("expected the root to load, got \(model.state)")
    }
    XCTAssertNil(contents.nextCursor)

    _ = try assertRenderingSnapshot(
      name: "tv-files",
      view: TVFolderView(
        route: .root, model: model, account: Self.account, now: Self.trashNow,
        locale: Self.locale, loadsOnAppear: false
      ) { _ in },
      size: viewport
    )
  }

  @MainActor
  func testUnsupportedFileMatchesBaseline() throws {
    _ = try assertRenderingSnapshot(
      name: "tv-file-unsupported",
      view: TVFileScreen(
        item: PutioFileItem(
          id: PutioFileID(rawValue: 407), parentID: .root, name: "Harness Bundle.zip",
          kind: .other("ARCHIVE"), sizeBytes: 4_096, createdAt: Self.trashNow,
          updatedAt: Self.trashNow, resumePositionSeconds: 0)),
      size: viewport
    )
  }

  /// Restores never refresh storage on their own, and one can commit after
  /// Trash is gone; the account's trash size and the restored file's folder
  /// must still follow it.
  @MainActor
  func testRestoreRefreshesTheAccountTrashSizeAndTheRestoredFolder() async throws {
    let runtime = try await Self.seededRuntime()
    XCTAssertEqual(Self.trashSize(runtime), 3 * 1_073_741_824)
    let refreshRequests = PutioFolderRefreshRequests()
    let model = TVTrashView.model(
      runtime: runtime, reconciliation: PutioTrashReconciliation(),
      refreshRequests: refreshRequests)
    await model.refresh()
    let item = try XCTUnwrap(model.page?.items.first)
    await model.restore(item)
    let deadline = Date().addingTimeInterval(10)
    while Self.trashSize(runtime) != 2 * 1_073_741_824 || refreshRequests.revision == 0,
      Date() < deadline
    {
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertEqual(Self.trashSize(runtime), 2 * 1_073_741_824)
    XCTAssertGreaterThan(refreshRequests.revision, 0, "the restored file's folder never refreshed")
  }

  /// A failed refresh on returning to Account must say so and offer the
  /// retry, rather than keep showing the old trash size silently.
  @MainActor
  func testAFailedRefreshOnReturningToAccountOffersRecovery() async throws {
    let runtime = try await Self.seededRuntime()
    let model = PutioAccountPreferencesModel(actions: .init(runtime: runtime))
    HarnessSeededAPI.failNextAccountRefresh()
    await TVAccountView.refreshAfterReturning(model: model)
    XCTAssertEqual(model.failure, "Could not refresh account settings. Try again.")
    XCTAssertEqual(TVAccountStatus(model: model).message, model.failure)
    XCTAssertEqual(TVAccountStatus(model: model).retryTitle, "Refresh account")
  }

  @MainActor
  private static func trashSize(_ runtime: PutioRuntime) -> Int64? {
    guard case .signedIn(let account) = runtime.session.state else { return nil }
    return account.trashSizeBytes
  }

  func testSignInPhaseFollowsTheSessionStore() {
    XCTAssertEqual(
      TVSignInPhase(state: .signedOut(nil), deviceCodeSignIn: nil), .fetchingCode)
    XCTAssertEqual(
      TVSignInPhase(
        state: .authenticating,
        deviceCodeSignIn: .awaitingApproval(PutioDeviceCode(code: "AB12C"))),
      .awaitingApproval(PutioDeviceCode(code: "AB12C")))
    XCTAssertEqual(
      TVSignInPhase(
        state: .authenticating, deviceCodeSignIn: .expired(PutioDeviceCode(code: "AB12C"))),
      .expired(PutioDeviceCode(code: "AB12C")))
    XCTAssertEqual(
      TVSignInPhase(state: .signedOut(.authenticationFailed("nope")), deviceCodeSignIn: nil),
      .failed(PutioSignedOutNotice(kind: .signInFailed, device: .appleTV)))
    XCTAssertEqual(
      TVSignInPhase(
        state: .signedOut(.restoreFailed(.sessionCheck, message: "offline")), deviceCodeSignIn: nil),
      .failed(PutioSignedOutNotice(kind: .restoreFailed(.sessionCheck), device: .appleTV)))
    XCTAssertEqual(
      TVSignInPhase(state: .signedOut(.sessionExpired), deviceCodeSignIn: nil), .fetchingCode)
  }

  /// A signed-in runtime against the seeded API, with its fixture counters
  /// reset so each test sees the first responses.
  @MainActor
  private static func seededRuntime() async throws -> PutioRuntime {
    HarnessSeededAPI.resetFileActions()
    let runtime = PutioRuntimeFactory.make(scenario: .signedIn)
    await runtime.session.restore()
    guard case .signedIn = runtime.session.state else {
      XCTFail("the seeded session did not sign in: \(runtime.session.state)")
      throw CancellationError()
    }
    return runtime
  }

  /// Seeded History events land at the start of today; noon keeps their
  /// relative times fixed.
  private static var fixtureNoon: Date {
    Calendar.current.startOfDay(for: .now).addingTimeInterval(12 * 60 * 60)
  }

  private static let locale = Locale(identifier: "en_US")

  private static func qrCode(_ code: String) -> Data? {
    PutioQRCode.image(for: "https://app.put.io/link?code=\(code)").flatMap {
      UIImage(cgImage: $0).pngData()
    }
  }

  /// An image that does not decode leaves the code and manual entry alone.
  @MainActor
  func testSignInWithAnUnreadableQRImageMatchesTheCodeOnlyBaseline() throws {
    _ = try assertRenderingSnapshot(
      name: "tv-sign-in-code-without-qr",
      view: TVSignInScreen(
        phase: .awaitingApproval(PutioDeviceCode(code: "FXWNPH", qrCode: Data("x".utf8))),
        requestCode: {}, retryRestore: {}),
      size: viewport
    )
  }

  private static let trashNow = ISO8601DateFormatter().date(from: "2026-09-10T12:00:00Z")!

  private static let appInfo = PutioAppInfo(
    version: "1.0", build: "1", channel: .appStore, device: "Apple TV", systemName: "tvOS",
    systemVersion: "27.0")

  private static let account = account()

  private static func account(
    hideSubtitles: Bool = false, trashEnabled: Bool = true, usedBytes: Int64 = 30_617_800_704
  ) -> PutioAccountSnapshot {
    PutioAccountSnapshot(
      id: 1001,
      username: "moviebuff",
      email: "moviebuff@example.com",
      suggestNextVideo: true,
      rememberVideoTime: true,
      defaultSort: nil,
      historyEnabled: true,
      trashEnabled: trashEnabled,
      storage: PutioAccountSnapshot.Storage(
        availableBytes: 1_099_511_627_776 - usedBytes,
        totalBytes: 1_099_511_627_776,
        usedBytes: usedBytes
      ),
      routeName: "edge",
      hideSubtitles: hideSubtitles,
      dontAutoSelectSubtitles: false,
      twoFactorEnabled: false,
      trashSizeBytes: 3_221_225_472
    )
  }
}
