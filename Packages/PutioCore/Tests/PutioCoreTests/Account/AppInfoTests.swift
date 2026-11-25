import StoreKit
import XCTest

@testable import PutioCore

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

  func testSupportTextIsTheFiveFieldsOnePerLineNamingThePlatform() {
    let phone = PutioAppInfo(
      version: "3.1.0", build: "4120", channel: .testFlight, device: "iPhone",
      systemName: "iOS", systemVersion: "26.1")
    XCTAssertEqual(
      phone.supportText,
      "Version: 3.1.0 (build 4120)\nChannel: TestFlight\nDevice: iPhone\niOS: 26.1\nPlayer: AVPlayer"
    )
    let tv = PutioAppInfo(
      version: "3.2.0", build: "4188", channel: .appStore, device: "Apple TV",
      systemName: "tvOS", systemVersion: "27.0")
    XCTAssertEqual(tv.fields.map(\.title), ["Version", "Channel", "Device", "tvOS", "Player"])
  }

  func testSupportMailtoAddressesSupportWithTheAppInfoAsBody() throws {
    let tv = PutioAppInfo(
      version: "3.2.0", build: "4188", channel: .appStore, device: "Apple TV",
      systemName: "tvOS", systemVersion: "27.0")
    let link = try XCTUnwrap(URLComponents(string: tv.supportMailto))
    XCTAssertEqual(link.scheme, "mailto")
    XCTAssertEqual(link.path, "support@put.io")
    XCTAssertEqual(link.queryItems?.first { $0.name == "body" }?.value, tv.supportText)
  }

  func testLicenseNoticesPutTheAppFirstWithTheRunningVersion() throws {
    let json = Data(
      #"""
      {"app":{"name":"put.io","license":"MIT","copyright":"put.io","licenseText":"https://put.io/license"},
       "packages":[{"name":"Sentry","version":"9.1.0","license":"MIT","copyright":"Sentry","licenseText":"https://sentry.io/license"}]}
      """#.utf8)
    let manifest = try JSONDecoder().decode(PutioLicenseManifest.self, from: json)
    let notices = manifest.notices(appVersion: "3.2.0")
    XCTAssertEqual(notices.map(\.title), ["put.io 3.2.0", "Sentry 9.1.0"])
  }
}
