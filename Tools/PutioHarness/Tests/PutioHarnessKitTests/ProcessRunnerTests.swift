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
