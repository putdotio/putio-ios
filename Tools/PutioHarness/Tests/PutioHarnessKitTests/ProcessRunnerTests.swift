import Foundation
import Testing

@testable import PutioHarnessKit

@Test func removesInheritedEnvironmentFromChildProcesses() throws {
  let output = try ProcessRunner().run(
    "/bin/sh",
    ["-c", "test -z \"${PUTIO_CLI_TOKEN+x}\""],
    environment: ["PUTIO_CLI_TOKEN": "must-not-reach-child"],
    removingEnvironment: ["PUTIO_CLI_TOKEN"]
  )

  #expect(output.status == 0)
}

@Test func closesCaptureHandlesWhenProcessLaunchFails() throws {
  let runner = ProcessRunner()
  let missingDirectory = FileManager.default.temporaryDirectory.appending(
    path: "putio-harness-missing-\(UUID().uuidString.lowercased())")

  #expect(throws: Error.self) {
    try runner.run("true", currentDirectory: missingDirectory)
  }
  let recovery = try runner.run("printf", ["ok"])
  #expect(recovery.status == 0)
  #expect(recovery.stdout == "ok")
}

@Test func startedProcessDrainsLargeOutputWithoutPipeBackpressure() throws {
  let byteCount = 262_144
  let process = try ProcessRunner().start(
    "/bin/sh",
    [
      "-c",
      "head -c \(byteCount) /dev/zero; head -c \(byteCount) /dev/zero >&2",
    ]
  )

  let output = process.wait()

  #expect(output.status == 0)
  #expect(output.stdout.utf8.count == byteCount)
  #expect(output.stderr.utf8.count == byteCount)
}

@Test func processCaptureReadFailurePreservesDiagnostics() {
  let missingCapture = FileManager.default.temporaryDirectory.appending(
    path: "putio-harness-missing-capture-\(UUID().uuidString.lowercased())")

  let capture = processCaptureContents(at: missingCapture, label: "stdout")

  #expect(capture.contents.isEmpty)
  #expect(capture.failure?.contains("read child stdout capture:") == true)
}
