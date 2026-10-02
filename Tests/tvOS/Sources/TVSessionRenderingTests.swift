import PutioCore
import SwiftUI
import XCTest

@testable import PutioTV

final class TVSessionRenderingTests: XCTestCase {
  private let viewport = CGSize(width: 1920, height: 1080)

  @MainActor
  func testSignInCodeMatchesBaseline() throws {
    let image = try assertRenderingSnapshot(
      name: "tv-sign-in-code",
      view: TVSignInScreen(
        phase: .awaitingApproval(code: "TVOK2"), requestCode: {}, retryRestore: {}),
      size: viewport
    )
    XCTAssertEqual(image.size, viewport)
  }

  @MainActor
  func testSignInExpiredMatchesBaseline() throws {
    _ = try assertRenderingSnapshot(
      name: "tv-sign-in-expired",
      view: TVSignInScreen(phase: .expired(code: "TVXP1"), requestCode: {}, retryRestore: {}),
      size: viewport
    )
  }

  @MainActor
  func testHomeMatchesBaseline() throws {
    _ = try assertRenderingSnapshot(
      name: "tv-home",
      view: NavigationStack { TVHomeScreen(entries: TVHomeEntry.entries(for: Self.account)) },
      size: viewport
    )
  }

  @MainActor
  func testAccountMatchesBaseline() throws {
    _ = try assertRenderingSnapshot(
      name: "tv-account",
      view: NavigationStack {
        TVAccountScreen(
          account: Self.account, appInfo: Self.appInfo, locale: Locale(identifier: "en_US")
        ) {}
      },
      size: viewport
    )
  }

  /// Hidden subtitles and disabled Trash drop their dependent rows; a stale
  /// account offers the refresh recovery.
  @MainActor
  func testAccountWithDependentRowsHiddenAndStaleSettingsMatchesBaseline() throws {
    _ = try assertRenderingSnapshot(
      name: "tv-account-stale",
      view: NavigationStack {
        TVAccountScreen(
          account: Self.account(hideSubtitles: true, trashEnabled: false),
          appInfo: Self.appInfo,
          status: TVAccountStatus(
            failure:
              "Saved, but the latest account settings could not be loaded. Refresh to continue.",
            isStale: true, canSave: false),
          locale: Locale(identifier: "en_US")
        ) {}
      },
      size: viewport
    )
  }

  @MainActor
  func testProxyChooserMatchesBaseline() throws {
    _ = try assertRenderingSnapshot(
      name: "tv-proxy-chooser",
      view: TVProxyChooserScreen(
        currentRoute: "edge",
        routes: [
          PutioPlaybackRoute(name: "default", description: "Amsterdam (Direct)"),
          PutioPlaybackRoute(name: "edge", description: "Alternate proxy"),
          PutioPlaybackRoute(name: "london", description: ""),
        ]),
      size: viewport
    )
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

  func testSignInPhaseFollowsTheSessionStore() {
    XCTAssertEqual(
      TVSignInPhase(state: .signedOut(nil), deviceCodeSignIn: nil), .fetchingCode)
    XCTAssertEqual(
      TVSignInPhase(state: .authenticating, deviceCodeSignIn: .awaitingApproval(code: "AB12C")),
      .awaitingApproval(code: "AB12C"))
    XCTAssertEqual(
      TVSignInPhase(state: .authenticating, deviceCodeSignIn: .expired(code: "AB12C")),
      .expired(code: "AB12C"))
    XCTAssertEqual(
      TVSignInPhase(state: .signedOut(.authenticationFailed("nope")), deviceCodeSignIn: nil),
      .failed(message: "nope", canRetryRestore: false))
    XCTAssertEqual(
      TVSignInPhase(state: .signedOut(.restoreFailed("offline")), deviceCodeSignIn: nil),
      .failed(message: "offline", canRetryRestore: true))
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

  private static let trashNow = ISO8601DateFormatter().date(from: "2026-09-10T12:00:00Z")!

  private static let appInfo = TVAppInfo(
    app: "io.put.dev.tvos@1.0+1", device: "Living Room - Apple TV", system: "tvOS 27.0")

  private static let account = account()

  private static func account(
    hideSubtitles: Bool = false, trashEnabled: Bool = true
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
        availableBytes: 1_068_893_827_072,
        totalBytes: 1_099_511_627_776,
        usedBytes: 30_617_800_704
      ),
      routeName: "edge",
      hideSubtitles: hideSubtitles,
      dontAutoSelectSubtitles: false,
      twoFactorEnabled: false,
      trashSizeBytes: 3_221_225_472
    )
  }
}
