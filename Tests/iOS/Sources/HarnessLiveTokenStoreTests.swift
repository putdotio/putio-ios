import PutioCore
import XCTest

@testable import Putio

final class HarnessLiveTokenStoreTests: XCTestCase {
  /// Sign-out clears the saved token before revoking it. A failed or
  /// interrupted revocation must still leave a copy the sign-out launch can
  /// restore and revoke.
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

  func testOnlySignOutAndExpiryProveRevocation() {
    XCTAssertTrue(HarnessLiveSession.provesRevocation(.signedOut(.userSignedOut)))
    XCTAssertTrue(HarnessLiveSession.provesRevocation(.signedOut(.sessionExpired)))
    XCTAssertFalse(HarnessLiveSession.provesRevocation(.signedOut(nil)))
    XCTAssertFalse(HarnessLiveSession.provesRevocation(.signOutFailed(.revocation)))
    XCTAssertFalse(HarnessLiveSession.provesRevocation(.signingOut))
  }
}
