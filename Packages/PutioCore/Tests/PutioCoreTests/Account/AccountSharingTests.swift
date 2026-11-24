import Foundation
import Observation
import XCTest

@testable import PutioCore

@MainActor
final class ProxyChooserModelTests: XCTestCase {
  private let routes = [
    PutioPlaybackRoute(name: "default", description: "Amsterdam (Direct)"),
    PutioPlaybackRoute(name: "cdn77", description: "cdn77 (Automatic)"),
    PutioPlaybackRoute(name: "London", description: "London"),
  ]

  func testDirectLeadsEveryChoiceAndTheDefaultRouteIsNeverListedTwice() async {
    let (model, _) = makeModel(route: "cdn77", routes: routes)
    await model.loadIfNeeded()

    XCTAssertEqual(model.choices?.names, ["default", "cdn77", "London"])
    XCTAssertEqual(PutioProxyChoices.title(for: "default"), "Direct")
    XCTAssertEqual(PutioProxyChoices.title(for: ""), "Direct")
    XCTAssertEqual(model.choices?.description(for: "cdn77"), "cdn77 (Automatic)")
    XCTAssertNil(model.choices?.description(for: "London"))
    XCTAssertEqual(model.selection, "cdn77")
  }

  func testAnEmptyAccountRouteReadsAsDirect() {
    let (model, _) = makeModel(route: "", routes: routes)
    XCTAssertEqual(model.currentRoute, "default")
  }

  func testAFailedListingOffersARetryThatLoadsTheRoutes() async {
    var calls = 0
    let (model, _) = makeModel(
      route: "default",
      listRoutes: {
        calls += 1
        if calls == 1 { throw PutioRuntimeError.transient }
        return self.routes
      })
    await model.loadIfNeeded()
    XCTAssertNotNil(model.loadFailure)
    XCTAssertEqual(model.failure, model.loadFailure)
    XCTAssertNil(model.choices)

    await model.retry()
    XCTAssertNil(model.loadFailure)
    XCTAssertEqual(model.choices?.names.count, 3)
  }

  func testARefusedRouteIsUnavailableAndKeepsTheAccountRoute() async {
    let (model, session) = makeModel(
      route: "default", routes: routes,
      save: { _ in
        throw PutioPlaybackRouteUnavailable()
      })
    await model.loadIfNeeded()

    let outcome = await model.select("cdn77")

    XCTAssertEqual(outcome, .unavailable)
    XCTAssertEqual(session.account?.routeName, "default")
    XCTAssertEqual(model.selection, "default")
    XCTAssertFalse(model.isRequestConfirmed)
  }

  func testChoosingTheCurrentRouteSavesNothing() async {
    var saves = 0
    let (model, _) = makeModel(
      route: "cdn77", routes: routes,
      save: { _ in
        saves += 1
        return PutioAccountPreferencesMutationResult(accountRefreshed: true)
      })
    await model.loadIfNeeded()

    let outcome = await model.select("cdn77")
    XCTAssertEqual(outcome, .skipped)
    XCTAssertEqual(saves, 0)
  }

  /// A save whose account reload fails leaves the account stale; the chosen
  /// route is confirmed only after the retry refreshes it.
  func testTheRequestIsConfirmedOnlyOnceTheAccountShowsItAndIsFresh() async {
    var fixture: ProxySessionFixture?
    let (model, session) = makeModel(
      route: "default", routes: routes,
      save: { mutation in
        if case .route(let name) = mutation { fixture?.account = Self.account(route: name) }
        fixture?.isStale = true
        return PutioAccountPreferencesMutationResult(accountRefreshed: false)
      })
    fixture = session
    session.onRefresh = {
      session.isStale = false
      return true
    }
    await model.loadIfNeeded()

    let outcome = await model.select("London")
    XCTAssertEqual(outcome, .savedUnconfirmed)
    XCTAssertEqual(model.requestedRoute, "London")
    XCTAssertFalse(model.isRequestConfirmed)

    await model.retry()
    XCTAssertTrue(model.isRequestConfirmed)
  }

  private func makeModel(
    route: String,
    routes: [PutioPlaybackRoute] = [],
    listRoutes: (@MainActor @Sendable () async throws -> [PutioPlaybackRoute])? = nil,
    save: (
      @MainActor @Sendable (PutioAccountPreferenceMutation) async throws ->
        PutioAccountPreferencesMutationResult
    )? = nil
  ) -> (PutioProxyChooserModel, ProxySessionFixture) {
    let session = ProxySessionFixture(account: Self.account(route: route))
    let save = save ?? { _ in PutioAccountPreferencesMutationResult(accountRefreshed: true) }
    let preferences = PutioAccountPreferencesModel(
      actions: PutioAccountPreferenceActions(
        save: save, refresh: { await session.onRefresh() }, account: { session.account },
        accountRevision: { 0 }, isStale: { session.isStale }, isUpdating: { false }))
    let model = PutioProxyChooserModel(
      actions: PutioProxyChooserActions(listRoutes: listRoutes ?? { routes }),
      preferences: preferences)
    return (model, session)
  }

  fileprivate static func account(route: String) -> PutioAccountSnapshot {
    PutioAccountSnapshot(
      id: 10, username: "fixture", email: "fixture@example.invalid", suggestNextVideo: true,
      rememberVideoTime: true, defaultSort: .nameAscending, historyEnabled: true,
      trashEnabled: true, storage: .init(availableBytes: 100, totalBytes: 200, usedBytes: 100),
      routeName: route)
  }
}

@MainActor
@Observable
private final class ProxySessionFixture {
  var account: PutioAccountSnapshot?
  var isStale = false
  @ObservationIgnored var onRefresh: @MainActor () async -> Bool = { true }

  init(account: PutioAccountSnapshot) {
    self.account = account
  }
}

@MainActor
final class AccountPreferencesStatusTests: XCTestCase {
  func testAStaleAccountSaysSoAndOffersARefresh() async {
    var stale = true
    let model = PutioAccountPreferencesModel(
      actions: PutioAccountPreferenceActions(
        save: { _ in PutioAccountPreferencesMutationResult(accountRefreshed: true) },
        refresh: {
          stale = false
          return true
        },
        account: { ProxyChooserModelTests.account(route: "default") }, accountRevision: { 0 },
        isStale: { stale }, isUpdating: { false }))

    XCTAssertEqual(
      model.statusMessage, "Account settings could not be confirmed. Refresh to continue.")
    XCTAssertEqual(model.retryTitle, "Refresh account")

    await model.retry()
    XCTAssertNil(model.statusMessage)
  }

  func testAFailedSaveOffersToTryTheSameSaveAgain() async {
    var saves: [PutioAccountPreferenceMutation] = []
    let model = PutioAccountPreferencesModel(
      actions: PutioAccountPreferenceActions(
        save: { mutation in
          saves.append(mutation)
          if saves.count == 1 { throw PutioRuntimeError.transient }
          return PutioAccountPreferencesMutationResult(accountRefreshed: true)
        },
        refresh: { true },
        account: { ProxyChooserModelTests.account(route: "default") }, accountRevision: { 0 },
        isStale: { false }, isUpdating: { false }))

    await model.save(.history(false))
    XCTAssertEqual(model.statusMessage, "Check your connection and try again.")
    XCTAssertEqual(model.retryTitle, "Try again")

    await model.retry()
    XCTAssertEqual(saves, [.history(false), .history(false)])
    XCTAssertNil(model.statusMessage)
  }
}

final class SignedOutNoticeTests: XCTestCase {
  func testAFreshOrChosenSignOutHasNoNotice() {
    XCTAssertNil(PutioSignedOutNotice(reason: nil, device: .appleTV))
    XCTAssertNil(PutioSignedOutNotice(reason: .userSignedOut, device: .iPhone))
  }

  func testEachRestoreFailureCauseHasItsOwnCopyAndWaysOut() throws {
    let check = try XCTUnwrap(
      PutioSignedOutNotice(
        reason: .restoreFailed(.sessionCheck, message: "raw"), device: .appleTV))
    XCTAssertEqual(check.title, "Can’t connect to put.io")
    XCTAssertEqual(check.restoreActions?.retryTitle, "Try now")
    XCTAssertEqual(check.restoreActions?.discardTitle, "Sign in again")

    let storage = try XCTUnwrap(
      PutioSignedOutNotice(
        reason: .restoreFailed(.secureStorage, message: "raw"), device: .appleTV))
    XCTAssertEqual(storage.title, "Secure storage is unavailable")
    XCTAssertTrue(storage.message.contains("this Apple TV"))
    XCTAssertEqual(storage.restoreActions?.discardTitle, "Reset and sign in")

    XCTAssertNotEqual(check.message, storage.message)
    XCTAssertFalse(check.message.contains("raw"))
  }

  func testPhonesKeepTheirSessionCheckCopy() {
    let notice = PutioSignedOutNotice(kind: .restoreFailed(.sessionCheck), device: .iPad)
    XCTAssertEqual(notice.title, "Couldn’t check your session")
    XCTAssertEqual(notice.restoreActions?.retryTitle, "Try again")
  }

  func testAnExpiredSessionAsksToSignInAgainWithoutRestoreActions() {
    let notice = PutioSignedOutNotice(reason: .sessionExpired, device: .appleTV)
    XCTAssertEqual(notice?.title, "Session expired")
    XCTAssertEqual(notice?.message, "Please sign in again")
    XCTAssertNil(notice?.restoreActions)
  }
}

final class AccountConfirmationTests: XCTestCase {
  func testSignOutNamesTheDeviceThatSignsOut() {
    let tv = PutioAccountConfirmations.signOut(device: .appleTV)
    XCTAssertEqual(tv.title, "Sign out?")
    XCTAssertEqual(tv.message, "You’ll need a new code to sign in on this Apple TV again.")
    XCTAssertEqual(tv.confirmTitle, "Sign out")

    let pad = PutioAccountConfirmations.signOut(device: .iPad)
    XCTAssertEqual(pad.title, "Sign out of put.io?")
    XCTAssertTrue(pad.message.contains("this iPad"))
  }

  func testTheDownloadSizeMovesIntoTheMessageAtLargeTextSizes() {
    let locale = Locale(identifier: "en_US")
    let compact = PutioSignOutPrompt(device: .iPhone, sizeInMessage: false)
    XCTAssertEqual(
      compact.message(downloadedBytes: 2_000_000_000, locale: locale), compact.message)
    XCTAssertTrue(
      compact.removeDownloadsTitle(downloadedBytes: 2_000_000_000, locale: locale).contains("("))

    let large = PutioSignOutPrompt(device: .iPhone, sizeInMessage: true)
    XCTAssertTrue(
      large.message(downloadedBytes: 2_000_000_000, locale: locale).hasPrefix("Downloads use"))
    XCTAssertEqual(
      large.removeDownloadsTitle(downloadedBytes: 2_000_000_000, locale: locale),
      "Sign out and remove downloads")
  }

  func testTurningOffResumeWarnsItErasesEveryPosition() {
    XCTAssertEqual(PutioAccountConfirmations.resumeOff.title, "Turn off resume?")
    XCTAssertEqual(
      PutioAccountConfirmations.resumeOff.message,
      "This erases every saved playback position on your account, on all devices.")
    XCTAssertEqual(PutioAccountConfirmations.trashOff.confirmTitle, "Turn off")
    XCTAssertEqual(PutioAccountConfirmations.historyOff.title, "Turn off history?")
  }
}

final class StorageWarningTests: XCTestCase {
  func testAlmostFullStartsAtTheThresholdAndEndsWhereFullBegins() {
    func storage(used: Int64) -> PutioAccountSnapshot.Storage {
      .init(availableBytes: 1_000 - used, totalBytes: 1_000, usedBytes: used)
    }
    XCTAssertFalse(storage(used: 949).isAlmostFull)
    XCTAssertTrue(storage(used: 950).isAlmostFull)
    XCTAssertTrue(storage(used: 999).isAlmostFull)
    XCTAssertFalse(storage(used: 1_000).isAlmostFull)
    XCTAssertTrue(storage(used: 1_000).isFull)
    XCTAssertFalse(
      PutioAccountSnapshot.Storage(availableBytes: 0, totalBytes: 0, usedBytes: 0).isAlmostFull)
    XCTAssertEqual(
      PutioAccountSnapshot.Storage.almostFullMessage,
      "Almost full. Empty trash or delete files to make room.")
  }
}

@MainActor
final class ShowHomePreferenceTests: XCTestCase {
  func testHomeShowsUntilTurnedOffAndTheChoiceIsPerAccount() throws {
    let suite = "ShowHomePreferenceTests.\(name)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let first = PutioShowHomePreference(defaults: defaults, accountID: 1)
    XCTAssertTrue(first.isShown)
    first.set(false)
    XCTAssertFalse(PutioShowHomePreference(defaults: defaults, accountID: 1).isShown)
    XCTAssertTrue(PutioShowHomePreference(defaults: defaults, accountID: 2).isShown)

    PutioShowHomePreference.clear(defaults: defaults, accountID: 1)
    XCTAssertTrue(PutioShowHomePreference(defaults: defaults, accountID: 1).isShown)
  }
}

@MainActor
final class AutoplayRuleTests: XCTestCase {
  func testAutoplayIsOfferedOnlyOnceLoadedAndOnlyWhenPutioSuggestsNextVideos() async {
    let model = PutioAppConfigModel(
      actions: PutioAppConfigActions(
        load: { PutioAppConfig(autoplayNextVideo: true) }, save: { _ in }))
    XCTAssertFalse(model.offersAutoplay(suggestsNextVideo: true))
    await model.loadIfNeeded()
    XCTAssertTrue(model.offersAutoplay(suggestsNextVideo: true))
    XCTAssertFalse(model.offersAutoplay(suggestsNextVideo: false))
  }
}
