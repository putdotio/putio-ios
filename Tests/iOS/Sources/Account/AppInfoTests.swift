import StoreKit
import XCTest

@testable import Putio

final class AppInfoTests: XCTestCase {
  func testChannelIsNightlyByBundleThenTestFlightBySandboxElseAppStore() {
    XCTAssertEqual(
      PutioReleaseChannel.resolve(bundleIdentifier: "io.put.nightly.ios", environment: .sandbox),
      .nightly)
    XCTAssertEqual(
      PutioReleaseChannel.resolve(bundleIdentifier: "io.put.ios", environment: .sandbox),
      .testFlight)
    XCTAssertEqual(
      PutioReleaseChannel.resolve(bundleIdentifier: "io.put.ios", environment: .production),
      .appStore)
    XCTAssertEqual(
      PutioReleaseChannel.resolve(bundleIdentifier: "io.put.ios", environment: nil), .appStore)
  }

  func testSupportTextIsTheFiveFieldsOnePerLine() {
    let info = PutioAppInfo(
      version: "3.1.0", build: "4120", channel: .testFlight, device: "iPhone",
      systemVersion: "26.1")
    XCTAssertEqual(
      info.supportText,
      "Version: 3.1.0 (build 4120)\nChannel: TestFlight\nDevice: iPhone\niOS: 26.1\nPlayer: AVPlayer"
    )
  }
}
