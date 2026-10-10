import Foundation
import XCTest

@testable import PutioCore

@MainActor
final class DiagnosticsConsentTests: XCTestCase {
  func testOnUntilTheAccountTurnsItOffAndBackOnWhenSignedOut() throws {
    let defaults = try makeDefaults()
    let consent = PutioDiagnosticsConsent(defaults: defaults)
    XCTAssertTrue(consent.isEnabled, "no answer yet counts as on")

    XCTAssertFalse(consent.update(for: .signedIn(Self.account(diagnostics: true))))
    XCTAssertTrue(consent.update(for: .signedIn(Self.account(diagnostics: false))))
    XCTAssertFalse(consent.isEnabled)

    for transitional in [PutioSessionState.unknown, .signingOut, .signOutFailed(.revocation)] {
      XCTAssertFalse(consent.update(for: transitional))
      XCTAssertFalse(consent.isEnabled, "\(transitional) dropped the account's opt-out")
    }

    XCTAssertTrue(consent.update(for: .signedOut(.userSignedOut)))
    XCTAssertTrue(consent.isEnabled, "signed out counts as on")
    consent.update(for: .signedIn(Self.account(diagnostics: false)))
    XCTAssertTrue(consent.update(for: .authenticating))
    XCTAssertTrue(consent.isEnabled)
  }

  func testColdLaunchHonorsTheLastAccountAnswerUntilTheSessionResolves() throws {
    let defaults = try makeDefaults()
    PutioDiagnosticsConsent(defaults: defaults)
      .update(for: .signedIn(Self.account(diagnostics: false)))

    let relaunched = PutioDiagnosticsConsent(defaults: defaults)
    XCTAssertFalse(relaunched.isEnabled)
    relaunched.update(for: .unknown)
    XCTAssertFalse(relaunched.isEnabled)

    relaunched.update(for: .signedOut(.sessionExpired))
    XCTAssertTrue(PutioDiagnosticsConsent(defaults: defaults).isEnabled)
  }

  private func makeDefaults() throws -> UserDefaults {
    let suiteName = "DiagnosticsConsentTests.\(UUID().uuidString)"
    addTeardownBlock { UserDefaults().removePersistentDomain(forName: suiteName) }
    return try XCTUnwrap(UserDefaults(suiteName: suiteName))
  }

  private static func account(diagnostics: Bool) -> PutioAccountSnapshot {
    PutioAccountSnapshot(
      id: 10, username: "fixture", email: "fixture@example.invalid", suggestNextVideo: false,
      rememberVideoTime: false, defaultSort: nil, historyEnabled: true, trashEnabled: true,
      storage: .init(availableBytes: 100, totalBytes: 200, usedBytes: 100),
      diagnosticsEnabled: diagnostics)
  }
}
