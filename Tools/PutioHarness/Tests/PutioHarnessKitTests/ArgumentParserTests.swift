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
        output: .json
      )
  )
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
    #"{"access_token":"live-secret","password":"pw-secret"}"#,
    environment: [:]
  )
  #expect(!json.contains("live-secret"))
  #expect(!json.contains("pw-secret"))
  #expect(json == #"{"access_token":"[REDACTED]","password":"[REDACTED]"}"#)
}
