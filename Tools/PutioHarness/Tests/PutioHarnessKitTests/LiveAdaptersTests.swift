import Foundation
import Testing

@testable import PutioHarnessKit

/// A fake `putio` on PATH that records each call with the profile and token
/// it saw, and serves a put.io account whose fixture state the test chooses.
private struct FakePutio {
  let root: URL
  let adapters: LiveAdapters

  init(folderExists: Bool, fileExists: Bool, uploadListingLag: Int = 0) throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "putio-live-adapters-\(UUID().uuidString.lowercased())")
    let bin = root.appending(path: "bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    if folderExists { try Data().write(to: root.appending(path: "folder")) }
    if fileExists { try Data().write(to: root.appending(path: "file")) }
    try Data(String(repeating: "x", count: uploadListingLag).utf8).write(
      to: root.appending(path: "lag"))
    let executable = bin.appending(path: "putio")
    try #"""
    #!/bin/sh
    state="$PUTIO_FAKE_STATE"
    { printf 'CALL profile=%s token=%s\n' "$PUTIO_CLI_PROFILE" "${PUTIO_CLI_TOKEN-unset}"
      printf '%s\n' "$@"; } >> "$state/calls"
    dry=0
    parent=""
    previous=""
    for argument in "$@"; do
      [ "$argument" = "--dry-run" ] && dry=1
      [ "$previous" = "--parent-id" ] && parent="$argument"
      previous="$argument"
    done
    case "$1 $2" in
      "describe --output") echo '{}' ;;
      "auth status") echo '{"authenticated":true,"source":"profile","profile":"devs-auto"}' ;;
      "auth approve") echo '{}' ;;
      "files mkdir")
        [ "$dry" = 0 ] && : > "$state/folder"
        echo '{"file":{"id":77,"name":"putio-ios-harness"}}' ;;
      "files upload")
        [ "$dry" = 0 ] && : > "$state/file"
        echo '{}' ;;
      "files list")
        if [ "$parent" = 0 ]; then
          if [ -f "$state/folder" ]; then
            echo '{"files":[{"id":5,"name":"other","file_type":"FOLDER","parent_id":0},{"id":77,"name":"putio-ios-harness","file_type":"FOLDER","parent_id":0}]}'
          else
            echo '{"files":[{"id":5,"name":"other","file_type":"FOLDER","parent_id":0}]}'
          fi
        elif [ "$parent" = 77 ] && [ -f "$state/file" ] && [ -s "$state/lag" ]; then
          # put.io has accepted the upload but does not list it yet.
          tail -c +2 "$state/lag" > "$state/lag.next" && mv "$state/lag.next" "$state/lag"
          echo '{"files":[]}'
        elif [ "$parent" = 77 ] && [ -f "$state/file" ]; then
          echo '{"files":[{"id":87,"name":"live-fixture.png","file_type":"TEXT","parent_id":77},{"id":88,"name":"live-fixture.png","file_type":"IMAGE","parent_id":77}]}'
        else
          echo '{"files":[]}'
        fi ;;
      *) echo "unexpected putio call: $*" >&2; exit 64 ;;
    esac
    """#.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
    let runner = ProcessRunner(environment: [
      "PATH": "\(bin.path):\(originalPath)",
      "PUTIO_FAKE_STATE": root.path,
      // An ambient token must never reach the CLI in place of the profile.
      "PUTIO_CLI_TOKEN": "ambient-token-value",
    ])
    adapters = LiveAdapters(
      context: RepositoryContext(root: root), runner: runner, uploadPollInterval: 0.01)
  }

  /// Each call's arguments, after checking that it ran as devs-auto without
  /// the ambient token.
  func calls() throws -> [[String]] {
    let log = root.appending(path: "calls")
    guard FileManager.default.fileExists(atPath: log.path) else { return [] }
    return try String(contentsOf: log, encoding: .utf8)
      .components(separatedBy: "CALL ").dropFirst()
      .map { entry in
        let lines = entry.split(separator: "\n").map(String.init)
        #expect(lines.first == "profile=devs-auto token=unset")
        return Array(lines.dropFirst())
      }
  }

  func writes() throws -> [[String]] {
    try calls().filter {
      ["mkdir", "upload", "approve"].contains($0.dropFirst().first ?? "")
    }
  }

  func remove() { try? FileManager.default.removeItem(at: root) }
}

struct LiveAdaptersTests {
  @Test func reusesExistingFixtureFolderAndFileWithoutWriting() throws {
    let putio = try FakePutio(folderExists: true, fileExists: true)
    defer { putio.remove() }

    let fixture = try putio.adapters.provisionLiveFixture()

    #expect(fixture.folderID == 77)
    #expect(fixture.fileID == 88)
    #expect(fixture.summary.contains("reused live-fixture.png (id 88)"))
    #expect(try putio.writes().isEmpty)
  }

  @Test func validatesEachFixtureWriteWithDryRunBeforeWriting() throws {
    let putio = try FakePutio(folderExists: false, fileExists: false)
    defer { putio.remove() }

    let fixture = try putio.adapters.provisionLiveFixture()

    #expect(fixture.folderID == 77)
    #expect(fixture.fileID == 88)
    let writes = try putio.writes()
    #expect(
      writes.map { Array($0.prefix(2)) + [$0.contains("--dry-run") ? "dry" : "write"] } == [
        ["files", "mkdir", "dry"], ["files", "mkdir", "write"],
        ["files", "upload", "dry"], ["files", "upload", "write"],
      ])
    let upload = try #require(writes.last)
    let payload = try #require(upload.firstIndex(of: "--json").map { upload[$0 + 1] })
    let request = try #require(
      JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
    #expect(request["parent_id"] as? Int == 77)
    #expect(request["file_name"] as? String == "live-fixture.png")
    #expect(
      (request["path"] as? String)?.hasSuffix("Tests/HarnessMedia/previews/runtime-proof-image.png")
        == true)
  }

  @Test func uploadsOnlyTheMissingFileIntoAnExistingFolder() throws {
    let putio = try FakePutio(folderExists: true, fileExists: false)
    defer { putio.remove() }

    let fixture = try putio.adapters.provisionLiveFixture()

    #expect(fixture.fileID == 88)
    #expect(try putio.writes().map { $0[1] } == ["upload", "upload"])
  }

  @Test func waitsForAFreshUploadToBeListed() throws {
    let putio = try FakePutio(folderExists: true, fileExists: false, uploadListingLag: 3)
    defer { putio.remove() }

    let fixture = try putio.adapters.provisionLiveFixture()

    #expect(fixture.fileID == 88)
    #expect(try putio.writes().map { $0[1] } == ["upload", "upload"])
  }

  @Test func approvesACodeAfterADryRun() throws {
    let putio = try FakePutio(folderExists: true, fileExists: true)
    defer { putio.remove() }

    try putio.adapters.approveDeviceCode("AB12CD")

    #expect(
      try putio.calls() == [
        ["auth", "approve", "--json", #"{"code":"AB12CD"}"#, "--dry-run", "--output", "json"],
        ["auth", "approve", "--json", #"{"code":"AB12CD"}"#, "--output", "json"],
      ])
  }

  @Test func refusedApprovalWritesNothing() throws {
    let putio = try FakePutio(folderExists: true, fileExists: true)
    defer { putio.remove() }

    #expect(throws: HarnessFailure.self) {
      try putio.adapters.approveDeviceCode("AB12CD") { _ in
        throw HarnessFailure("cleanup started")
      }
    }

    #expect(try putio.calls().map { $0.contains("--dry-run") } == [true])
  }

  @Test(arguments: ["", "AB 12", "AB12;rm", "AB12\nCD", "ABC", String(repeating: "A", count: 17)])
  func refusesMalformedCodesBeforeCallingTheCLI(code: String) throws {
    let putio = try FakePutio(folderExists: true, fileExists: true)
    defer { putio.remove() }

    #expect(throws: HarnessFailure.self) { try putio.adapters.approveDeviceCode(code) }
    #expect(try putio.calls().isEmpty)
  }
}

struct LiveSessionContractTests {
  @Test func readsTheCodeTheAppReports() {
    #expect(LiveSessionContract.deviceCode(from: Data("  XK42PQ\n".utf8)) == "XK42PQ")
    #expect(LiveSessionContract.deviceCode(from: Data("XK42 PQ".utf8)) == nil)
    #expect(LiveSessionContract.deviceCode(from: Data("·····".utf8)) == nil)
    #expect(LiveSessionContract.deviceCode(from: Data([0xFF, 0xFE])) == nil)
  }

  @Test func acceptsOnlyPositiveRevocationEvidence() throws {
    func cleanup(_ outcome: String, recorded: Bool) throws -> LiveCleanup {
      LiveCleanup(
        outcome: try #require(LiveSessionContract.outcome(from: Data(outcome.utf8))),
        revocationRecorded: recorded)
    }
    #expect(try cleanup("signed-out", recorded: false).isRevoked)
    #expect(try cleanup("expired\n", recorded: false).isRevoked)
    #expect(try cleanup("no-session", recorded: true).isRevoked)
    // A token that lived only in a killed process, or was never saved, leaves
    // no session behind without having been revoked.
    let unproven = try cleanup("no-session", recorded: false)
    #expect(!unproven.isRevoked)
    #expect(unproven.summary.contains("may still be live"))
    #expect(try !cleanup("restore-failed", recorded: true).isRevoked)
    #expect(try !cleanup("sign-out-failed", recorded: true).isRevoked)
    #expect(LiveSessionContract.outcome(from: Data("signed-in".utf8)) == nil)
  }

}

/// Events recorded from several threads, in order.
private final class EventLog: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [String] = []

  func record(_ event: String) { lock.withLock { events.append(event) } }
  var recorded: [String] { lock.withLock { events } }
  var count: Int { lock.withLock { events.count } }
}

struct LiveGrantTests {
  @Test func revokesOnceAndReusesTheResult() throws {
    var attempts = 0
    let grant = LiveGrant {
      attempts += 1
      return LiveCleanup(outcome: .signOutFailed, revocationRecorded: false)
    }
    try grant.approve {}

    #expect(throws: HarnessFailure.self) { try grant.requireRevoked() }
    #expect(throws: HarnessFailure.self) { try grant.requireRevoked() }
    #expect(attempts == 1)
  }

  @Test func refusesApprovalOnceCleanupHasStarted() throws {
    var wrote = false
    let grant = LiveGrant { LiveCleanup(outcome: .signedOut, revocationRecorded: true) }

    try grant.requireRevoked()
    #expect(throws: HarnessFailure.self) { try grant.approve { wrote = true } }

    #expect(!wrote)
    #expect(try grant.revoke() == nil)
  }

  /// An interrupt that arrives while the approval write runs revokes only
  /// after it, never alongside it.
  @Test func revocationWaitsForAnApprovalInFlight() throws {
    let log = EventLog()
    let grant = LiveGrant {
      log.record("revoke")
      return LiveCleanup(outcome: .signedOut, revocationRecorded: true)
    }
    let writing = DispatchSemaphore(value: 0)
    let revoked = DispatchSemaphore(value: 0)
    let worker = Thread {
      try? grant.approve {
        writing.signal()
        _ = revoked.wait(timeout: .now() + 1)
        log.record("approve")
      }
    }
    worker.start()
    #expect(writing.wait(timeout: .now() + 5) == .success)

    try grant.requireRevoked()
    revoked.signal()

    #expect(log.recorded == ["approve", "revoke"])
  }
}

/// An interrupt after approval runs the lifecycle cleanup the signal handler
/// runs; revocation must precede the simulator deletion that would erase the
/// keychain holding the token.
struct LiveInterruptTests {
  private func interrupt(revocationResult: LiveCleanup) throws -> (events: [String], error: Error?)
  {
    let lifecycle = SimulatorLifecycle()
    var events: [String] = []
    try lifecycle.register { events.append("delete simulator") }
    let grant = LiveGrant {
      events.append("revoke")
      return revocationResult
    }
    try lifecycle.register(beforeSimulatorTeardown: true) { try grant.requireRevoked() }
    try grant.approve {}
    do {
      try lifecycle.cleanup()
      return (events, nil)
    } catch {
      return (events, error)
    }
  }

  @Test func revokesBeforeDeletingTheSimulator() throws {
    let result = try interrupt(
      revocationResult: LiveCleanup(outcome: .signedOut, revocationRecorded: true))
    #expect(result.events == ["revoke", "delete simulator"])
    #expect(result.error == nil)
  }

  @Test func reportsAnUnprovenRevocationAndStillDeletesTheSimulator() throws {
    let result = try interrupt(
      revocationResult: LiveCleanup(outcome: .noSession, revocationRecorded: false))
    #expect(result.events == ["revoke", "delete simulator"])
    #expect(String(describing: try #require(result.error)).contains("may still be live"))
  }
}

struct LiveCleanupRetryTests {
  private struct LaunchFailed: Error {}

  @Test func retriesAFailedLaunchUntilRevocationIsProven() throws {
    var attempts = 0
    let cleanup = try retryLiveCleanup(attempts: 3, delay: 0) {
      attempts += 1
      if attempts == 1 { throw LaunchFailed() }
      return LiveCleanup(outcome: .signedOut, revocationRecorded: true)
    }
    #expect(cleanup.isRevoked)
    #expect(attempts == 2)
  }

  @Test func reportsEveryAttemptWhenAllLaunchesFail() {
    var attempts = 0
    #expect {
      _ = try retryLiveCleanup(attempts: 3, delay: 0) {
        attempts += 1
        throw LaunchFailed()
      }
    } throws: { String(describing: $0).contains("failed 3 times") }
    #expect(attempts == 3)
  }

  @Test func stopsWhenNoTokenIsLeftToRevoke() throws {
    var attempts = 0
    let cleanup = try retryLiveCleanup(attempts: 3, delay: 0) {
      attempts += 1
      return LiveCleanup(outcome: .noSession, revocationRecorded: false)
    }
    #expect(!cleanup.isRevoked)
    #expect(attempts == 1)
  }
}

/// The interrupt handler's revocation can still be retrying while the worker
/// unwinds out of its session; the worker must leave the simulator to it.
struct LiveInterruptTeardownTests {
  @Test func workerLeavesSimulatorTeardownToAnInterruptInProgress() throws {
    let lifecycle = SimulatorLifecycle()
    let log = EventLog()
    let revocationStarted = DispatchSemaphore(value: 0)
    let workerFinished = DispatchSemaphore(value: 0)
    try lifecycle.register { log.record("delete simulator") }
    try lifecycle.register(beforeSimulatorTeardown: true) {
      revocationStarted.signal()
      _ = workerFinished.wait(timeout: .now() + 5)
      log.record("revoke")
    }
    let interrupt = Thread { try? lifecycle.cleanup() }
    interrupt.start()

    #expect(revocationStarted.wait(timeout: .now() + 5) == .success)
    try lifecycle.endSession { log.record("worker deletes simulator") }
    workerFinished.signal()
    let deadline = Date().addingTimeInterval(5)
    while log.count < 2, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.01)
    }

    #expect(log.recorded == ["revoke", "delete simulator"])
  }

  /// An interrupt that arrives after the worker claimed teardown waits for it
  /// instead of revoking against a simulator being deleted.
  @Test func interruptWaitsForATeardownTheWorkerAlreadyClaimed() throws {
    let lifecycle = SimulatorLifecycle()
    let log = EventLog()
    let interruptRan = DispatchSemaphore(value: 0)
    try lifecycle.register { log.record("interrupt deletes simulator") }
    try lifecycle.register(beforeSimulatorTeardown: true) {
      log.record("interrupt revokes")
      interruptRan.signal()
    }
    let interruptDone = DispatchSemaphore(value: 0)

    try lifecycle.endSession {
      log.record("worker deletes simulator")
      Thread {
        try? lifecycle.cleanup()
        interruptDone.signal()
      }.start()
      // Long enough for an unsynchronized interrupt to run its actions here.
      _ = interruptRan.wait(timeout: .now() + 1)
      log.record("worker teardown done")
    }
    #expect(interruptDone.wait(timeout: .now() + 5) == .success)

    #expect(log.recorded == ["worker deletes simulator", "worker teardown done"])
  }

  @Test func workerTearsDownWhenNoInterruptIsRunning() throws {
    let lifecycle = SimulatorLifecycle()
    var tornDown = false
    try lifecycle.endSession { tornDown = true }
    #expect(tornDown)
  }
}
