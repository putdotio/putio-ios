import XCTest

@testable import Putio

final class SentryConfigurationTests: XCTestCase {
  private let dsn = "https://synthetickey@o0.ingest.example.invalid/4500000000000001"

  func testReportsThroughTheRelayAsTheBuiltAppAndEnvironment() throws {
    let configuration = try XCTUnwrap(SentryConfiguration(info: info()))

    XCTAssertEqual(configuration.dsn, "https://synthetickey@relay.put.io/4500000000000001")
    XCTAssertEqual(configuration.environment, "nightly")
    XCTAssertEqual(configuration.releaseName, "io.put.nightly.ios@1.2.3+45")
    XCTAssertEqual(
      SentryConfiguration.relayDSN("https://k@relay.put.io/12"), "https://k@relay.put.io/12")
    XCTAssertEqual(
      SentryConfiguration.relayDSN("https://k:legacy@sentry.example.invalid/base/12/"),
      "https://k@relay.put.io/12")
  }

  func testKillSwitchAndUnusableDSNsDisableReporting() {
    XCTAssertNil(SentryConfiguration(info: info(enabled: "NO")))
    XCTAssertNil(SentryConfiguration(info: info(enabled: "")))
    for unusable in [
      "", "$(PUTIO_SENTRY_DSN)", "https://sentry.example.invalid/12",
      "https://k@host/not-a-project",
      "ftp://k@host/12", "not a dsn",
    ] {
      XCTAssertNil(SentryConfiguration(info: info(dsn: unusable)), unusable)
    }
  }

  func testTheCheckedInBuildReportsNothing() {
    XCTAssertNil(SentryConfiguration(bundle: .main), "a checked-in build must not carry a DSN")
  }

  private func info(dsn: String? = nil, enabled: String = "YES") -> [String: Any] {
    [
      "PUTIO_SENTRY_DSN": dsn ?? self.dsn,
      "PUTIO_SENTRY_ENABLED": enabled,
      "PUTIO_SENTRY_ENVIRONMENT": "nightly",
      "CFBundleIdentifier": "io.put.nightly.ios",
      "CFBundleShortVersionString": "1.2.3",
      "CFBundleVersion": "45",
    ]
  }
}
