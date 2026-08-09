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

@Test func rejectsUnknownPlatform() {
  #expect(throws: HarnessFailure.self) {
    try HarnessArgumentParser.parse(["proof", "--platform", "visionos"])
  }
}

@Test func defaultsLiveProfile() throws {
  let invocation = try HarnessArgumentParser.parse(["auth-status", "--output", "json"])
  #expect(invocation == .authStatus(profile: "devs-fe-auto", output: .json))
}

@Test func publishRequiresPositivePullRequest() {
  #expect(throws: HarnessFailure.self) {
    try HarnessArgumentParser.parse([
      "publish", "--artifact", "proof.png", "--repo", "putdotio/putio-ios", "--pr", "0",
    ])
  }
}
