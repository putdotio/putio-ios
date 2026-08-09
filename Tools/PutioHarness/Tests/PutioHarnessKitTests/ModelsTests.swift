import Foundation
import Testing

@testable import PutioHarnessKit

@Test func platformContractsStayExplicit() {
  #expect(HarnessPlatform.ios.configuration.scheme == "Putio")
  #expect(HarnessPlatform.watchos.configuration.bundleIdentifier == "io.put.dev.ios.watchkitapp")
  #expect(HarnessPlatform.tvos.configuration.productDirectory == "Debug-appletvsimulator")
}

@Test func proofManifestRoundTrips() throws {
  let manifest = ProofManifest(
    runID: "unit-test",
    commit: "abc123",
    createdAt: "2026-08-09T00:00:00Z",
    command: "proof",
    platform: .ios,
    scheme: "Putio",
    bundleIdentifier: "io.put.dev.ios",
    runtime: "iOS 26.5",
    deviceType: "iPhone 17 Pro",
    simulatorName: "putio-harness-ios-unit-test",
    fixtureSet: "signed-out-placeholder-v1",
    artifacts: [
      ProofArtifact(
        kind: "screenshot", path: "build/proof/unit-test/ios/signed-out.png", bytes: 42,
        sha256: "deadbeef")
    ]
  )
  let data = try JSONEncoder().encode(manifest)
  #expect(try JSONDecoder().decode(ProofManifest.self, from: data) == manifest)
}

@Test func doctorFailsOnlyForRequiredFailures() {
  let warningOnly = DoctorReport(checks: [
    DoctorCheck(name: "attach", status: .warning, required: false, detail: "missing")
  ])
  let requiredFailure = DoctorReport(checks: [
    DoctorCheck(name: "xcode", status: .failed, required: true, detail: "missing")
  ])
  #expect(warningOnly.status == "ok")
  #expect(requiredFailure.status == "failed")
}

@Test func runtimeMatchingUsesMajorMinorCompatibility() {
  #expect(runtimeMatchesSDK("26.5", "26.5.1"))
  #expect(!runtimeMatchesSDK("26.4.1", "26.5"))
}
