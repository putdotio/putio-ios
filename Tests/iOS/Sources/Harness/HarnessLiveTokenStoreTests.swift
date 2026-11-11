import PutioCore
import XCTest

@testable import Putio

final class HarnessLiveTokenStoreTests: XCTestCase {
  /// A cleared token must still leave a copy the sign-out launch can restore
  /// and revoke until revocation is confirmed.
  func testClearedTokenStaysRestorableUntilRevocationIsConfirmed() throws {
    let store = HarnessLiveTokenStore(
      active: PutioInMemoryTokenStore(), pending: PutioInMemoryTokenStore())
    try store.write("live-token")

    try store.clear()
    XCTAssertEqual(try store.read(), "live-token")

    try store.confirmRevoked()
    XCTAssertNil(try store.read())
  }

  func testAFreshSignInWinsOverAPendingToken() throws {
    let store = HarnessLiveTokenStore(
      active: PutioInMemoryTokenStore(), pending: PutioInMemoryTokenStore(token: "old-token"))
    try store.write("new-token")
    XCTAssertEqual(try store.read(), "new-token")
  }

  func testOnlyAFinishedSignOutAndExpiryProveRevocation() {
    XCTAssertTrue(
      HarnessLiveSession.provesRevocation(.signedOut(.userSignedOut), signOutCleanupPending: false))
    XCTAssertTrue(
      HarnessLiveSession.provesRevocation(.signedOut(.sessionExpired), signOutCleanupPending: false)
    )
    XCTAssertFalse(
      HarnessLiveSession.provesRevocation(.signedOut(nil), signOutCleanupPending: false))
    XCTAssertFalse(
      HarnessLiveSession.provesRevocation(.signedOut(.userSignedOut), signOutCleanupPending: true))
    XCTAssertFalse(HarnessLiveSession.provesRevocation(.signingOut, signOutCleanupPending: true))
    XCTAssertEqual(
      HarnessLiveSession.outcome(for: .signedOut(.userSignedOut), signOutCleanupPending: true),
      "sign-out-failed")
  }
}
