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
