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
