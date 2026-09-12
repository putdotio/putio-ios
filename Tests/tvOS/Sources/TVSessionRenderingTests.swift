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
  func testAccountMatchesBaseline() throws {
    _ = try assertRenderingSnapshot(
      name: "tv-account",
      view: TVAccountScreen(account: Self.account, locale: Locale(identifier: "en_US")) {},
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

  private static let account = PutioAccountSnapshot(
    id: 1001,
    username: "moviebuff",
    email: "moviebuff@example.com",
    suggestNextVideo: true,
    rememberVideoTime: true,
    defaultSort: nil,
    historyEnabled: true,
    trashEnabled: true,
    storage: PutioAccountSnapshot.Storage(
      availableBytes: 1_068_893_827_072,
      totalBytes: 1_099_511_627_776,
      usedBytes: 30_617_800_704
    ),
    routeName: "default",
    hideSubtitles: false,
    dontAutoSelectSubtitles: false,
    twoFactorEnabled: false
  )
}
