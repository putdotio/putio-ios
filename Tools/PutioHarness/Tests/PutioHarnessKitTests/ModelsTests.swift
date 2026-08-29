import Foundation
import Testing

@testable import PutioHarnessKit

@Test func platformContractsStayExplicit() {
  #expect(HarnessPlatform.ios.configuration.scheme == "Putio")
  #expect(HarnessPlatform.ios.configuration.extraBuildSchemes == ["PutioNightly"])
  #expect(
    HarnessPlatform.ios.configuration.snapshotSuites
      == [
        SnapshotSuite(scheme: "Putio", target: "PutioSnapshotTests"),
        SnapshotSuite(scheme: "PutioFeatureTests", target: "PutioFeatureTests"),
      ]
  )
  #expect(HarnessPlatform.watchos.configuration.bundleIdentifier == "io.put.dev.ios.watchkitapp")
  #expect(HarnessPlatform.watchos.configuration.snapshotSuites.isEmpty)
  #expect(HarnessPlatform.tvos.configuration.productDirectory == "Debug-appletvsimulator")
  #expect(
    HarnessPlatform.tvos.configuration.snapshotSuites
      == [SnapshotSuite(scheme: "PutioTV", target: "PutioTVSnapshotTests")]
  )
  #expect(HarnessPlatform.tvos.configuration.extraBuildSchemes.isEmpty)
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

@Test func browserJourneyContractUsesSeededFixtureAndExactTest() {
  #expect(JourneyScenario.filesBrowser.fixtureSet == "seeded-files-browser-v1")
  #expect(
    BrowserJourneyContract.testIdentifier
      == "PutioUITests/FilesBrowserJourneyTests/testRootNestedFolderAndNativeBack"
  )
  #expect(
    BrowserJourneyContract.attachmentNames
      == ["files-browser-root", "files-browser-nested", "files-browser-back"]
  )
}

@Test func browserJourneySelectsAttachmentsBySuggestedName() throws {
  let manifest = Data(
    #"""
    [
      {
        "attachments": [
          {
            "exportedFileName": "opaque-nested.png",
            "suggestedHumanReadableName": "files-browser-nested_0_123E4567-E89B-12D3-A456-426614174000.png"
          },
          {
            "exportedFileName": "opaque-root.png",
            "suggestedHumanReadableName": "files-browser-root"
          },
          {
            "exportedFileName": "opaque-back.png",
            "suggestedHumanReadableName": "files-browser-back_2_123E4567-E89B-12D3-A456-426614174002.png"
          }
        ]
      }
    ]
    """#.utf8
  )

  let selected = try selectJourneyAttachmentFiles(from: manifest)

  #expect(selected["files-browser-root"] == "opaque-root.png")
  #expect(selected["files-browser-nested"] == "opaque-nested.png")
  #expect(selected["files-browser-back"] == "opaque-back.png")
}

@Test func browserJourneyRejectsMissingDuplicateAndUnsafeAttachments() {
  let missing = Data(
    #"[{"attachments":[{"exportedFileName":"root.png","suggestedHumanReadableName":"root"}]}]"#
      .utf8
  )
  #expect(throws: HarnessFailure.self) {
    try selectJourneyAttachmentFiles(from: missing, expectedNames: ["root", "nested"])
  }

  let duplicate = Data(
    #"[{"attachments":[{"exportedFileName":"one.png","suggestedHumanReadableName":"root"},{"exportedFileName":"two.png","suggestedHumanReadableName":"root"}]}]"#
      .utf8
  )
  #expect(throws: HarnessFailure.self) {
    try selectJourneyAttachmentFiles(from: duplicate, expectedNames: ["root"])
  }

  let unsafe = Data(
    #"[{"attachments":[{"exportedFileName":"../root.png","suggestedHumanReadableName":"root"}]}]"#
      .utf8
  )
  #expect(throws: HarnessFailure.self) {
    try selectJourneyAttachmentFiles(from: unsafe, expectedNames: ["root"])
  }
}

@Test func browserJourneyRequiresExactlyOnePassingTest() throws {
  let passing = Data(
    #"{"result":"Passed","totalTestCount":1,"passedTests":1,"failedTests":0,"skippedTests":0,"expectedFailures":0}"#
      .utf8
  )
  #expect(try requirePassingJourneySummary(passing).passedTests == 1)

  let extra = Data(
    #"{"result":"Passed","totalTestCount":2,"passedTests":2,"failedTests":0,"skippedTests":0,"expectedFailures":0}"#
      .utf8
  )
  #expect(throws: HarnessFailure.self) {
    try requirePassingJourneySummary(extra)
  }

  let skipped = Data(
    #"{"result":"Passed","totalTestCount":1,"passedTests":0,"failedTests":0,"skippedTests":1,"expectedFailures":0}"#
      .utf8
  )
  #expect(throws: HarnessFailure.self) {
    try requirePassingJourneySummary(skipped)
  }
}

@Test func proofRevisionRejectsDriftFromPinnedCommit() throws {
  try requireMatchingProofRevision(expected: "abc123", actual: "abc123")
  #expect(throws: HarnessFailure.self) {
    try requireMatchingProofRevision(expected: "abc123", actual: "def456")
  }
}

@Test func repositoryPathsStayRelativeInHarnessOutput() {
  let context = RepositoryContext(root: URL(fileURLWithPath: "/Users/example/putio-ios"))
  #expect(
    context.relativePath(for: context.proofRoot.appending(path: "run/ios"))
      == "build/proof/run/ios"
  )
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

@Test func watchBuildPlanReusesOnlyAnAvailableIOSCompanion() {
  #expect(shouldBuildIOSCompanion(for: .watchos, iosCompanionAvailable: false))
  #expect(!shouldBuildIOSCompanion(for: .watchos, iosCompanionAvailable: true))
  #expect(!shouldBuildIOSCompanion(for: .ios, iosCompanionAvailable: false))
}

@Test func watchBuildRejectsMissingReusedIOSCompanion() throws {
  let root = FileManager.default.temporaryDirectory.appending(
    path: "putio-harness-watch-build-\(UUID().uuidString.lowercased())")
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(
    at: root.appending(path: "Putio.xcworkspace"), withIntermediateDirectories: true)

  #expect(throws: HarnessFailure.self) {
    try SimulatorHarness(context: RepositoryContext(root: root)).build(
      .watchos, iosCompanionAvailable: true)
  }
}
