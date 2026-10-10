import Foundation
import Testing

@testable import PutioHarnessKit

struct SimulatorJobsTests {
  @Test func unusedJobsAreBootedOutInOneSpawnByTheirPlistPaths() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "putio-simulator-jobs-\(UUID().uuidString.lowercased())")
    defer { try? FileManager.default.removeItem(at: root) }
    let runtimeRoot = root.appending(path: "RuntimeRoot")
    let daemon = runtimeRoot.appending(path: "System/Library/LaunchDaemons/com.apple.chronod.plist")
    let agent = runtimeRoot.appending(path: "System/Library/LaunchAgents/com.apple.assistantd.plist")
    let kept = runtimeRoot.appending(path: "System/Library/LaunchDaemons/com.apple.securityd.plist")
    // DTServiceHub needs gamed for every UI-test app launch.
    let keptGameCenter = runtimeRoot.appending(
      path: "System/Library/LaunchAgents/com.apple.gamed.plist")
    for plist in [daemon, agent, kept, keptGameCenter] {
      try FileManager.default.createDirectory(
        at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data().write(to: plist)
    }
    let bin = root.appending(path: "bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let log = root.appending(path: "calls")
    let xcrun = bin.appending(path: "xcrun")
    try """
    #!/bin/sh
    echo "$@" >> "\(log.path)"
    if [ "$2" = getenv ]; then echo "\(runtimeRoot.path)"; fi
    if [ "$2" = spawn ]; then exit 3; fi
    """.write(to: xcrun, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: xcrun.path)
    let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
    let harness = SimulatorHarness(
      context: RepositoryContext(root: root),
      runner: ProcessRunner(environment: ["PATH": "\(bin.path):\(originalPath)"]))

    try harness.unloadUnusedJobs("DEVICE")

    let calls = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
    #expect(
      calls == [
        "simctl getenv DEVICE SIMULATOR_ROOT",
        "simctl spawn DEVICE launchctl bootout system \(agent.path) \(daemon.path)",
      ])
  }
}
