import Foundation
import Testing

@testable import PutioHarnessKit

/// Exercises `OwnedSimulator.cleanup` on both sides of `claim` through a fake
/// `xcrun` ahead on the runner's PATH, recording every simctl invocation.
private func withFakeSimctl<T>(
  devices: [(udid: String, name: String)],
  _ body: (ProcessRunner, URL) throws -> T
) throws -> T {
  let root = FileManager.default.temporaryDirectory.appending(
    path: "putio-owned-simulator-\(UUID().uuidString.lowercased())")
  let bin = root.appending(path: "bin")
  try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
  let log = root.appending(path: "calls")
  let list = devices.map { #"{"udid":"\#($0.udid)","name":"\#($0.name)"}"# }.joined(separator: ",")
  let script = """
    #!/bin/sh
    echo "$@" >> "\(log.path)"
    if [ "$2" = "list" ]; then
      case " $* " in
        *" -j "*) echo '{"devices":{"runtime":[\(list)]}}';;
        *) echo '';;
      esac
    fi
    """
  let xcrun = bin.appending(path: "xcrun")
  try script.write(to: xcrun, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: xcrun.path)
  defer { try? FileManager.default.removeItem(at: root) }
  // Foundation snapshots the process environment on first access, so PATH is
  // redirected per runner instead of through `setenv`.
  let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
  return try body(ProcessRunner(environment: ["PATH": "\(bin.path):\(originalPath)"]), log)
}

private func calls(_ log: URL) -> [String] {
  (try? String(contentsOf: log, encoding: .utf8))?
    .split(separator: "\n").map(String.init) ?? []
}

struct OwnedSimulatorTests {

  @Test func unclaimedOwnedSimulatorCleansOnlyItsOwnNameBeforeCreateReturns() throws {
    try withFakeSimctl(devices: [
      ("aaaa", "putio-harness-ios-run-1-deadbeef"),
      ("bbbb", "another-agent-device"),
    ]) { runner, log in
      let owned = OwnedSimulator(name: "putio-harness-ios-run-1-deadbeef")
      // Interrupted before `simctl create` returned: only the verified name
      // identifies the device. The static fixture still lists it after
      // deletion, so the verification step throws; the recorded calls are
      // the contract under test.
      try? owned.cleanup(runner: runner)
      let recorded = calls(log)
      #expect(recorded.contains("simctl shutdown aaaa"))
      #expect(recorded.contains("simctl delete aaaa"))
      #expect(!recorded.contains { $0.contains("bbbb") })
    }
  }

  @Test func claimedOwnedSimulatorCleansTheExactUDIDNotTheName() throws {
    try withFakeSimctl(devices: [
      ("aaaa", "putio-harness-ios-run-1-deadbeef"),
      ("cccc", "putio-harness-ios-run-1-deadbeef"),
    ]) { runner, log in
      let owned = OwnedSimulator(name: "putio-harness-ios-run-1-deadbeef")
      owned.claim("cccc")
      try? owned.cleanup(runner: runner)
      let recorded = calls(log)
      #expect(recorded.contains("simctl delete cccc"))
      #expect(!recorded.contains("simctl delete aaaa"), "a same-named device is not ours")
    }
  }

}
