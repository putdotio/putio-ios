import Foundation

public struct ProcessOutput: Sendable {
  public let status: Int32
  public let stdout: String
  public let stderr: String

  public var combinedOutput: String {
    [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
  }
}

public final class RunningProcess: @unchecked Sendable {
  private let process: Process
  private let stdoutPipe: Pipe
  private let stderrPipe: Pipe
  private var result: ProcessOutput?

  fileprivate init(process: Process, stdoutPipe: Pipe, stderrPipe: Pipe) {
    self.process = process
    self.stdoutPipe = stdoutPipe
    self.stderrPipe = stderrPipe
  }

  public func interruptAndWait() -> ProcessOutput {
    if let result { return result }
    if process.isRunning { process.interrupt() }
    process.waitUntilExit()
    let stdout =
      String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderr =
      String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let output = ProcessOutput(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    result = output
    return output
  }
}

public struct ProcessRunner: Sendable {
  public init() {}

  public func run(
    _ executable: String,
    _ arguments: [String] = [],
    environment: [String: String] = [:],
    removingEnvironment: Set<String> = [],
    currentDirectory: URL? = nil
  ) throws -> ProcessOutput {
    let captureDirectory = FileManager.default.temporaryDirectory
      .appending(path: "putio-harness-process-\(UUID().uuidString.lowercased())")
    try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: captureDirectory) }
    let stdoutURL = captureDirectory.appending(path: "stdout")
    let stderrURL = captureDirectory.appending(path: "stderr")
    FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
    FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
    let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
    var stdoutIsOpen = true
    defer {
      if stdoutIsOpen { try? stdoutHandle.close() }
    }
    let stderrHandle = try FileHandle(forWritingTo: stderrURL)
    var stderrIsOpen = true
    defer {
      if stderrIsOpen { try? stderrHandle.close() }
    }

    let process = configuredProcess(
      executable,
      arguments,
      environment: environment,
      removingEnvironment: removingEnvironment,
      currentDirectory: currentDirectory
    )
    process.standardOutput = stdoutHandle
    process.standardError = stderrHandle
    try process.run()
    process.waitUntilExit()
    try stdoutHandle.close()
    stdoutIsOpen = false
    try stderrHandle.close()
    stderrIsOpen = false
    let stdout = String(data: try Data(contentsOf: stdoutURL), encoding: .utf8) ?? ""
    let stderr = String(data: try Data(contentsOf: stderrURL), encoding: .utf8) ?? ""
    return ProcessOutput(status: process.terminationStatus, stdout: stdout, stderr: stderr)
  }

  public func checked(
    _ executable: String,
    _ arguments: [String] = [],
    environment: [String: String] = [:],
    removingEnvironment: Set<String> = [],
    currentDirectory: URL? = nil,
    context: String
  ) throws -> ProcessOutput {
    let output = try run(
      executable,
      arguments,
      environment: environment,
      removingEnvironment: removingEnvironment,
      currentDirectory: currentDirectory
    )
    guard output.status == 0 else {
      throw HarnessFailure("\(context) failed\n\(tail(output.combinedOutput))")
    }
    return output
  }

  func runIgnoringTerminationSignals(
    _ executable: String,
    _ arguments: [String] = [],
    currentDirectory: URL? = nil
  ) throws -> ProcessOutput {
    try run(
      "/bin/sh",
      ["-c", "trap '' INT TERM; exec \"$@\"", "putio-harness-cleanup", executable]
        + arguments,
      currentDirectory: currentDirectory
    )
  }

  func checkedIgnoringTerminationSignals(
    _ executable: String,
    _ arguments: [String] = [],
    currentDirectory: URL? = nil,
    context: String
  ) throws -> ProcessOutput {
    let output = try runIgnoringTerminationSignals(
      executable,
      arguments,
      currentDirectory: currentDirectory
    )
    guard output.status == 0 else {
      throw HarnessFailure("\(context) failed\n\(tail(output.combinedOutput))")
    }
    return output
  }

  public func start(
    _ executable: String,
    _ arguments: [String] = [],
    environment: [String: String] = [:],
    removingEnvironment: Set<String> = [],
    currentDirectory: URL? = nil
  ) throws -> RunningProcess {
    let process = configuredProcess(
      executable,
      arguments,
      environment: environment,
      removingEnvironment: removingEnvironment,
      currentDirectory: currentDirectory
    )
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    try process.run()
    return RunningProcess(process: process, stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)
  }

  private func configuredProcess(
    _ executable: String,
    _ arguments: [String],
    environment: [String: String],
    removingEnvironment: Set<String>,
    currentDirectory: URL?
  ) -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [executable] + arguments
    var childEnvironment = ProcessInfo.processInfo.environment.merging(environment) { _, override in
      override
    }
    for key in removingEnvironment { childEnvironment.removeValue(forKey: key) }
    process.environment = childEnvironment
    process.currentDirectoryURL = currentDirectory
    return process
  }

  private func tail(_ output: String, lineCount: Int = 40) -> String {
    output.split(separator: "\n", omittingEmptySubsequences: false).suffix(lineCount).joined(
      separator: "\n")
  }
}
