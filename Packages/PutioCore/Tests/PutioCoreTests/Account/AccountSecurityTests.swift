import Foundation
import XCTest

@testable import PutioCore

@MainActor
final class AccountSecurityTests: XCTestCase {
  func testRevokeFailureKeepsTheAppAndTheCurrentClientIsNeverRevoked() async {
    var revoked: [Int] = []
    let apps = [
      PutioAuthorizedApp(id: 3001, name: "This", isCurrentClient: true),
      PutioAuthorizedApp(id: 42, name: "TV", isCurrentClient: false),
    ]
    let model = PutioAuthorizedAppsModel(
      actions: PutioAccountSecurityActions(
        listApps: { apps },
        revokeApp: { id in
          revoked.append(id)
          if revoked.count == 1 { throw PutioRuntimeError.transient }
        }))
    await model.load()
    XCTAssertEqual(model.apps, apps)
    await model.revoke(id: 3001)
    XCTAssertEqual(revoked, [])
    await model.revoke(id: 42)
    XCTAssertEqual(model.apps, apps)
    XCTAssertEqual(model.revokeFailures, [42: "Check your connection and try again."])
    await model.revoke(id: 42)
    XCTAssertEqual(revoked, [42, 42])
    XCTAssertEqual(model.apps.map(\.id), [3001])
    XCTAssertEqual(model.revokeFailures, [:])
    XCTAssertFalse(model.canSignOutOthers, "the row stayed with only this app listed")
  }

  func testSignOutOthersRevokesEveryOtherAppOnceAndKeepsTheFailures() async {
    var revoked: [Int] = []
    var failing: Set<Int> = [43]
    let apps = [
      PutioAuthorizedApp(id: 3001, name: "This", isCurrentClient: true),
      PutioAuthorizedApp(id: 42, name: "TV", isCurrentClient: false),
      PutioAuthorizedApp(id: 43, name: "Android", isCurrentClient: false),
      PutioAuthorizedApp(id: 44, name: "Infuse", isCurrentClient: false),
    ]
    let model = PutioAuthorizedAppsModel(
      actions: PutioAccountSecurityActions(
        listApps: { apps },
        revokeApp: { id in
          revoked.append(id)
          if failing.contains(id) { throw PutioRuntimeError.transient }
        }))
    await model.load()
    XCTAssertTrue(model.canSignOutOthers)
    await model.signOutOthers()
    XCTAssertEqual(revoked, [42, 43, 44])
    XCTAssertEqual(model.apps.map(\.id), [3001, 43])
    XCTAssertEqual(Array(model.revokeFailures.keys), [43])
    XCTAssertTrue(model.canSignOutOthers, "a partial failure hid the row")
    XCTAssertFalse(model.isSigningOutOthers)
    failing = []
    await model.signOutOthers()
    XCTAssertEqual(revoked, [42, 43, 44, 43])
    XCTAssertEqual(model.apps.map(\.id), [3001])
    XCTAssertEqual(model.revokeFailures, [:])
    XCTAssertFalse(model.canSignOutOthers)
  }

  func testSwipeRevokeWaitsWhileSigningOutOthers() async throws {
    let gate = RequestGate()
    defer { gate.finish() }
    var revoked: [Int] = []
    let apps = [
      PutioAuthorizedApp(id: 3001, name: "This", isCurrentClient: true),
      PutioAuthorizedApp(id: 42, name: "TV", isCurrentClient: false),
      PutioAuthorizedApp(id: 43, name: "Android", isCurrentClient: false),
    ]
    let model = PutioAuthorizedAppsModel(
      actions: PutioAccountSecurityActions(
        listApps: { apps },
        revokeApp: { id in
          revoked.append(id)
          if id == 42 { await gate.wait() }
        }))
    await model.load()
    let signOut = Task { await model.signOutOthers() }
    try await gate.waitForRequest()
    XCTAssertTrue(model.isSigningOutOthers)
    XCTAssertEqual(model.revokingID, 42)
    await model.revoke(id: 43)
    XCTAssertEqual(revoked, [42], "a swipe revoke ran beside sign out of all other apps")
    gate.finish()
    await signOut.value
    XCTAssertEqual(revoked, [42, 43])
    XCTAssertFalse(model.isSigningOutOthers)
  }

  func testIconsLoadOnceOnlyForAppsThatHaveOne() async {
    var requested: [Int] = []
    let model = PutioAuthorizedAppsModel(
      actions: PutioAccountSecurityActions(appIcon: { id in
        requested.append(id)
        if id == 43 { throw PutioRuntimeError.notFound }
        return Data([UInt8(id)])
      }))
    let withIcon = PutioAuthorizedApp(id: 42, name: "TV", hasIcon: true, isCurrentClient: false)
    let broken = PutioAuthorizedApp(id: 43, name: "Android", hasIcon: true, isCurrentClient: false)
    let withoutIcon = PutioAuthorizedApp(id: 44, name: "Infuse", isCurrentClient: false)
    let first = await model.icon(for: withIcon)
    let second = await model.icon(for: withIcon)
    let missing = await model.icon(for: broken)
    let missingAgain = await model.icon(for: broken)
    let none = await model.icon(for: withoutIcon)
    XCTAssertEqual(first, Data([42]))
    XCTAssertEqual(second, Data([42]))
    XCTAssertNil(missing)
    XCTAssertNil(missingAgain)
    XCTAssertNil(none)
    XCTAssertEqual(requested, [42, 43], "an icon was requested twice")
  }

  func testSignOutOthersStopsWhenTheSessionEnds() async {
    var revoked: [Int] = []
    let apps = [
      PutioAuthorizedApp(id: 3001, name: "This", isCurrentClient: true),
      PutioAuthorizedApp(id: 42, name: "TV", isCurrentClient: false),
      PutioAuthorizedApp(id: 43, name: "Android", isCurrentClient: false),
    ]
    let model = PutioAuthorizedAppsModel(
      actions: PutioAccountSecurityActions(
        listApps: { apps },
        revokeApp: { id in
          revoked.append(id)
          throw PutioRuntimeError.sessionExpired
        }))
    await model.load()
    await model.signOutOthers()
    XCTAssertEqual(revoked, [42], "revokes kept going after the session ended")
    XCTAssertFalse(model.isSigningOutOthers)
  }

  func testReloadDropsARevokeFailureWhoseGrantIsGone() async {
    var apps = [PutioAuthorizedApp(id: 42, name: "TV", isCurrentClient: false)]
    let model = PutioAuthorizedAppsModel(
      actions: PutioAccountSecurityActions(
        listApps: { apps },
        revokeApp: { _ in
          apps = []
          throw PutioRuntimeError.transient
        }))
    await model.load()
    await model.revoke(id: 42)
    XCTAssertNotNil(model.revokeFailures[42])
    await model.load()
    XCTAssertTrue(model.apps.isEmpty)
    XCTAssertEqual(model.revokeFailures, [:])
  }

  func testRevokeOutlivesAListRequestThatStartedBeforeIt() async throws {
    let gate = RequestGate()
    defer { gate.finish() }
    var loads = 0
    let apps = [
      PutioAuthorizedApp(id: 42, name: "TV", isCurrentClient: false)
    ]
    let model = PutioAuthorizedAppsModel(
      actions: PutioAccountSecurityActions(
        listApps: {
          loads += 1
          if loads == 2 { await gate.wait() }
          return apps
        }))
    await model.load()
    let stale = Task { await model.load() }
    try await gate.waitForRequest()
    await model.revoke(id: 42)
    XCTAssertTrue(model.apps.isEmpty)
    gate.finish()
    await stale.value
    XCTAssertTrue(model.apps.isEmpty, "a stale list restored the revoked app")
  }

  func testAppsLoadFailureIsRetryableAndSessionEndingsStaySilent() async {
    var loads = 0
    let apps = [PutioAuthorizedApp(id: 42, name: "TV", isCurrentClient: false)]
    let model = PutioAuthorizedAppsModel(
      actions: PutioAccountSecurityActions(listApps: {
        loads += 1
        if loads == 1 || loads == 4 { throw PutioRuntimeError.transient }
        if loads == 2 { throw PutioRuntimeError.sessionExpired }
        return apps
      }))
    await model.load()
    guard case .failed = model.state else { return XCTFail("load failure was not shown") }
    await model.load()
    XCTAssertEqual(model.state, .loading, "a session ending produced an error state")
    await model.load()
    XCTAssertEqual(model.state, .loaded(apps))
    await model.load()
    XCTAssertEqual(model.state, .loaded(apps), "a failed refresh dropped the rows")
    XCTAssertNotNil(model.refreshFailure, "a failed refresh went unreported")
    await model.load()
    XCTAssertNil(model.refreshFailure)
  }

  func testLinkDeviceRejectionKeepsTheCodeAndSuccessIsAcknowledged() async {
    var submitted: [String] = []
    let model = PutioLinkDeviceModel(
      actions: PutioAccountSecurityActions(linkDevice: { code in
        submitted.append(code)
        guard code == "HARN42" else { throw PutioAccountSecurityError.invalidDeviceCode }
        return PutioAuthorizedApp(id: 77, name: "TV", isCurrentClient: false)
      }))
    XCTAssertFalse(model.canLink)
    model.code = "ZZZZZZ"
    await model.link()
    XCTAssertEqual(model.code, "ZZZZZZ", "a rejected code was cleared instead of kept for editing")
    XCTAssertEqual(
      model.failure,
      "That device code was not found. Check the code on the device and try again.")
    model.code = "ZZZZZ"
    model.codeEdited()
    XCTAssertNil(model.failure, "the failure stayed after the code was edited")
    model.code = " harn42\n"
    await model.link()
    XCTAssertEqual(model.linkedApp?.id, 77)
    XCTAssertNil(model.failure)
    XCTAssertEqual(submitted, ["ZZZZZZ", "HARN42"])
    model.acknowledgeLink()
    XCTAssertNil(model.linkedApp)
    XCTAssertEqual(model.code, "")
  }

  func testLinkDeviceNeedsExactlySixCharactersBeforeAnyRequest() async {
    var submitted: [String] = []
    let model = PutioLinkDeviceModel(
      actions: PutioAccountSecurityActions(linkDevice: { code in
        submitted.append(code)
        return PutioAuthorizedApp(id: 77, name: "TV", isCurrentClient: false)
      }))
    for code in ["HARN", " HARN4 ", "HARN421"] {
      model.code = code
      XCTAssertTrue(model.canLink, code)
      await model.link()
      XCTAssertEqual(model.failure, "Must be exactly 6 characters.", code)
      XCTAssertEqual(model.code, code, "a malformed code was cleared instead of corrected")
    }
    XCTAssertEqual(submitted, [])
    model.code = "harn42"
    await model.link()
    XCTAssertNil(model.failure)
    XCTAssertEqual(submitted, ["HARN42"])
  }

  func testLinkDeviceUppercasesAsTyped() {
    let model = PutioLinkDeviceModel(actions: PutioAccountSecurityActions())
    model.code = "x7k2qm"
    model.codeEdited()
    XCTAssertEqual(model.code, "X7K2QM")
  }

  func testLeavingMidLinkCancelsWithoutAResult() async {
    let model = PutioLinkDeviceModel(
      actions: PutioAccountSecurityActions(linkDevice: { _ in
        try await Task.sleep(for: .seconds(60))
        return PutioAuthorizedApp(id: 77, name: "TV", isCurrentClient: false)
      }))
    model.code = "X7K2QM"
    let linking = Task { await model.link() }
    while !model.isLinking { await Task.yield() }
    model.cancel()
    XCTAssertFalse(model.isLinking)
    await linking.value
    XCTAssertNil(model.linkedApp)
    XCTAssertNil(model.failure)
    XCTAssertFalse(model.isLinking)
    XCTAssertTrue(model.canLink)
  }

  func testLinkDevicePrefillIsNormalized() {
    let model = PutioLinkDeviceModel(actions: PutioAccountSecurityActions(), code: " ab12cd ")
    XCTAssertEqual(model.code, "AB12CD")
    XCTAssertEqual(PutioLinkDeviceModel(actions: PutioAccountSecurityActions()).code, "")
  }

  func testClearDataNeedsASelectionAndReportsAFailedRefresh() async {
    var cleared: [Set<PutioAccountDataCategory>] = []
    var notified: [Set<PutioAccountDataCategory>] = []
    var refreshes = 0
    var observed: PutioClearDataModel?
    var refreshStates: [Bool] = []
    let model = PutioClearDataModel(
      actions: PutioAccountSecurityActions(
        clearData: { selection in
          cleared.append(selection)
          if cleared.count == 1 || cleared.count == 3 { throw PutioRuntimeError.transient }
          return false
        },
        refreshAccount: {
          refreshes += 1
          refreshStates.append(observed?.isClearing ?? true)
          refreshStates.append(observed?.isBusy ?? false)
          return refreshes == 2
        }),
      onCleared: { categories, committed in notified.append(committed ? categories : []) })
    observed = model
    await model.clear()
    XCTAssertTrue(cleared.isEmpty)
    model.toggle(.trash)
    model.toggle(.files)
    model.toggle(.history)
    model.toggle(.files)
    XCTAssertEqual(model.orderedSelection, [.history, .trash])
    await model.clear()
    XCTAssertEqual(model.selection, [.history, .trash], "a failed clear dropped the selection")
    XCTAssertNotNil(model.failure)
    XCTAssertFalse(model.didClear)
    await model.clear()
    XCTAssertTrue(model.didClear)
    XCTAssertTrue(model.selection.isEmpty)
    XCTAssertNotNil(model.refreshWarning)
    await model.refreshAccount()
    XCTAssertNotNil(model.refreshWarning)
    await model.refreshAccount()
    XCTAssertNil(model.refreshWarning)
    XCTAssertEqual(
      refreshStates, [false, true, false, true], "a refresh showed as a clear in progress")
    model.toggle(.files)
    XCTAssertFalse(model.didClear, "a new selection kept the earlier result")
    await model.clear()
    XCTAssertFalse(model.didClear, "an earlier success survived a failed attempt")
    XCTAssertNil(model.refreshWarning)
    XCTAssertEqual(cleared, [[.history, .trash], [.history, .trash], [.files]])
    XCTAssertEqual(
      notified, [[], [.history, .trash], []],
      "the shell must reconcile after every attempt and purge only after a confirmed clear")
  }

  func testPresentationMapsRejectionsAndHidesSessionEndings() {
    XCTAssertNil(PutioAccountSecurityPresentation.message(for: PutioRuntimeError.sessionExpired))
    XCTAssertNil(PutioAccountSecurityPresentation.message(for: CancellationError()))
    XCTAssertEqual(
      PutioAccountSecurityPresentation.message(for: PutioAccountSecurityError.invalidDeviceCode),
      "That device code was not found. Check the code on the device and try again.")
    XCTAssertEqual(
      PutioAccountSecurityPresentation.message(for: PutioRuntimeError.transient),
      "Check your connection and try again.")
  }
}

@MainActor
private final class RequestGate {
  private var isClosed = false
  private var continuation: CheckedContinuation<Void, Never>?

  func wait() async {
    guard !isClosed else { return }
    await withCheckedContinuation { continuation = $0 }
  }

  func waitForRequest() async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while continuation == nil {
      guard ContinuousClock.now < deadline else {
        throw NSError(
          domain: "AccountSecurityTests", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "List request did not start"])
      }
      try await Task.sleep(for: .milliseconds(1))
    }
  }

  func finish() {
    isClosed = true
    continuation?.resume()
    continuation = nil
  }
}
