import Darwin
import Foundation
import ImageIO

public struct SurfaceRun: Sendable {
  public let platform: HarnessPlatform
  public let artifacts: [URL]
  public let message: String
}

private final class SimulatorSession {
  let deviceIdentifier: String
  let deviceName: String
  let runtime: RuntimeRecord
  let deviceType: DeviceTypeRecord
  let companionIdentifier: String?
  private let runner: ProcessRunner

  init(
    deviceIdentifier: String,
    deviceName: String,
    runtime: RuntimeRecord,
    deviceType: DeviceTypeRecord,
    companionIdentifier: String?,
    runner: ProcessRunner
  ) {
    self.deviceIdentifier = deviceIdentifier
    self.deviceName = deviceName
    self.runtime = runtime
    self.deviceType = deviceType
    self.companionIdentifier = companionIdentifier
    self.runner = runner
  }

  func cleanup() throws {
    let identifiers = [deviceIdentifier, companionIdentifier].compactMap { $0 }
    var diagnostics: [String] = []
    for identifier in identifiers {
      do {
        let output = try runner.run("xcrun", ["simctl", "shutdown", identifier])
        if output.status != 0 { diagnostics.append(output.combinedOutput) }
      } catch {
        diagnostics.append("shutdown \(identifier): \(error)")
      }
      do {
        let output = try runner.run("xcrun", ["simctl", "delete", identifier])
        if output.status != 0 { diagnostics.append(output.combinedOutput) }
      } catch {
        diagnostics.append("delete \(identifier): \(error)")
      }
    }
    let devices = try runner.checked(
      "xcrun", ["simctl", "list", "devices", "-j"], context: "verify Simulator cleanup")
    let remaining = identifiers.filter { devices.stdout.contains($0) }
    guard remaining.isEmpty else {
      let detail = diagnostics.filter { !$0.isEmpty }.joined(separator: "\n")
      throw HarnessFailure(
        "Simulator cleanup left devices behind: \(remaining.joined(separator: ", "))\n\(detail)")
    }
  }
}

public struct SimulatorHarness {
  private let context: RepositoryContext
  private let runner: ProcessRunner
  private let fileManager: FileManager

  public init(
    context: RepositoryContext,
    runner: ProcessRunner = ProcessRunner(),
    fileManager: FileManager = .default
  ) {
    self.context = context
    self.runner = runner
    self.fileManager = fileManager
  }

  public func build(_ platform: HarnessPlatform) throws -> SurfaceRun {
    try requireGeneratedWorkspace()
    try fileManager.createDirectory(at: context.derivedData, withIntermediateDirectories: true)
    if platform == .watchos {
      try buildProduct(.ios)
    }
    try buildProduct(platform)
    let config = platform.configuration
    let app = appURL(for: platform)
    guard fileManager.fileExists(atPath: app.path) else {
      throw HarnessFailure(
        "build \(platform.rawValue) succeeded but product is missing at \(app.path)")
    }
    return SurfaceRun(platform: platform, artifacts: [], message: "built \(config.scheme)")
  }

  private func buildProduct(_ platform: HarnessPlatform) throws {
    let config = platform.configuration
    _ = try runner.checked(
      "xcodebuild",
      [
        "build",
        "-workspace", "Putio.xcworkspace",
        "-scheme", config.scheme,
        "-destination", config.destination,
        "-derivedDataPath", context.derivedData.path,
      ],
      currentDirectory: context.root,
      context: "build \(platform.rawValue)"
    )
  }

  public func launch(_ platform: HarnessPlatform) throws -> SurfaceRun {
    try runInstalledApp(platform, shouldExercise: false)
  }

  public func boot(_ platform: HarnessPlatform) throws -> SurfaceRun {
    try withSession(platform: platform, runID: UUID().uuidString.lowercased()) { _ in
      SurfaceRun(
        platform: platform,
        artifacts: [],
        message: "boot confirmed ephemeral \(platform.rawValue) Simulator"
      )
    }
  }

  public func exercise(_ platform: HarnessPlatform) throws -> SurfaceRun {
    try runInstalledApp(platform, shouldExercise: true)
  }

  private func runInstalledApp(_ platform: HarnessPlatform, shouldExercise: Bool) throws
    -> SurfaceRun
  {
    _ = try build(platform)
    let scratch = context.root.appending(path: "build/harness/\(UUID().uuidString.lowercased())")
    try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: scratch) }
    return try withSession(platform: platform, runID: UUID().uuidString.lowercased()) { session in
      try install(platform: platform, session: session)
      let screenshot = scratch.appending(path: "ready.png")
      let pid = try launchAndWait(
        platform: platform, session: session, screenshot: screenshot, logsDirectory: scratch)
      if shouldExercise {
        let exercisedScreenshot = scratch.appending(path: "exercised.png")
        _ = try performExercise(
          platform: platform,
          session: session,
          pid: pid,
          baseline: screenshot,
          screenshot: exercisedScreenshot,
          logsDirectory: scratch
        )
      }
      return SurfaceRun(
        platform: platform,
        artifacts: [],
        message: shouldExercise
          ? "exercise confirmed \(platform.configuration.bundleIdentifier) completed its visible harness scenario"
          : "launch confirmed \(platform.configuration.bundleIdentifier) stayed running"
      )
    }
  }

  public func capture(
    _ platform: HarnessPlatform,
    command: SurfaceCommand,
    runID: String,
    recordSeconds: Int
  ) throws -> SurfaceRun {
    try requireCleanSource()
    try regenerateWorkspace()
    try requireCleanSource()
    _ = try build(platform)
    let platformDirectory = context.proofRoot.appending(path: runID).appending(
      path: platform.rawValue)
    guard !fileManager.fileExists(atPath: platformDirectory.path) else {
      throw HarnessFailure(
        "proof path already exists: \(platformDirectory.path); choose a new --run-id")
    }
    try fileManager.createDirectory(at: platformDirectory, withIntermediateDirectories: true)

    do {
      return try withSession(platform: platform, runID: runID) { session in
        try install(platform: platform, session: session)

        let wantsScreenshot = command == .screenshot || command == .proof
        let wantsRecording = command == .record || command == .proof
        let screenshot = platformDirectory.appending(
          path: command == .proof ? "exercised.png" : "signed-out.png")
        let readinessScreenshot =
          command == .proof
          ? platformDirectory.appending(path: ".signed-out-readiness.png")
          : wantsScreenshot ? screenshot : platformDirectory.appending(path: ".readiness.png")
        let recording = platformDirectory.appending(path: "launch.mp4")
        let recordingProcess =
          wantsRecording ? try startRecording(session: session, output: recording) : nil
        defer {
          if let recordingProcess { _ = recordingProcess.interruptAndWait() }
        }

        var pid = try launchAndWait(
          platform: platform,
          session: session,
          screenshot: readinessScreenshot,
          logsDirectory: platformDirectory
        )
        if command == .proof {
          pid = try performExercise(
            platform: platform,
            session: session,
            pid: pid,
            baseline: readinessScreenshot,
            screenshot: screenshot,
            logsDirectory: platformDirectory
          )
          try? fileManager.removeItem(at: readinessScreenshot)
        }

        if wantsRecording {
          try waitForLiveness(
            pid: pid,
            seconds: TimeInterval(recordSeconds),
            bundleIdentifier: platform.configuration.bundleIdentifier
          )
          guard let recordingProcess else {
            throw HarnessFailure("recording process was not created")
          }
          let output = recordingProcess.interruptAndWait()
          guard output.status == 0 else {
            throw HarnessFailure("record \(platform.rawValue) failed\n\(output.combinedOutput)")
          }
          try requireNonemptyFile(recording, context: "recording")
          guard processIsRunning(pid) else {
            throw HarnessFailure(
              "\(platform.configuration.bundleIdentifier) exited before proof capture completed")
          }
        }
        if !wantsScreenshot { try? fileManager.removeItem(at: readinessScreenshot) }

        let artifactURLs = [wantsScreenshot ? screenshot : nil, wantsRecording ? recording : nil]
          .compactMap { $0 }
        let manifest = try writeManifest(
          platform: platform,
          command: command,
          runID: runID,
          session: session,
          artifactURLs: artifactURLs,
          directory: platformDirectory
        )
        return SurfaceRun(
          platform: platform,
          artifacts: artifactURLs + [manifest],
          message:
            "captured \(command.rawValue) for \(platform.rawValue) in \(platformDirectory.path)"
        )
      }
    } catch {
      let diagnostics = failureDiagnostics(in: platformDirectory)
      try? fileManager.removeItem(at: platformDirectory)
      guard !diagnostics.isEmpty else { throw error }
      throw HarnessFailure("\(error)\n\(diagnostics)")
    }
  }

  public func defaultRunID() throws -> String {
    let commit = try runner.checked(
      "git",
      ["rev-parse", "--short", "HEAD"],
      currentDirectory: context.root,
      context: "read git commit"
    ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    return "\(formatter.string(from: Date()))-\(commit)"
  }

  private func withSession<T>(
    platform: HarnessPlatform,
    runID: String,
    operation: (SimulatorSession) throws -> T
  ) throws -> T {
    let session = try createSession(platform: platform, runID: runID)
    let result: Result<T, Error>
    do {
      result = .success(try operation(session))
    } catch {
      result = .failure(error)
    }
    do {
      try session.cleanup()
    } catch {
      switch result {
      case .success:
        throw error
      case .failure(let operationError):
        throw HarnessFailure("\(operationError)\ncleanup failed: \(error)")
      }
    }
    return try result.get()
  }

  private func requireGeneratedWorkspace() throws {
    let workspace = context.root.appending(path: "Putio.xcworkspace")
    guard fileManager.fileExists(atPath: workspace.path) else {
      throw HarnessFailure("Putio.xcworkspace is missing; run mise run generate")
    }
  }

  private func requireCleanSource() throws {
    let output = try runner.checked(
      "git",
      ["status", "--porcelain=v1", "--untracked-files=all"],
      currentDirectory: context.root,
      context: "inspect proof source state"
    ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard output.isEmpty else {
      let changedPaths = output.split(separator: "\n").prefix(20).joined(separator: "\n")
      throw HarnessFailure(
        "proof requires a clean Git worktree so its manifest can identify the exact source commit\n\(changedPaths)"
      )
    }
  }

  private func regenerateWorkspace() throws {
    _ = try runner.checked(
      "./scripts/generate.sh",
      currentDirectory: context.root,
      context: "regenerate workspace for proof provenance"
    )
  }

  private func appURL(for platform: HarnessPlatform) -> URL {
    let config = platform.configuration
    return context.derivedData
      .appending(path: "Build/Products")
      .appending(path: config.productDirectory)
      .appending(path: config.appName)
  }

  private func createSession(platform: HarnessPlatform, runID: String) throws -> SimulatorSession {
    let runtimes = try availableRuntimes()
    let deviceTypes = try availableDeviceTypes()
    let config = platform.configuration
    let sdkVersion = try runner.checked(
      "xcodebuild",
      ["-version", "-sdk", config.sdk, "ProductVersion"],
      context: "read \(config.sdk) version"
    ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      let runtime = runtimes.first(where: {
        $0.isAvailable && $0.platform == config.runtimePlatform
          && runtimeMatchesSDK($0.version, sdkVersion)
      })
    else {
      throw HarnessFailure(
        "\(config.runtimePlatform) \(sdkVersion) Simulator runtime is missing; run xcodebuild -downloadPlatform \(config.runtimePlatform)"
      )
    }
    guard let deviceType = deviceTypes.first(where: { $0.productFamily == config.deviceFamily })
    else {
      throw HarnessFailure("no \(config.deviceFamily) Simulator device type is installed")
    }

    let suffix = String(runID.prefix(24))
    let deviceName = "putio-harness-\(platform.rawValue)-\(suffix)"
    let deviceIdentifier = try createDevice(
      name: deviceName, type: deviceType.identifier, runtime: runtime.identifier)
    var companionIdentifier: String?

    do {
      if platform == .watchos {
        guard
          let phoneRuntime = runtimes.first(where: {
            $0.isAvailable && $0.platform == "iOS"
              && runtimeMatchesSDK($0.version, runtime.version)
          }),
          let phoneType = deviceTypes.first(where: { $0.productFamily == "iPhone" })
        else {
          throw HarnessFailure(
            "watchOS \(runtime.version) requires a matching iOS Simulator runtime and iPhone device type"
          )
        }
        let phoneName = "putio-harness-watch-companion-\(suffix)"
        let phoneIdentifier = try createDevice(
          name: phoneName,
          type: phoneType.identifier,
          runtime: phoneRuntime.identifier
        )
        companionIdentifier = phoneIdentifier
        let pairIdentifier = try runner.checked(
          "xcrun",
          ["simctl", "pair", deviceIdentifier, phoneIdentifier],
          context: "pair watchOS simulator with iPhone companion"
        ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let activation = try runner.run(
          "xcrun",
          ["simctl", "pair_activate", pairIdentifier]
        )
        guard activation.status == 0 || activation.combinedOutput.contains("already active") else {
          throw HarnessFailure(
            "activate watchOS simulator pair failed\n\(activation.combinedOutput)")
        }
        try boot(phoneIdentifier, label: "iPhone companion")
      }
      try boot(deviceIdentifier, label: platform.rawValue)
      if platform == .watchos {
        _ = try runner.checked(
          "xcrun",
          ["simctl", "io", deviceIdentifier, "screenConfig", "power", "on"],
          context: "wake watchOS Simulator display"
        )
      }
      return SimulatorSession(
        deviceIdentifier: deviceIdentifier,
        deviceName: deviceName,
        runtime: runtime,
        deviceType: deviceType,
        companionIdentifier: companionIdentifier,
        runner: runner
      )
    } catch {
      _ = try? runner.run("xcrun", ["simctl", "delete", deviceIdentifier])
      if let companionIdentifier {
        _ = try? runner.run("xcrun", ["simctl", "delete", companionIdentifier])
      }
      throw error
    }
  }

  private func availableRuntimes() throws -> [RuntimeRecord] {
    let output = try runner.checked(
      "xcrun",
      ["simctl", "list", "-j", "runtimes"],
      context: "list Simulator runtimes"
    )
    return try JSONDecoder().decode(RuntimeList.self, from: Data(output.stdout.utf8)).runtimes
  }

  private func availableDeviceTypes() throws -> [DeviceTypeRecord] {
    let output = try runner.checked(
      "xcrun",
      ["simctl", "list", "-j", "devicetypes"],
      context: "list Simulator device types"
    )
    return try JSONDecoder().decode(DeviceTypeList.self, from: Data(output.stdout.utf8)).devicetypes
  }

  private func createDevice(name: String, type: String, runtime: String) throws -> String {
    try runner.checked(
      "xcrun",
      ["simctl", "create", name, type, runtime],
      context: "create Simulator device \(name)"
    ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func boot(_ identifier: String, label: String) throws {
    _ = try runner.checked(
      "xcrun", ["simctl", "boot", identifier], context: "boot \(label) Simulator")
    _ = try runner.checked(
      "xcrun",
      ["simctl", "bootstatus", identifier, "-b"],
      context: "wait for \(label) Simulator"
    )
  }

  private func install(platform: HarnessPlatform, session: SimulatorSession) throws {
    if platform == .watchos {
      guard let companionIdentifier = session.companionIdentifier else {
        throw HarnessFailure("watchOS session has no paired iPhone companion")
      }
      let companionApp = appURL(for: .ios)
      try requireNonemptyDirectory(companionApp, context: "built iOS companion app")
      _ = try runner.checked(
        "xcrun",
        ["simctl", "install", companionIdentifier, companionApp.path],
        context: "install iOS companion app"
      )
    }
    let app = appURL(for: platform)
    try requireNonemptyDirectory(app, context: "built app")
    _ = try runner.checked(
      "xcrun",
      ["simctl", "install", session.deviceIdentifier, app.path],
      context: "install \(platform.rawValue) app"
    )
  }

  private func launchAndWait(
    platform: HarnessPlatform,
    session: SimulatorSession,
    screenshot: URL,
    logsDirectory: URL,
    scenario: String = "signed-out"
  ) throws -> Int {
    let baseline = logsDirectory.appending(path: ".baseline.png")
    _ = try runner.checked(
      "xcrun",
      ["simctl", "io", session.deviceIdentifier, "screenshot", baseline.path],
      context: "capture pre-launch screen"
    )
    defer { try? fileManager.removeItem(at: baseline) }

    let stdout = logsDirectory.appending(path: "app.stdout.log")
    let stderr = logsDirectory.appending(path: "app.stderr.log")
    let config = platform.configuration
    let output = try runner.checked(
      "xcrun",
      [
        "simctl", "launch",
        "--terminate-running-process",
        "--stdout=\(stdout.path)",
        "--stderr=\(stderr.path)",
        session.deviceIdentifier,
        config.bundleIdentifier,
        "--putio-harness-scenario", scenario,
      ],
      context: "launch \(platform.rawValue) app"
    )
    guard
      let pidText = output.stdout.split(separator: ":").last?.trimmingCharacters(
        in: .whitespacesAndNewlines),
      let pid = Int(pidText)
    else {
      throw HarnessFailure("launch \(platform.rawValue) returned no process id: \(output.stdout)")
    }

    let baselinePixels = try decodedPixels(at: baseline)
    let deadline = Date().addingTimeInterval(12)
    repeat {
      guard processIsRunning(pid) else {
        throw HarnessFailure("\(config.bundleIdentifier) exited before its first rendered frame")
      }
      let capture = try runner.run(
        "xcrun",
        ["simctl", "io", session.deviceIdentifier, "screenshot", screenshot.path]
      )
      if capture.status == 0,
        let currentPixels = try? decodedPixels(at: screenshot),
        currentPixels.data != baselinePixels.data,
        currentPixels.visibleContentPixelCount >= currentPixels.minimumContentPixelCount
      {
        return pid
      }
      Thread.sleep(forTimeInterval: 0.25)
    } while Date() < deadline

    throw HarnessFailure(
      "\(config.bundleIdentifier) stayed running but its screen did not change within 12 seconds")
  }

  private func processIsRunning(_ pid: Int) -> Bool {
    Darwin.kill(pid_t(pid), 0) == 0 || errno == EPERM
  }

  private func waitForLiveness(pid: Int, seconds: TimeInterval, bundleIdentifier: String) throws {
    let deadline = Date().addingTimeInterval(seconds)
    repeat {
      guard processIsRunning(pid) else {
        throw HarnessFailure("\(bundleIdentifier) exited during proof capture")
      }
      Thread.sleep(forTimeInterval: min(0.25, max(0, deadline.timeIntervalSinceNow)))
    } while Date() < deadline
  }

  private func performExercise(
    platform: HarnessPlatform,
    session: SimulatorSession,
    pid: Int,
    baseline: URL,
    screenshot: URL,
    logsDirectory: URL
  ) throws -> Int {
    guard processIsRunning(pid) else {
      throw HarnessFailure(
        "\(platform.configuration.bundleIdentifier) exited before harness exercise")
    }
    let exercisedPID = try launchAndWait(
      platform: platform,
      session: session,
      screenshot: screenshot,
      logsDirectory: logsDirectory,
      scenario: "exercised"
    )
    try waitForExerciseSignal(
      platform: platform,
      session: session,
      pid: exercisedPID,
      bundleIdentifier: platform.configuration.bundleIdentifier
    )
    try waitForChangedFrame(
      platform: platform,
      session: session,
      pid: exercisedPID,
      baseline: baseline,
      screenshot: screenshot,
      action: "harness exercise"
    )
    return exercisedPID
  }

  private func waitForExerciseSignal(
    platform: HarnessPlatform,
    session: SimulatorSession,
    pid: Int,
    bundleIdentifier: String
  ) throws {
    let container = try runner.checked(
      "xcrun",
      ["simctl", "get_app_container", session.deviceIdentifier, bundleIdentifier, "data"],
      context: "locate \(platform.rawValue) harness data container"
    ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    let marker = URL(fileURLWithPath: container)
      .appending(path: "tmp/putio-harness-exercise-complete")
    let deadline = Date().addingTimeInterval(12)
    repeat {
      guard processIsRunning(pid) else {
        throw HarnessFailure("\(bundleIdentifier) exited before signaling harness exercise")
      }
      if fileManager.fileExists(atPath: marker.path) { return }
      Thread.sleep(forTimeInterval: 0.1)
    } while Date() < deadline
    throw HarnessFailure("\(bundleIdentifier) did not signal harness exercise within 12 seconds")
  }

  private func waitForChangedFrame(
    platform: HarnessPlatform,
    session: SimulatorSession,
    pid: Int,
    baseline: URL,
    screenshot: URL,
    action: String
  ) throws {
    let baselinePixels = try decodedPixels(at: baseline)
    let deadline = Date().addingTimeInterval(12)
    repeat {
      guard processIsRunning(pid) else {
        throw HarnessFailure(
          "\(platform.configuration.bundleIdentifier) exited during \(action)")
      }
      let capture = try runner.run(
        "xcrun", ["simctl", "io", session.deviceIdentifier, "screenshot", screenshot.path])
      if capture.status == 0,
        let currentPixels = try? decodedPixels(at: screenshot),
        currentPixels.data != baselinePixels.data,
        currentPixels.visibleContentPixelCount >= currentPixels.minimumContentPixelCount
      {
        return
      }
      Thread.sleep(forTimeInterval: 0.25)
    } while Date() < deadline
    throw HarnessFailure("\(action) did not produce a visible frame change within 12 seconds")
  }

  private func startRecording(session: SimulatorSession, output: URL) throws -> RunningProcess {
    let process = try runner.start(
      "xcrun",
      [
        "simctl", "io", session.deviceIdentifier, "recordVideo", "--codec=h264", "--force",
        output.path,
      ]
    )
    let deadline = Date().addingTimeInterval(8)
    while Date() < deadline {
      if fileManager.fileExists(atPath: output.path) { return process }
      Thread.sleep(forTimeInterval: 0.1)
    }
    _ = process.interruptAndWait()
    throw HarnessFailure("recording did not start within 8 seconds")
  }

  private func failureDiagnostics(in directory: URL) -> String {
    ["app.stdout.log", "app.stderr.log"].compactMap { name in
      let url = directory.appending(path: name)
      guard let data = try? Data(contentsOf: url), !data.isEmpty,
        let contents = String(data: data, encoding: .utf8)
      else { return nil }
      let lines = contents.split(separator: "\n", omittingEmptySubsequences: false).suffix(40)
      return "\(name):\n\(lines.joined(separator: "\n"))"
    }.joined(separator: "\n")
  }

  private func writeManifest(
    platform: HarnessPlatform,
    command: SurfaceCommand,
    runID: String,
    session: SimulatorSession,
    artifactURLs: [URL],
    directory: URL
  ) throws -> URL {
    let commit = try runner.checked(
      "git",
      ["rev-parse", "HEAD"],
      currentDirectory: context.root,
      context: "read git commit"
    ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    let artifacts = try artifactURLs.map { try artifact(for: $0) }
    let manifest = ProofManifest(
      runID: runID,
      commit: commit,
      createdAt: ISO8601DateFormatter().string(from: Date()),
      command: command.rawValue,
      platform: platform,
      scheme: platform.configuration.scheme,
      bundleIdentifier: platform.configuration.bundleIdentifier,
      runtime: session.runtime.name,
      deviceType: session.deviceType.name,
      simulatorName: session.deviceName,
      fixtureSet: command == .proof
        ? "signed-out-to-exercised-placeholder-v1" : "signed-out-placeholder-v1",
      artifacts: artifacts
    )
    let manifestURL = directory.appending(path: "manifest.json")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
    return manifestURL
  }

  private func artifact(for url: URL) throws -> ProofArtifact {
    let attributes = try fileManager.attributesOfItem(atPath: url.path)
    let bytes = (attributes[.size] as? NSNumber)?.intValue ?? 0
    let digest =
      try runner.checked(
        "shasum",
        ["-a", "256", url.path],
        context: "hash \(url.lastPathComponent)"
      ).stdout.split(separator: " ").first.map(String.init) ?? ""
    let relative = url.path.replacingOccurrences(of: context.root.path + "/", with: "")
    return ProofArtifact(
      kind: url.pathExtension == "png" ? "screenshot" : "recording", path: relative, bytes: bytes,
      sha256: digest)
  }

  private func requireNonemptyFile(_ url: URL, context: String) throws {
    let attributes = try fileManager.attributesOfItem(atPath: url.path)
    guard let size = (attributes[.size] as? NSNumber)?.intValue, size > 0 else {
      throw HarnessFailure("\(context) is empty at \(url.path)")
    }
  }

  private func requireNonemptyDirectory(_ url: URL, context: String) throws {
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue
    else {
      throw HarnessFailure("\(context) is missing at \(url.path); run the matching build command")
    }
  }

  private func decodedPixels(at url: URL) throws -> DecodedPixels {
    let encoded = try Data(contentsOf: url)
    guard
      let source = CGImageSourceCreateWithData(encoded as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
      throw HarnessFailure("could not decode screenshot pixels at \(url.path)")
    }
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    var rendered = false
    bytes.withUnsafeMutableBytes { buffer in
      guard
        let context = CGContext(
          data: buffer.baseAddress,
          width: image.width,
          height: image.height,
          bitsPerComponent: 8,
          bytesPerRow: image.width * 4,
          space: colorSpace,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue
        )
      else { return }
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      rendered = true
    }
    guard rendered else {
      throw HarnessFailure("could not rasterize screenshot pixels at \(url.path)")
    }
    let minimumX = image.width / 10
    let maximumX = image.width * 9 / 10
    let minimumY = image.height / 5
    let maximumY = image.height * 4 / 5
    var visibleContentPixelCount = 0
    for y in minimumY..<maximumY {
      for x in minimumX..<maximumX {
        let index = (y * image.width + x) * 4
        if max(bytes[index], bytes[index + 1], bytes[index + 2]) >= 48 {
          visibleContentPixelCount += 1
        }
      }
    }
    let contentArea = (maximumX - minimumX) * (maximumY - minimumY)
    return DecodedPixels(
      data: Data(bytes),
      visibleContentPixelCount: visibleContentPixelCount,
      minimumContentPixelCount: max(128, contentArea / 1_000)
    )
  }
}

private struct DecodedPixels {
  let data: Data
  let visibleContentPixelCount: Int
  let minimumContentPixelCount: Int
}
