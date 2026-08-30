import Testing

@testable import PutioHarnessKit

@Test func parsesAllPlatformProof() throws {
  let invocation = try HarnessArgumentParser.parse([
    "proof", "--platform", "all", "--run-id", "pr-146", "--record-seconds", "4", "--output", "json",
  ])
  #expect(
    invocation
      == .surface(
        command: .proof,
        platforms: .all,
        runID: "pr-146",
        recordSeconds: 4,
        scenario: .signedOut,
        output: .json
      )
  )
}

@Test func parsesStandaloneBoot() throws {
  let invocation = try HarnessArgumentParser.parse([
    "boot", "--platform", "watchos", "--output", "json",
  ])
  #expect(
    invocation
      == .surface(
        command: .boot,
        platforms: .one(.watchos),
        runID: nil,
        recordSeconds: 3,
        scenario: .signedOut,
        output: .json
      )
  )
}

@Test func parsesGalleryScreenshot() throws {
  let invocation = try HarnessArgumentParser.parse([
    "screenshot", "--platform", "ios", "--scenario", "gallery", "--output", "json",
  ])
  #expect(
    invocation
      == .surface(
        command: .screenshot,
        platforms: .one(.ios),
        runID: nil,
        recordSeconds: 3,
        scenario: .gallery,
        output: .json
      )
  )
}

@Test func parsesFilesBrowserJourney() throws {
  let invocation = try HarnessArgumentParser.parse([
    "journey", "--platform", "ios", "--scenario", "files-browser", "--run-id", "browser-1",
    "--output", "json",
  ])
  #expect(
    invocation
      == .journey(
        platform: .ios,
        scenario: .filesBrowser,
        runID: "browser-1",
        output: .json
      )
  )
}

@Test func rejectsGalleryScenarioOutsideCapture() {
  #expect(throws: HarnessFailure.self) {
    try HarnessArgumentParser.parse(["proof", "--platform", "ios", "--scenario", "gallery"])
  }
  #expect(throws: HarnessFailure.self) {
    try HarnessArgumentParser.parse([
      "screenshot", "--platform", "watchos", "--scenario", "gallery",
    ])
  }
}

@Test func rejectsFilesBrowserScenarioOnOrdinaryCapture() {
  #expect(throws: HarnessFailure.self) {
    try HarnessArgumentParser.parse([
      "record", "--platform", "ios", "--scenario", "files-browser",
    ])
  }
}

@Test func rejectsUnsupportedFilesBrowserJourneyShapes() {
  #expect(throws: HarnessFailure.self) {
    try HarnessArgumentParser.parse([
      "journey", "--platform", "tvos", "--scenario", "files-browser",
    ])
  }
  #expect(throws: HarnessFailure.self) {
    try HarnessArgumentParser.parse([
      "journey", "--platform", "watchos", "--scenario", "files-browser",
    ])
  }
  #expect(throws: HarnessFailure.self) {
    try HarnessArgumentParser.parse([
      "journey", "--platform", "all", "--scenario", "files-browser",
    ])
  }
  #expect(throws: HarnessFailure.self) {
    try HarnessArgumentParser.parse([
      "journey", "--platform", "ios",
    ])
  }
  #expect(throws: HarnessFailure.self) {
    try HarnessArgumentParser.parse([
      "journey", "--platform", "ios", "--scenario", "signed-in",
    ])
  }
}

@Test func parsesSnapshotTest() throws {
  let invocation = try HarnessArgumentParser.parse(["test", "--platform", "tvos"])
  #expect(invocation == .test(platform: .tvos, recordSnapshots: false, output: .text))
  let record = try HarnessArgumentParser.parse([
    "test", "--platform", "ios", "--snapshots", "record",
  ])
  #expect(record == .test(platform: .ios, recordSnapshots: true, output: .text))
}

@Test func rejectsSnapshotTestOnUnsupportedPlatform() {
  #expect(throws: HarnessFailure.self) {
    try HarnessArgumentParser.parse(["test", "--platform", "watchos"])
  }
  #expect(throws: HarnessFailure.self) {
    try HarnessArgumentParser.parse(["test", "--platform", "all"])
  }
}

@Test func rejectsUnknownPlatform() {
  #expect(throws: HarnessFailure.self) {
    try HarnessArgumentParser.parse(["proof", "--platform", "visionos"])
  }
}

@Test func defaultsLiveProfile() throws {
  let invocation = try HarnessArgumentParser.parse(["auth-status", "--output", "json"])
  #expect(invocation == .authStatus(output: .json))
}

@Test func rejectsLiveProfileAndNamespaceOverrides() {
  #expect(throws: HarnessFailure.self) {
    try HarnessArgumentParser.parse([
      "auth-status", "--profile", "personal", "--output", "json",
    ])
  }
  #expect(throws: HarnessFailure.self) {
    try HarnessArgumentParser.parse([
      "live-fixture", "--name", "unrelated", "--output", "json",
    ])
  }
}

@Test func publishRequiresPositivePullRequest() {
  #expect(throws: HarnessFailure.self) {
    try HarnessArgumentParser.parse([
      "publish", "--artifact", "proof.png", "--repo", "putdotio/putio-ios", "--pr", "0",
    ])
  }
}

@Test func errorFormatUsesOnlyOutputOptionValue() {
  #expect(
    HarnessOutput.requestedErrorFormat(arguments: [
      "proof", "--platform", "ios", "--run-id", "json", "--output", "text",
    ]) == .text
  )
  #expect(
    HarnessOutput.requestedErrorFormat(arguments: [
      "publish", "--artifact", "json", "--repo", "putdotio/putio-ios", "--pr", "156",
    ]) == .text
  )
  #expect(
    HarnessOutput.requestedErrorFormat(arguments: [
      "proof", "--platform", "ios", "--output", "json",
    ]) == .json
  )
}

@Test func errorOutputRedactsSecretsAndHomePaths() {
  let environment = [
    "HOME": "/Users/example",
    "PUTIO_CLI_TOKEN": "ambient-secret-value",
  ]
  let message = HarnessOutput.redact(
    "request failed at /Users/example/file: Authorization: Bearer bearer-value token=query-value ambient-secret-value",
    environment: environment
  )
  #expect(!message.contains("ambient-secret-value"))
  #expect(!message.contains("bearer-value"))
  #expect(!message.contains("query-value"))
  #expect(message.contains("$HOME/file"))
  #expect(message.contains("[REDACTED]"))

  let json = HarnessOutput.redact(
    #"{"access_token":"live secret","password":"correct horse","api_key":"abc,def"}"#,
    environment: [:]
  )
  #expect(!json.contains("live secret"))
  #expect(!json.contains("correct horse"))
  #expect(!json.contains("abc,def"))
  #expect(
    json
      == #"{"access_token":"[REDACTED]","password":"[REDACTED]","api_key":"[REDACTED]"}"#
  )

  let escapedJSON = HarnessOutput.redact(
    #"{"secret":"value with \"quote\" and \\ slash"}"#,
    environment: [:]
  )
  #expect(escapedJSON == #"{"secret":"[REDACTED]"}"#)

  let quotedAuthorization = HarnessOutput.redact(
    #"{"Authorization":"Bearer very-secret-token","authorization": "Basic another-secret"}"#,
    environment: [:]
  )
  #expect(!quotedAuthorization.contains("very-secret-token"))
  #expect(!quotedAuthorization.contains("another-secret"))
  #expect(
    quotedAuthorization
      == #"{"Authorization":"[REDACTED]","authorization": "[REDACTED]"}"#
  )

  let equalsAuthorization = HarnessOutput.redact(
    "Authorization=Bearer equals-secret",
    environment: [:]
  )
  #expect(!equalsAuthorization.contains("equals-secret"))
  #expect(equalsAuthorization.contains("[REDACTED]"))

  let basicAuthorization = HarnessOutput.redact(
    "Authorization: Basic basic-secret",
    environment: [:]
  )
  #expect(!basicAuthorization.contains("basic-secret"))
  #expect(basicAuthorization.contains("[REDACTED]"))
}

@Test func doctorOutputRedactsCaughtFailureDetails() throws {
  let report = DoctorReport(checks: [
    DoctorCheck(
      name: "simulator-runtimes",
      status: .failed,
      required: true,
      detail: #"command failed: {"access_token":"secret with spaces"}"#
    )
  ])

  let text = try HarnessOutput.render(.doctor(report), format: .text)
  let json = try HarnessOutput.render(.doctor(report), format: .json)
  #expect(!text.contains("secret with spaces"))
  #expect(!json.contains("secret with spaces"))
  #expect(text.contains("[REDACTED]"))
  #expect(json.contains("[REDACTED]"))
}
