import Darwin
import Foundation

public struct ProcessOutput: Sendable {
  public let status: Int32
  public let stdout: String
  public let stderr: String

  public var combinedOutput: String {
    [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
  }
}

private final class ProcessCapture: @unchecked Sendable {
  private let directory: URL
  private let stdoutURL: URL
  private let stderrURL: URL
  private let stdoutHandle: FileHandle
  private let stderrHandle: FileHandle
  private var stdoutIsOpen = true
  private var stderrIsOpen = true

  init(fileManager: FileManager = .default) throws {
    directory = fileManager.temporaryDirectory
      .appending(path: "putio-harness-process-\(UUID().uuidString.lowercased())")
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    stdoutURL = directory.appending(path: "stdout")
    stderrURL = directory.appending(path: "stderr")
    fileManager.createFile(atPath: stdoutURL.path, contents: nil)
    fileManager.createFile(atPath: stderrURL.path, contents: nil)
    stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
    stderrHandle = try FileHandle(forWritingTo: stderrURL)
  }

  func attach(to process: Process) {
    process.standardOutput = stdoutHandle
    process.standardError = stderrHandle
  }

  func output(status: Int32) -> ProcessOutput {
    let closeFailure = closeHandles()
    let stdout = (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
    var stderr = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
    if let closeFailure {
      stderr += stderr.isEmpty ? closeFailure : "\n\(closeFailure)"
    }
    try? FileManager.default.removeItem(at: directory)
    return ProcessOutput(status: status, stdout: stdout, stderr: stderr)
  }

  func discard() {
    _ = closeHandles()
    try? FileManager.default.removeItem(at: directory)
  }

  private func closeHandles() -> String? {
    var failures: [String] = []
    if stdoutIsOpen {
      do {
        try stdoutHandle.close()
        stdoutIsOpen = false
      } catch {
        failures.append("close child stdout capture: \(error)")
      }
    }
    if stderrIsOpen {
      do {
        try stderrHandle.close()
        stderrIsOpen = false
      } catch {
        failures.append("close child stderr capture: \(error)")
      }
    }
    return failures.isEmpty ? nil : failures.joined(separator: "\n")
  }
}

public final class ChildProcessLifecycle: @unchecked Sendable {
  public static let shared = ChildProcessLifecycle()

  private let condition = NSCondition()
  private var processes: [ObjectIdentifier: Process] = [:]
  private var terminationRequested = false

  private init() {}

  func launch(_ process: Process) throws {
    condition.lock()
    defer { condition.unlock() }
    while terminationRequested { condition.wait() }
    try process.run()
    processes[ObjectIdentifier(process)] = process
  }

  func release(_ process: Process) {
    condition.lock()
    _ = processes.removeValue(forKey: ObjectIdentifier(process))
    condition.unlock()
  }

  public func terminateAll() {
    condition.lock()
    terminationRequested = true
    let activeProcesses = Array(processes.values)
    condition.unlock()
    for process in activeProcesses { terminate(process) }
    condition.lock()
    terminationRequested = false
    condition.broadcast()
    condition.unlock()
  }

  private func terminate(_ process: Process) {
    guard process.isRunning else { return }
    kill(process.processIdentifier, SIGKILL)
    process.waitUntilExit()
  }
}

public final class RunningProcess: @unchecked Sendable {
  private let process: Process
  private let capture: ProcessCapture
  private var result: ProcessOutput?

  fileprivate init(process: Process, capture: ProcessCapture) {
    self.process = process
    self.capture = capture
  }

  public func interruptAndWait() -> ProcessOutput {
    finish(interrupt: true)
  }

  public func wait() -> ProcessOutput {
    finish(interrupt: false)
  }

  public var isRunning: Bool {
    process.isRunning
  }

  private func finish(interrupt: Bool) -> ProcessOutput {
    if let result { return result }
    if interrupt, process.isRunning { process.interrupt() }
    process.waitUntilExit()
    ChildProcessLifecycle.shared.release(process)
    let output = capture.output(status: process.terminationStatus)
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
    let capture = try ProcessCapture()
    defer { capture.discard() }

    let process = configuredProcess(
      executable,
      arguments,
      environment: environment,
      removingEnvironment: removingEnvironment,
      currentDirectory: currentDirectory
    )
    capture.attach(to: process)
    try ChildProcessLifecycle.shared.launch(process)
    defer { ChildProcessLifecycle.shared.release(process) }
    process.waitUntilExit()
    return capture.output(status: process.terminationStatus)
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
    let capture = try ProcessCapture()
    capture.attach(to: process)
    do {
      try ChildProcessLifecycle.shared.launch(process)
      return RunningProcess(process: process, capture: capture)
    } catch {
      capture.discard()
      throw error
    }
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
