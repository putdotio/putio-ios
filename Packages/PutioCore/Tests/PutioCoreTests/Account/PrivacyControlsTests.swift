import XCTest

@testable import PutioCore

final class PrivacyControlsTests: XCTestCase {
  func testSummaryNamesEachControlState() {
    XCTAssertEqual(
      PutioPrivacyControls.summary(for: Self.account(diagnostics: true, productAnalytics: false)),
      "Diagnostics on · Product analytics off")
    XCTAssertEqual(
      PutioPrivacyControls.summary(for: Self.account(diagnostics: false, productAnalytics: true)),
      "Diagnostics off · Product analytics on")
  }

  func testDescriptionsKeepTheContractCopy() {
    XCTAssertEqual(
      PutioPrivacyControls.strictlyNecessary.description,
      "Required for login, security, account access, transfers, downloads, playback, billing operations, and remembering your choices. These cannot be turned off."
    )
    XCTAssertEqual(
      PutioPrivacyControls.diagnostics.description,
      "Send crash reports, error details, and limited playback diagnostics so we can find and fix problems. We do not send filenames, media titles, URLs, search text, or tokens."
    )
    XCTAssertEqual(
      PutioPrivacyControls.productAnalytics.description,
      "Help us understand which apps and features work well by sending limited usage, device, billing, and playback information. We never send filenames, media titles, URLs, search text, or tokens."
    )
  }

  private static func account(diagnostics: Bool, productAnalytics: Bool) -> PutioAccountSnapshot {
    PutioAccountSnapshot(
      id: 10, username: "fixture", email: "fixture@example.invalid", suggestNextVideo: false,
      rememberVideoTime: false, defaultSort: nil, historyEnabled: true, trashEnabled: true,
      storage: .init(availableBytes: 100, totalBytes: 200, usedBytes: 100),
      diagnosticsEnabled: diagnostics, productAnalyticsEnabled: productAnalytics)
  }
}
