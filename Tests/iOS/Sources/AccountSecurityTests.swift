import Foundation
import PutioCore
import XCTest

@testable import Putio

@MainActor
final class AccountSecurityTests: XCTestCase {
  func testEnrollmentClearsARejectedCodeAndEndsOnRecoveryCodes() async {
    var submitted: [(Bool, String)] = []
    let model = PutioTwoFactorChangeModel(
      enabling: true,
      actions: PutioAccountSecurityActions(
        generateSecret: { " JBSWY3DP " },
        setTwoFactor: { enable, code in
          submitted.append((enable, code))
          if code == "000000" { throw PutioAccountSecurityError.invalidTwoFactorCode }
          return .init(accountRefreshed: true)
        },
        recoveryCodes: { [PutioTwoFactorRecoveryCode(code: "a-1", isUsed: false)] }))
    XCTAssertEqual(model.step, .loadingSecret)
    await model.loadSecret()
    XCTAssertEqual(model.step, .secret(" JBSWY3DP "))
    XCTAssertFalse(model.canSubmit)
    model.continueToCode()
    XCTAssertEqual(model.step, .code)
    model.code = "000000"
    await model.submit()
    XCTAssertEqual(model.code, "", "the rejected code stayed in the field")
    XCTAssertNotNil(model.codeFailure)
    XCTAssertEqual(model.step, .code)
    model.code = " 246810 "
    await model.submit()
    XCTAssertNil(model.codeFailure)
    XCTAssertEqual(
      model.step, .recoveryCodes([PutioTwoFactorRecoveryCode(code: "a-1", isUsed: false)]))
    XCTAssertEqual(submitted.map(\.0), [true, true])
    XCTAssertEqual(submitted.map(\.1), ["000000", " 246810 "])
    model.finish()
    XCTAssertEqual(model.step, .finished(accountRefreshed: true))
  }

  func testTransientFailureKeepsTheCodeAndDisablingSkipsRecoveryCodes() async {
    var attempts = 0
    let model = PutioTwoFactorChangeModel(
      enabling: false,
      actions: PutioAccountSecurityActions(
        setTwoFactor: { _, _ in
          attempts += 1
          if attempts == 1 { throw PutioRuntimeError.transient }
          return .init(accountRefreshed: false)
        },
        recoveryCodes: {
          XCTFail("disabling loaded recovery codes")
          return []
        }))
    XCTAssertEqual(model.step, .code)
    await model.loadSecret()
    XCTAssertEqual(model.step, .code, "disabling generated a secret")
    model.code = "246810"
    await model.submit()
    XCTAssertEqual(model.code, "246810")
    XCTAssertNotNil(model.codeFailure)
    await model.submit()
    XCTAssertEqual(model.step, .finished(accountRefreshed: false))
  }

  func testEnabledWithFailedRecoveryCodesOffersAnotherLoad() async {
    var loads = 0
    let model = PutioTwoFactorChangeModel(
      enabling: true,
      actions: PutioAccountSecurityActions(
        generateSecret: { "S" },
        recoveryCodes: {
          loads += 1
          if loads == 1 { throw PutioRuntimeError.transient }
          return [PutioTwoFactorRecoveryCode(code: "b-2", isUsed: true)]
        }))
    await model.loadSecret()
    model.continueToCode()
    model.code = "1"
    await model.submit()
    XCTAssertEqual(model.step, .code)
    XCTAssertNotNil(model.recoveryCodesFailure)
    await model.retryRecoveryCodes()
    XCTAssertEqual(
      model.step, .recoveryCodes([PutioTwoFactorRecoveryCode(code: "b-2", isUsed: true)]))
    XCTAssertEqual(loads, 2)
  }

  func testRecoveryCodesRegenerateFailureKeepsCurrentCodesAndCopiesUnusedOnly() async {
    var regenerations = 0
    let model = PutioRecoveryCodesModel(
      actions: PutioAccountSecurityActions(
        recoveryCodes: {
          [
            PutioTwoFactorRecoveryCode(code: "a-1", isUsed: false),
            PutioTwoFactorRecoveryCode(code: "a-2", isUsed: true),
          ]
        },
        regenerateRecoveryCodes: {
          regenerations += 1
          if regenerations == 1 { throw PutioRuntimeError.transient }
          return [PutioTwoFactorRecoveryCode(code: "z-9", isUsed: false)]
        }))
    await model.load()
    XCTAssertEqual(model.copyableText, "a-1")
    await model.regenerate()
    XCTAssertEqual(model.codes?.map(\.code), ["a-1", "a-2"])
    XCTAssertTrue(model.canRetryRegenerate)
    await model.regenerate()
    XCTAssertEqual(model.codes?.map(\.code), ["z-9"])
    XCTAssertNil(model.failure)
    XCTAssertFalse(model.canRetryRegenerate)
  }

  func testRevokeFailureKeepsTheAppAndTheCurrentClientIsNeverRevoked() async {
    var revoked: [Int] = []
    let apps = [
      PutioAuthorizedApp(id: 3001, name: "This", description: "", isCurrentClient: true),
      PutioAuthorizedApp(id: 42, name: "TV", description: "", isCurrentClient: false),
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
    XCTAssertEqual(model.failedRevokeID, 42)
    XCTAssertNotNil(model.revokeFailure)
    await model.retryRevoke()
    XCTAssertEqual(revoked, [42, 42])
    XCTAssertEqual(model.apps.map(\.id), [3001])
    XCTAssertNil(model.revokeFailure)
  }

  func testAppsLoadFailureIsRetryableAndSessionEndingsStaySilent() async {
    var loads = 0
    let model = PutioAuthorizedAppsModel(
      actions: PutioAccountSecurityActions(listApps: {
        loads += 1
        if loads == 1 { throw PutioRuntimeError.transient }
        if loads == 2 { throw PutioRuntimeError.sessionExpired }
        return []
      }))
    await model.load()
    guard case .failed = model.state else { return XCTFail("load failure was not shown") }
    await model.load()
    XCTAssertEqual(model.state, .loading, "a session ending produced an error state")
    await model.load()
    XCTAssertEqual(model.state, .loaded([]))
  }

  func testLinkDeviceRejectionClearsTheCodeAndSuccessIsAcknowledged() async {
    let model = PutioLinkDeviceModel(
      actions: PutioAccountSecurityActions(linkDevice: { code in
        guard code == "HARN" else { throw PutioAccountSecurityError.invalidDeviceCode }
        return PutioAuthorizedApp(id: 77, name: "TV", description: "", isCurrentClient: false)
      }))
    XCTAssertFalse(model.canLink)
    model.code = "ZZZZ"
    await model.link()
    XCTAssertEqual(model.code, "")
    XCTAssertNotNil(model.failure)
    model.code = "HARN"
    await model.link()
    XCTAssertEqual(model.linkedApp?.id, 77)
    XCTAssertNil(model.failure)
    model.acknowledgeLink()
    XCTAssertNil(model.linkedApp)
    XCTAssertEqual(model.code, "")
  }

  func testClearDataNeedsASelectionAndReportsAFailedRefresh() async {
    var cleared: [Set<PutioAccountDataCategory>] = []
    var refreshes = 0
    let model = PutioClearDataModel(
      actions: PutioAccountSecurityActions(
        clearData: { selection in
          cleared.append(selection)
          if cleared.count == 1 { throw PutioRuntimeError.transient }
          return false
        },
        refreshAccount: {
          refreshes += 1
          return refreshes == 2
        }))
    await model.clear()
    XCTAssertTrue(cleared.isEmpty)
    model.selection = [.history, .trash]
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
    XCTAssertEqual(cleared, [[.history, .trash], [.history, .trash]])
  }

  func testDestroyAccountRejectionKeepsTheScreenAndNeverRetainsThePassword() async {
    var passwords: [String] = []
    let model = PutioDestroyAccountModel(
      actions: PutioAccountSecurityActions(destroyAccount: { password in
        passwords.append(password)
        if password == "wrong" { throw PutioAccountSecurityError.invalidPassword }
      }))
    XCTAssertFalse(model.canDestroy)
    model.password = "wrong"
    await model.destroy()
    XCTAssertEqual(model.password, "")
    XCTAssertNotNil(model.failure)
    model.password = "right"
    await model.destroy()
    XCTAssertNil(model.failure)
    XCTAssertEqual(passwords, ["wrong", "right"])
  }

  func testPresentationMapsRejectionsAndHidesSessionEndings() {
    XCTAssertNil(PutioAccountSecurityPresentation.message(for: PutioRuntimeError.sessionExpired))
    XCTAssertNil(PutioAccountSecurityPresentation.message(for: CancellationError()))
    XCTAssertEqual(
      PutioAccountSecurityPresentation.message(for: PutioAccountSecurityError.invalidPassword),
      "That password does not match our records. Check it and try again.")
    XCTAssertEqual(
      PutioAccountSecurityPresentation.message(for: PutioRuntimeError.transient),
      "Check your connection and try again.")
  }
}
