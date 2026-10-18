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

  func testDescriptionsKeepTheApprovedCopy() {
    XCTAssertEqual(
      PutioPrivacyControls.strictlyNecessary.description,
      "Needed for sign-in, security, transfers, downloads, playback, billing, and saving your choices."
    )
    XCTAssertEqual(
      PutioPrivacyControls.diagnostics.description,
      "Crash reports, error details, and limited playback diagnostics, so we can fix problems."
    )
    XCTAssertEqual(
      PutioPrivacyControls.productAnalytics.description,
      "Limited usage, device, billing, and playback data that shows which apps and features work."
    )
    XCTAssertEqual(
      PutioPrivacyControls.groupFooter,
      "Diagnostics and product analytics never send filenames, media titles, URLs, search text, or tokens."
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
